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
    @Query(sort: [SortDescriptor(\Recipient.createdAt, order: .reverse)])
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

    /// How long the splash stays up at minimum, regardless of how fast
    /// identity loading completes. Picked to give the rotating arc a
    /// little over half a revolution and the icon at least one breath cycle.
    private let minimumSplashDuration: Duration = .milliseconds(1100)

    var body: some View {
        Group {
            if let identity, minimumSplashElapsed {
                mainContent(identity: identity)
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
        .task {
            // Run identity loading and the minimum splash delay in parallel;
            // we only fall through once whichever finishes last is done.
            async let identityWork: Void = loadIdentity()
            async let minimumDelay: Void = Task.sleep(for: minimumSplashDuration)
            await identityWork
            try? await minimumDelay
            minimumSplashElapsed = true
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
                        }
                        .onDelete(perform: deleteRecipients)
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
            }
            .sheet(isPresented: $addingRecipient) {
                AddRecipientView()
            }
            .sheet(isPresented: $composing) {
                ComposeView()
            }
            .sheet(isPresented: $decrypting) {
                DecryptView()
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
            identity = try IdentityStore.loadOrCreate()
        } catch {
            identityErrorMessage = "Couldn't set up your identity: \(error.localizedDescription)"
        }
    }

    private func deleteRecipients(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(recipients[index])
        }
    }

    /// Wipe the keychain identity and all recipients, then re-trigger
    /// identity loading so a fresh keypair is generated and the user
    /// returns to the splash → main flow without restarting the app.
    private func resetIdentity() async {
        // Drop the local handle first so the splash takes over the body
        // immediately while the wipe runs.
        identity = nil
        identityErrorMessage = nil
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
}
