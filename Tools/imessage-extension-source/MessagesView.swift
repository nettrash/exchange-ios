//
//  MessagesView.swift
//  MessagesExtension
//
//  SwiftUI shell hosted by MessagesViewController. Drives off a single
//  @Observable model whose `.state` enum decides which sub-view renders:
//  loading, compose, decrypted-plaintext, decrypted-binary, error.
//
//  All callbacks bubble up to the view controller, which owns the
//  MSConversation lifecycle (insert, dismiss, expand).
//

import CryptoKit
import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

// MARK: - Sender display

/// How the recipient should describe whoever signed the envelope they
/// just opened. Either a known contact's name or a short hex
/// fingerprint of the signing key (when the sender isn't in their list).
enum SenderDisplay: Equatable {
    case knownRecipient(String)
    case fingerprint(String)

    var displayString: String {
        switch self {
        case .knownRecipient(let name): return name
        case .fingerprint(let hex):     return "fingerprint \(hex)"
        }
    }
}

// MARK: - Recipient snapshot

/// Plain-value copy of a `Recipient`. The iMessage extension reads the
/// SwiftData store on each compose pass, snapshots into these structs,
/// and hands the array to SwiftUI. Keeps the SwiftUI tree decoupled
/// from the @Model object's context lifecycle.
struct RecipientSnapshot: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let encryptionPublicKeyData: Data
    let signingPublicKeyData: Data
    let fingerprintDisplay: String

    init?(from recipient: Recipient) {
        guard let bundle = recipient.publicBundle else { return nil }
        self.id = recipient.id
        self.displayName = recipient.displayName
        self.encryptionPublicKeyData = bundle.encryptionPublicKey.rawRepresentation
        self.signingPublicKeyData = bundle.signingPublicKey.rawRepresentation
        self.fingerprintDisplay = recipient.fingerprintDisplay
    }
}

// MARK: - Model

@Observable
final class MessagesAppModel {
    enum State: Equatable {
        case loading
        case compose
        case decryptedPlaintext(text: String, sender: SenderDisplay)
        case decryptedBinary(byteCount: Int, sender: SenderDisplay)
        case error(String)
    }

    var state: State = .loading
    var recipients: [RecipientSnapshot] = []
    var identity: Identity?
}

// MARK: - Main view

struct MessagesView: View {
    @Bindable var model: MessagesAppModel
    let onSend: (_ envelope: String, _ recipientName: String) -> Void
    let onRequestExpand: () -> Void
    let onDone: () -> Void
    let modelContainer: ModelContainer?

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                loadingView
            case .compose:
                ComposeForm(
                    recipients: model.recipients,
                    identity: model.identity,
                    onSend: onSend,
                    onRequestExpand: onRequestExpand
                )
            case .decryptedPlaintext(let text, let sender):
                DecryptResult(
                    plaintext: text,
                    sender: sender,
                    onDone: onDone
                )
            case .decryptedBinary(let byteCount, let sender):
                DecryptResult(
                    plaintext: nil,
                    binaryByteCount: byteCount,
                    sender: sender,
                    onDone: onDone
                )
            case .error(let message):
                ErrorView(message: message, onDone: onDone)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Compose

private struct ComposeForm: View {
    let recipients: [RecipientSnapshot]
    let identity: Identity?
    let onSend: (String, String) -> Void
    let onRequestExpand: () -> Void

    @State private var selectedRecipientID: UUID?
    @State private var plaintext: String = ""
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if recipients.isEmpty {
                ContentUnavailableView(
                    "No recipients yet",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Open the Exchange app to add a recipient first, then come back here to send them an encrypted message.")
                )
            } else {
                Form {
                    Section("Recipient") {
                        Picker("Recipient", selection: $selectedRecipientID) {
                            ForEach(recipients) { recipient in
                                Text(recipient.displayName).tag(Optional(recipient.id))
                            }
                        }
                        .pickerStyle(.menu)
                        if let selected {
                            Text(selected.fingerprintDisplay)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        TextEditor(text: $plaintext)
                            .frame(minHeight: 120)
                            .onTapGesture {
                                onRequestExpand()
                            }
                    } header: {
                        Text("Message")
                    } footer: {
                        Text("Encrypted to your recipient and signed by your identity.")
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red)
                        }
                    }

                    Section {
                        Button {
                            encryptAndSend()
                        } label: {
                            Label("Encrypt & insert", systemImage: "lock.fill")
                        }
                        .disabled(!canSend)
                    }
                }
            }
        }
        .onAppear {
            if selectedRecipientID == nil {
                selectedRecipientID = recipients.first?.id
            }
        }
    }

    private var selected: RecipientSnapshot? {
        recipients.first { $0.id == selectedRecipientID }
    }

    private var canSend: Bool {
        identity != nil && selected != nil && !plaintext.isEmpty
    }

    private func encryptAndSend() {
        guard let identity, let recipient = selected else { return }
        guard let encryptionKey = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: recipient.encryptionPublicKeyData
        ) else {
            errorMessage = "Couldn't read this recipient's encryption key."
            return
        }
        do {
            let envelope = try CryptoEnvelope.seal(
                plaintext: Data(plaintext.utf8),
                to: encryptionKey,
                from: identity
            )
            errorMessage = nil
            onSend(envelope, recipient.displayName)
        } catch {
            errorMessage = "Couldn't encrypt: \(error.localizedDescription)"
        }
    }
}

// MARK: - Decrypt result

private struct DecryptResult: View {
    let plaintext: String?
    var binaryByteCount: Int?
    let sender: SenderDisplay
    let onDone: () -> Void

    var body: some View {
        Form {
            Section {
                if let plaintext {
                    Text(plaintext)
                        .textSelection(.enabled)
                } else if let binaryByteCount {
                    Text("Binary content, \(binaryByteCount) bytes — not displayable as text.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Decrypted message")
            } footer: {
                senderFooter
            }

            if let plaintext {
                Section {
                    Button {
                        UIPasteboard.general.string = plaintext
                    } label: {
                        Label("Copy plaintext", systemImage: "doc.on.doc")
                    }
                }
            }

            Section {
                Button("Done") { onDone() }
            }
        }
    }

    @ViewBuilder
    private var senderFooter: some View {
        switch sender {
        case .knownRecipient(let name):
            Text("Signature verified — from \(name).")
        case .fingerprint(let hex):
            Text("Signature verified, but the sender's signing key (fingerprint \(hex)) doesn't match anyone in your recipients. Add them in the Exchange app to confirm their identity.")
        }
    }
}

// MARK: - Error

private struct ErrorView: View {
    let message: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Done") { onDone() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
