//
//  SettingsView.swift
//  Exchange
//
//  Sheet shown from the home-screen toolbar's gear button.
//
//  Layout:
//
//    1. Identity — fingerprint readout.
//    2. Identity sync — toggle bound to IdentityStore.setSyncEnabled.
//       Default ON in v1.1: identity rides iCloud Keychain across the
//       user's same-Apple-ID devices. Toggle OFF to opt back in to the
//       v1.0 device-only behaviour.
//    3. Backup & restore — passphrase-encrypted Export / Import, plus
//       the in-person QR Send / Receive flows.
//    4. About / Links — version, privacy policy, support page.
//    5. Reset identity — destructive, with explicit confirmation.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RecipientsSyncCoordinator.self) private var recipientsSync

    /// Display-friendly identity fingerprint for visual confirmation.
    let identityFingerprint: String

    /// Called when the user confirms the destructive reset.
    let onResetIdentity: () -> Void

    @State private var showingResetConfirmation = false

    // Sheet routers for the four backup / transfer flows.
    @State private var showingExport = false
    @State private var showingImport = false
    @State private var showingSendQR = false
    @State private var showingReceiveQR = false

    // iCloud-Keychain sync toggle — initial value is loaded from
    // IdentityStore in `task`. The Bool can only be flipped *after* the
    // load completes; an explicit nil sentinel before that prevents the
    // toggle from rendering with a stale "OFF" state during boot.
    @State private var syncEnabled: Bool?
    @State private var syncToggleErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    LabeledContent("Fingerprint") {
                        Text(identityFingerprint)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                identitySyncSection

                recipientsSyncSection

                Section {
                    Button {
                        showingExport = true
                    } label: {
                        Label("Export identity (passphrase)", systemImage: "lock.doc")
                    }
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import identity (passphrase)", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showingSendQR = true
                    } label: {
                        Label("Send identity (QR code)", systemImage: "qrcode")
                    }
                    Button {
                        showingReceiveQR = true
                    } label: {
                        Label("Receive identity (Scan QR)", systemImage: "qrcode.viewfinder")
                    }
                } header: {
                    Text("Backup & transfer")
                } footer: {
                    Text("Export creates a passphrase-encrypted blob you can keep in a password manager and import on another device. Send/Receive QR transfers the identity in person between two devices held by you — faster than passphrase, but only safe if both phones are physically with you.")
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: appBuild)
                }

                Section("Links") {
                    Link(destination: AppConstants.privacyPolicyURL) {
                        HStack {
                            Label("Privacy Policy", systemImage: "hand.raised.fill")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: AppConstants.supportURL) {
                        HStack {
                            Label("Support", systemImage: "questionmark.circle.fill")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset identity", systemImage: "trash.fill")
                    }
                } footer: {
                    Text("Wipes your private key and every saved recipient. A new identity is generated on the next launch. Anything previously encrypted to your old key becomes unreadable. This cannot be undone.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Reset identity?", isPresented: $showingResetConfirmation) {
                Button("Reset", role: .destructive) {
                    onResetIdentity()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your private key and all saved recipients will be deleted. A new identity will be generated. Messages previously sent to your old identity will be unrecoverable. This cannot be undone.")
            }
            .sheet(isPresented: $showingExport) {
                ExportIdentityView()
            }
            .sheet(isPresented: $showingImport) {
                ImportIdentityView()
            }
            .sheet(isPresented: $showingSendQR) {
                ShowIdentityQRTransferView()
            }
            .sheet(isPresented: $showingReceiveQR) {
                ScanIdentityQRTransferView()
            }
        }
        .task {
            await loadSyncState()
        }
    }

    // MARK: - Identity-sync section

    @ViewBuilder
    private var identitySyncSection: some View {
        Section {
            if let syncEnabled {
                Toggle("Sync via iCloud Keychain", isOn: Binding(
                    get: { syncEnabled },
                    set: { newValue in
                        Task { await applySync(newValue) }
                    }
                ))
            } else {
                HStack {
                    Text("Sync via iCloud Keychain")
                    Spacer()
                    ProgressView()
                }
            }
            if let syncToggleErrorMessage {
                Text(syncToggleErrorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("Identity sync")
        } footer: {
            Text("When on, your identity is carried across the devices signed into your Apple ID via iCloud Keychain (which is itself end-to-end encrypted). This lets iPhone and Mac share one identity, and a new device picks it up automatically. Turn off to keep the private key pinned to this device only — anything encrypted to your old key on a lost device stays unreadable, but you'll generate a fresh identity on each install.")
        }
    }

    // MARK: - Recipients-sync section

    @ViewBuilder
    private var recipientsSyncSection: some View {
        Section {
            Toggle("Sync recipients", isOn: Binding(
                get: { recipientsSync.syncEnabled },
                set: { newValue in recipientsSync.setSyncEnabled(newValue) }
            ))
            if let lastError = recipientsSync.lastErrorMessage {
                Text(lastError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("Recipients sync")
        } footer: {
            Text("When on, your saved recipients are encrypted with a key derived from your identity and the resulting blob rides iCloud Keychain alongside the identity itself. Apple sees only ciphertext — display names, public keys, and notes are end-to-end encrypted between your devices. Adding or removing a recipient on one device propagates to the others within a few seconds. Two devices changing recipients in the same minute may overwrite each other's changes; this is rare in practice for personal use.")
        }
    }

    // MARK: - Sync state plumbing

    private func loadSyncState() async {
        do {
            syncEnabled = try IdentityStore.isSyncEnabled()
        } catch {
            syncToggleErrorMessage = "Couldn't read sync state: \(error.localizedDescription)"
            syncEnabled = false
        }
    }

    private func applySync(_ enabled: Bool) async {
        syncToggleErrorMessage = nil
        do {
            try IdentityStore.setSyncEnabled(enabled)
            syncEnabled = enabled
        } catch {
            syncToggleErrorMessage = "Couldn't change sync setting: \(error.localizedDescription)"
            // Re-read whatever the keychain actually settled on so the
            // toggle reflects truth rather than the user's intent.
            syncEnabled = (try? IdentityStore.isSyncEnabled()) ?? syncEnabled
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
