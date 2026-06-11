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
    // Same order as the home screen: manual drag-order first
    // (`orderIndex`), then newest-first as the tie-break. The picker used
    // to sort alphabetically, which didn't match what the user sees on the
    // main list.
    @Query(sort: [
        SortDescriptor(\Recipient.orderIndex, order: .forward),
        SortDescriptor(\Recipient.createdAt, order: .reverse),
    ])
    private var recipients: [Recipient]

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?

    @State private var selectedRecipient: Recipient?
    @State private var plaintext: String = ""
    @State private var envelope: String?
    @State private var errorMessage: String?

    /// Preferred representation for Copy / Share in the result view — the
    /// rich `exchange.nettrash.me/msg` link or the raw `EXC2:` envelope.
    /// Persisted so the choice sticks across messages.
    @AppStorage("compose.shareFormat") private var shareFormat: MessageShareFormat = .link

    /// Focus of the message editor. Lets the keyboard's Done button dismiss
    /// it so the "Encrypt & sign" button below isn't hidden by the keyboard.
    @FocusState private var messageFocused: Bool

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
                selectedRecipient = preferredInitialRecipient()
            }
        }
        // Remember the chosen recipient so the next Compose (here or in the
        // iMessage extension) pre-selects them.
        .onChange(of: selectedRecipient) { _, newValue in
            if let id = newValue?.id {
                AppConstants.saveLastRecipientID(id)
            }
        }
    }

    /// The recipient to pre-select when Compose opens: the one the user
    /// last composed to if they still exist, otherwise the first row in
    /// the list (which now matches the home-screen order).
    private func preferredInitialRecipient() -> Recipient? {
        if let id = AppConstants.loadLastRecipientID(),
           let match = recipients.first(where: { $0.id == id }) {
            return match
        }
        return recipients.first
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
                    .focused($messageFocused)
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
        // Keep the "Encrypt & sign" button reachable while the keyboard is
        // up: swipe to dismiss interactively, or tap Done on the keyboard
        // toolbar. Without this the button sits hidden behind the keyboard.
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { messageFocused = false }
            }
        }
    }

    @ViewBuilder
    private func resultView(envelope: String) -> some View {
        // The sealed envelope can be shared two ways (user's choice, which
        // we persist):
        //   • Link — wrapped as `https://exchange.nettrash.me/msg?...`,
        //     which makes iMessage / Telegram / Slack render a rich 🔒
        //     preview bubble and resolves via Universal Links to open
        //     Exchange directly on the recipient's side.
        //   • EXC2 — the raw `EXC2:<base64>` envelope, for plain-text
        //     channels or recipients who'd rather paste the blob.
        //
        // `EnvelopeURL.url(for:)` only returns nil for input lacking the
        // `EXC2:` prefix, which CryptoEnvelope.seal never produces — so the
        // fallback to the raw envelope is purely defensive.
        let url = EnvelopeURL.url(for: envelope)
        let usingLink = shareFormat == .link && url != nil
        let shareableString = usingLink ? url!.absoluteString : envelope

        Form {
            Section {
                Picker("Format", selection: $shareFormat) {
                    ForEach(MessageShareFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Format")
            } footer: {
                Text(usingLink
                     ? "A link that opens Exchange and decrypts in place — shows a 🔒 preview in iMessage and most messengers."
                     : "The raw EXC2: envelope — paste it into any text channel.")
            }

            Section {
                Text(shareableString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(nil)
            } header: {
                Text(usingLink ? "Encrypted message link" : "Encrypted envelope (EXC2)")
            } footer: {
                Text("Send this through any messenger — iMessage, Mail, Telegram, WhatsApp. Only \(selectedRecipient?.displayName ?? "the recipient") can read it, and they can verify it came from you.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = shareableString
                } label: {
                    Label("Copy to clipboard", systemImage: "doc.on.doc")
                }

                // Share a URL *value* (not a String) for the link form —
                // that's the signal the share sheet uses to route into the
                // link-preview path inside Messages. The EXC2 form shares
                // as plain text.
                if usingLink, let url {
                    ShareLink(item: url) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                } else {
                    ShareLink(item: shareableString) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
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

/// How a sealed message is handed off from the result view.
enum MessageShareFormat: String, CaseIterable, Identifiable {
    /// `https://exchange.nettrash.me/msg?...` — rich preview + Universal Link.
    case link
    /// Raw `EXC2:<base64>` envelope.
    case envelope

    var id: String { rawValue }

    var label: String {
        switch self {
        case .link:     return "Link"
        case .envelope: return "EXC2"
        }
    }
}

#Preview {
    ComposeView()
        .modelContainer(for: Recipient.self, inMemory: true)
}
