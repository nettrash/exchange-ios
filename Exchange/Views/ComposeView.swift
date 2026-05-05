//
//  ComposeView.swift
//  Exchange
//
//  Encrypt-and-sign-a-message flow.
//
//  Pick a recipient, type plaintext, tap Encrypt. The view swaps to a
//  result section showing the EXC2: envelope (signed by your identity,
//  encrypted to the recipient) with Copy / Share buttons.
//

import CryptoKit
import SwiftData
import SwiftUI
import UIKit

struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Recipient.displayName)])
    private var recipients: [Recipient]

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?

    @State private var selectedRecipient: Recipient?
    @State private var plaintext: String = ""
    @State private var envelope: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if recipients.isEmpty {
                    emptyState
                } else if let envelope {
                    resultView(envelope: envelope)
                } else if let identity {
                    composeForm(identity: identity)
                } else if let identityErrorMessage {
                    Text(identityErrorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    ProgressView("Loading identity…")
                }
            }
            .navigationTitle("Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(envelope == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .task {
            await loadIdentity()
            if selectedRecipient == nil {
                selectedRecipient = recipients.first
            }
        }
    }

    // MARK: - Sub-views

    private var emptyState: some View {
        ContentUnavailableView(
            "No recipients yet",
            systemImage: "person.crop.circle.badge.plus",
            description: Text("Add a recipient's public key bundle from the home screen first, then come back to send them an encrypted message.")
        )
    }

    private func composeForm(identity: Identity) -> some View {
        Form {
            Section("Recipient") {
                Picker("Recipient", selection: $selectedRecipient) {
                    ForEach(recipients) { recipient in
                        Text(recipient.displayName).tag(Optional(recipient))
                    }
                }
                .pickerStyle(.menu)

                if let selectedRecipient {
                    Text(selectedRecipient.fingerprintDisplay)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextEditor(text: $plaintext)
                    .frame(minHeight: 160)
            } header: {
                Text("Message")
            } footer: {
                Text("Plaintext stays on this device. The envelope that leaves is encrypted to your recipient and signed by your identity.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    encrypt(with: identity)
                } label: {
                    Label("Encrypt & sign", systemImage: "lock.fill")
                }
                .disabled(selectedRecipient == nil || plaintext.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func resultView(envelope: String) -> some View {
        Form {
            Section {
                Text(envelope)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(nil)
            } header: {
                Text("Encrypted envelope")
            } footer: {
                Text("Send this through any messenger — iMessage, Mail, Telegram, WhatsApp. Only \(selectedRecipient?.displayName ?? "the recipient") can read it, and they can verify it came from you.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = envelope
                } label: {
                    Label("Copy to clipboard", systemImage: "doc.on.doc")
                }

                ShareLink(item: envelope) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Button("Encrypt another message") {
                    self.envelope = nil
                    self.plaintext = ""
                    self.errorMessage = nil
                }
            }
        }
    }

    // MARK: - Actions

    private func loadIdentity() async {
        do {
            identity = try IdentityStore.loadOrCreate()
        } catch {
            identityErrorMessage = "Couldn't load identity: \(error.localizedDescription)"
        }
    }

    private func encrypt(with identity: Identity) {
        guard let recipient = selectedRecipient,
              let bundle = recipient.publicBundle else {
            errorMessage = "Couldn't read this recipient's public key. The stored data may be corrupt — try removing and re-adding the recipient."
            return
        }
        do {
            let result = try CryptoEnvelope.seal(
                plaintext: Data(plaintext.utf8),
                to: bundle.encryptionPublicKey,
                from: identity
            )
            envelope = result
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't encrypt: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ComposeView()
        .modelContainer(for: Recipient.self, inMemory: true)
}
