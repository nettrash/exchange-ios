//
//  ContentView.swift
//  Exchange
//
//  Top-level view. Shows a full-screen splash that visually matches the
//  iOS launch screen while the identity loads (or generates, on first
//  run). Once loaded, it transitions to the home screen — identity
//  details up top, recipient list below, Compose / Decrypt / Add /
//  Show QR sheets driven from the toolbar.
//

import CryptoKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(RecipientsSyncCoordinator.self) private var recipientsSync
    @Environment(\.scenePhase) private var scenePhase
    // Manual order first (drag-to-reorder), then newest-first as the
    // tie-break so rows that have never been reordered keep their old
    // ordering.
    @Query(sort: [
        SortDescriptor(\Recipient.orderIndex, order: .forward),
        SortDescriptor(\Recipient.createdAt, order: .reverse),
    ])
    private var recipients: [Recipient]

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?
    /// Becomes true once the splash has been visible for at least
    /// `minimumSplashDuration`. We gate the transition to the main UI
    /// on this so the animated indicator gets enough time to actually
    /// be seen, even when identity loads in tens of milliseconds (the
    /// common case on every launch after the first).
    @State private var minimumSplashElapsed = false

    @State private var composing = false
    @State private var decrypting = false
    @State private var addingRecipient = false
    @State private var showingMyQR = false
    @State private var showingSettings = false
    @State private var encryptingFile = false
    @State private var decryptingFile = false
    /// The recipient currently being renamed, if any. Drives the
    /// EditRecipientView sheet.
    @State private var recipientToEdit: Recipient?

    // MARK: App lock

    /// Whether the biometric/passcode lock is currently engaged. Starts
    /// locked on a cold launch when the lock is enabled; re-locked on
    /// foreground per `AppLockSettings.relockTimeout`. See `lockView`.
    @State private var isLocked = AppLockSettings.isEnabled
    /// When the app most recently went to the background, used to decide
    /// whether enough time has passed to re-lock on return.
    @State private var lastBackgrounded: Date?
    /// Guards against overlapping authentication prompts (the auto-prompt
    /// on appear plus a manual Unlock tap).
    @State private var authInProgress = false

    /// How long the splash stays up at minimum, regardless of how fast
    /// identity loading completes. Picked to give the rotating arc a
    /// little over half a revolution and the icon at least one breath cycle.
    private let minimumSplashDuration: Duration = .milliseconds(1100)

    var body: some View {
        Group {
            if shouldShowLock {
                lockView
            } else if let identity {
                if let envelope = appState.pendingDecryptEnvelope {
                    // Universal-Link launch (or a URL arriving while
                    // the app was in the background): render DecryptView
                    // as the *root* content rather than a sheet over
                    // mainContent. This skips the home-screen flash and
                    // the sheet animate-in, so the path from the splash
                    // to "decrypted message" is splash → DecryptView with
                    // a single fade transition. Done clears the pending
                    // envelope and SwiftUI re-renders mainContent.
                    DecryptView(
                        prefilledEnvelope: envelope,
                        onDone: { appState.pendingDecryptEnvelope = nil }
                    )
                    // Bind the view's identity to the envelope so a new
                    // URL arriving while DecryptView is already up causes
                    // SwiftUI to recreate it (and re-run its .task) for
                    // the new payload, instead of holding the stale one.
                    .id(envelope)
                    .transition(.opacity)
                } else if minimumSplashElapsed {
                    mainContent(identity: identity)
                        .transition(.opacity)
                } else {
                    splashView(
                        message: "Setting up your secure identity…",
                        showsProgress: true
                    )
                }
            } else if let identityErrorMessage {
                splashView(
                    message: identityErrorMessage,
                    showsProgress: false
                )
            } else {
                splashView(
                    message: "Setting up your secure identity…",
                    showsProgress: true
                )
            }
        }
        .animation(.easeInOut(duration: 0.25),
                   value: appState.pendingDecryptEnvelope)
        .animation(.easeInOut(duration: 0.2), value: isLocked)
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
        .task {
            // Run identity loading and the minimum splash delay in parallel;
            // we only fall through once whichever finishes last is done.
            //
            // Exception: if the app was launched (or resumed) by a
            // Universal Link, skip the artificial splash hold — the user
            // wants to see the decrypted message as fast as possible,
            // not wait for the splash to finish its breath cycle.
            async let identityWork: Void = loadIdentity()
            if appState.pendingDecryptEnvelope == nil {
                async let minimumDelay: Void = Task.sleep(for: minimumSplashDuration)
                await identityWork
                try? await minimumDelay
            } else {
                await identityWork
            }
            minimumSplashElapsed = true
        }
    }

    // MARK: - App lock

    /// Whether to cover the UI with the lock screen right now. Honours the
    /// master switch, the device's ability to authenticate (fail open if
    /// there's no biometric/passcode, so the user can't be locked out),
    /// and the scope toggle: an incoming message-link presentation is only
    /// gated when the user chose to cover incoming messages.
    private var shouldShowLock: Bool {
        guard isLocked,
              AppLockSettings.isEnabled,
              BiometricAuth.canAuthenticate() else { return false }
        if appState.pendingDecryptEnvelope != nil && !AppLockSettings.coversIncoming {
            return false
        }
        return true
    }

    /// Full-screen lock matching the splash visuals. Auto-prompts on
    /// appear and offers a manual retry button.
    private var lockView: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()
            VStack(spacing: 28) {
                Image("LaunchIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                Text("Exchange is locked")
                    .font(.headline)
                    .foregroundStyle(.white)
                Button {
                    Task { await attemptUnlock() }
                } label: {
                    Label("Unlock with \(BiometricAuth.biometryLabel())", systemImage: "lock.open.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
        }
        .preferredColorScheme(.dark)
        .task { await attemptUnlock() }
    }

    private func attemptUnlock() async {
        guard !authInProgress else { return }
        authInProgress = true
        defer { authInProgress = false }
        let ok = await BiometricAuth.authenticate(
            reason: "Unlock Exchange to read and send your encrypted messages."
        )
        if ok { isLocked = false }
    }

    /// Track background/foreground transitions to drive re-locking. We key
    /// the timestamp off `.background` (not `.inactive`) so the biometric
    /// prompt itself — which only makes the app inactive — doesn't trip an
    /// immediate re-lock loop.
    private func handleScenePhase(_ phase: ScenePhase) {
        guard AppLockSettings.isEnabled else { return }
        switch phase {
        case .background:
            if lastBackgrounded == nil { lastBackgrounded = Date.now }
        case .active:
            if let last = lastBackgrounded,
               let interval = AppLockSettings.relockTimeout.interval,
               Date.now.timeIntervalSince(last) >= interval {
                isLocked = true
            }
            lastBackgrounded = nil
        default:
            break
        }
    }

    // MARK: - Main content

    private func mainContent(identity: Identity) -> some View {
        NavigationStack {
            List {
                Section("My identity") {
                    identityDetail(identity: identity)
                    Button {
                        showingMyQR = true
                    } label: {
                        Label("Show QR code", systemImage: "qrcode")
                    }
                }
                Section("Recipients") {
                    if recipients.isEmpty {
                        Text("No recipients yet. Add someone's public key with the + button.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recipients) { recipient in
                            RecipientRow(recipient: recipient)
                                .contentShape(Rectangle())
                                .onTapGesture { recipientToEdit = recipient }
                                .contextMenu {
                                    Button {
                                        recipientToEdit = recipient
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        modelContext.delete(recipient)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .onDelete(perform: deleteRecipients)
                        .onMove(perform: moveRecipients)
                    }
                }
            }
            .navigationTitle("Exchange")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                // Enter edit mode to drag-reorder recipients (drag handles
                // appear) and to delete. Only useful once there's a list.
                if !recipients.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        decrypting = true
                    } label: {
                        Label("Decrypt", systemImage: "lock.open")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composing = true
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingRecipient = true
                    } label: {
                        Label("Add recipient", systemImage: "plus")
                    }
                }

                // File encryption/decryption tucked into an overflow menu
                // so the main bar stays focused on the text-message flow.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            encryptingFile = true
                        } label: {
                            Label("Encrypt file", systemImage: "doc.badge.plus")
                        }
                        Button {
                            decryptingFile = true
                        } label: {
                            Label("Decrypt file", systemImage: "doc.badge.gearshape")
                        }
                    } label: {
                        Label("Files", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $addingRecipient) {
                AddRecipientView()
            }
            .sheet(item: $recipientToEdit) { recipient in
                EditRecipientView(recipient: recipient)
            }
            .sheet(isPresented: $composing) {
                ComposeView()
            }
            .sheet(isPresented: $decrypting) {
                // Manual Decrypt button: no prefill — DecryptView's
                // clipboard auto-detect handles the case where the
                // user just copied an envelope from somewhere else.
                // Universal-Link envelopes are presented at the
                // ContentView root instead (see body), not via this sheet.
                DecryptView()
            }
            .sheet(isPresented: $encryptingFile) {
                EncryptFileView()
            }
            .sheet(isPresented: $decryptingFile) {
                DecryptFileView()
            }
            // A `.exc2` opened from another app ("Open in Exchange").
            .sheet(item: Binding(
                get: { appState.pendingDecryptFileURL.map { IdentifiableURL(url: $0) } },
                set: { appState.pendingDecryptFileURL = $0?.url }
            )) { item in
                DecryptFileView(
                    incomingFileURL: item.url,
                    onDone: { appState.pendingDecryptFileURL = nil }
                )
            }
            .sheet(isPresented: $showingMyQR) {
                MyIdentityQRView(identity: identity)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    identityFingerprint: identity.fingerprint.groupedHex,
                    onResetIdentity: { Task { await resetIdentity() } }
                )
            }
        }
    }

    private func identityDetail(identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Public key")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Identity.encode(publicBundle: identity.publicBundle))
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Fingerprint: \(identity.fingerprint.groupedHex)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Splash

    /// Full-screen view shown while we load (or generate) the identity.
    /// Uses the same colors and icon as the iOS launch screen so the
    /// hand-off from launch screen → SwiftUI is visually invisible.
    private func splashView(message: String, showsProgress: Bool) -> some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()
            VStack(spacing: 36) {
                if showsProgress {
                    AnimatedSplashIndicator()
                } else {
                    Image("LaunchIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                }
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Actions

    private func loadIdentity() async {
        do {
            let loaded = try IdentityStore.loadOrCreate()
            identity = loaded
            // Hand the (possibly newly-generated, possibly migrated)
            // identity to the recipients-sync coordinator so it can
            // pull any blob iCloud Keychain has for us and start
            // listening for changes to push back.
            await recipientsSync.bind(identity: loaded)
        } catch {
            identityErrorMessage = "Couldn't set up your identity: \(error.localizedDescription)"
        }
    }

    private func deleteRecipients(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(recipients[index])
        }
    }

    /// Apply a drag-reorder. SwiftData has no intrinsic ordering, so we
    /// materialise the new visual order and rewrite every row's
    /// `orderIndex` to its position (0, 1, 2, …). Each touched row is
    /// stamped with a fresh `updatedAt` so the sync merge propagates the
    /// new order to the user's other devices (latest write wins).
    private func moveRecipients(from source: IndexSet, to destination: Int) {
        var reordered = recipients
        reordered.move(fromOffsets: source, toOffset: destination)
        let now = Date.now
        for (position, recipient) in reordered.enumerated() where recipient.orderIndex != position {
            recipient.orderIndex = position
            recipient.updatedAt = now
        }
        try? modelContext.save()
    }

    /// Wipe the keychain identity and all recipients, then re-trigger
    /// identity loading so a fresh keypair is generated and the user
    /// returns to the splash → main flow without restarting the app.
    private func resetIdentity() async {
        // Drop the local handle first so the splash takes over the body
        // immediately while the wipe runs.
        identity = nil
        identityErrorMessage = nil
        // Clear the synchronised recipients blob *before* wiping the
        // identity — once the identity is gone, the coordinator can't
        // re-derive the key. This also prevents the next run (with a
        // fresh identity) from quietly silently reading stale ciphertext
        // it can't decrypt anyway.
        recipientsSync.wipeRemoteForReset()
        do {
            try IdentityStore.reset()
        } catch {
            identityErrorMessage = "Couldn't reset identity: \(error.localizedDescription)"
            return
        }
        for recipient in recipients {
            modelContext.delete(recipient)
        }
        try? modelContext.save()
        await loadIdentity()
    }
}

/// The launch icon (gently pulsing) wrapped by a rotating arc.
///
/// Two independent looping animations with different periods so they feel
/// organic rather than mechanically synced:
///   - the icon breathes between 1.00x and 1.04x scale every 2.8 s
///   - the arc rotates 360° every 1.8 s
///
/// Together they read as "alive and working" without being distracting.
private struct AnimatedSplashIndicator: View {
    @State private var pulsing = false
    @State private var rotating = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.22)
                .stroke(
                    Color.white.opacity(0.75),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 200, height: 200)
                .rotationEffect(.degrees(rotating ? 360 : 0))
                .animation(
                    .linear(duration: 1.8).repeatForever(autoreverses: false),
                    value: rotating
                )

            Image("LaunchIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .scaleEffect(pulsing ? 1.04 : 1.0)
                .animation(
                    .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: pulsing
                )
        }
        .onAppear {
            pulsing = true
            rotating = true
        }
    }
}

private struct RecipientRow: View {
    let recipient: Recipient

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipient.displayName)
                .font(.body)
            Text(recipient.fingerprintDisplay)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Recipient.self, inMemory: true)
        .environment(AppState())
}
