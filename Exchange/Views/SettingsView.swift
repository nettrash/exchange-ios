//
//  SettingsView.swift
//  Exchange
//
//  Sheet shown from the home-screen toolbar's gear button. Surfaces the
//  basics App Reviewers expect: version + build, links to privacy policy
//  and support, and a destructive Reset identity action.
//
//  The reset action is provided as a callback so the parent (ContentView)
//  can coordinate the wipe + re-load flow against its own state — wiping
//  the keychain item, deleting all recipients, and re-triggering the
//  identity load.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Display-friendly identity fingerprint for visual confirmation.
    let identityFingerprint: String

    /// Called when the user confirms the destructive reset.
    let onResetIdentity: () -> Void

    @State private var showingResetConfirmation = false

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
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
