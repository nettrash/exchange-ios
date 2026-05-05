//
//  DecryptView.swift
//  Exchange
//
//  Paste-and-decrypt flow.
//
//  User pastes an EXC2: envelope (or pulls one from the clipboard with one
//  tap), Decrypt runs it through CryptoEnvelope.open against the local
//  identity, and the plaintext appears with a Copy button. The view also
//  matches the sender's signing public key against the saved Recipient
//  list so it can show "From Alice" instead of just an opaque fingerprint.
//

import CryptoKit
import SwiftData
import SwiftUI
import UIKit

struct DecryptView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var recipients: [Recipient]

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?

    @State private var envelopeText: String = ""
    @State private var plaintext: String?
    @State private var binaryByteCount: Int?
    @State private var senderDisplayName: String?
    @State private var senderFingerprintHex: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let identity {
                    if plaintext != nil || binaryByteCount != nil {
                        resultView
                    } else {
                        inputForm(identity: identity)
                    }
                } else if let identityErrorMessage {
                    Text(identityErrorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    ProgressView("Loading identity…")
                }
            }
            .navigationTitle("Decrypt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button((plaintext == nil && binaryByteCount == nil) ? "Cancel" : "Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadIdentity()
        }
    }

    // MARK: - Sub-views

    private func inputForm(identity: Identity) -> some View {
        Form {
            Section {
                TextEditor(text: $envelopeText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 160)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Paste an Exchange envelope")
            } footer: {
                Text("Anything starting with EXC2: that was sent to your identity.")
            }

            Section {
                Button {
                    if let pasted = UIPasteboard.general.string {
                        envelopeText = pasted
                    }
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    decrypt(with: identity)
                } label: {
                    Label("Decrypt", systemImage: "lock.open")
                }
                .disabled(envelopeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var resultView: some View {
        Form {
            Section {
                if let plaintext {
                    Text(plaintext)
                        .textSelection(.enabled)
                } else if let binaryByteCount {
                    Text("(Binary content, \(binaryByteCount) bytes — not displayable as text.)")
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
                Button("Decrypt another envelope") {
                    plaintext = nil
                    binaryByteCount = nil
                    senderDisplayName = nil
                    senderFingerprintHex = nil
                    envelopeText = ""
                    errorMessage = nil
                }
            }
        }
    }

    @ViewBuilder
    private var senderFooter: some View {
        if let senderDisplayName {
            Text("Signature verified — from \(senderDisplayName).")
        } else if let senderFingerprintHex {
            Text("Signature verified, but the sender's signing key (fingerprint \(senderFingerprintHex)) doesn't match anyone in your recipients. Add them to confirm their identity.")
        } else {
            Text("Verified as addressed to your identity.")
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

    private func decrypt(with identity: Identity) {
        do {
            let opened = try CryptoEnvelope.open(envelope: envelopeText, with: identity)
            if let text = String(data: opened.plaintext, encoding: .utf8) {
                plaintext = text
                binaryByteCount = nil
            } else {
                plaintext = nil
                binaryByteCount = opened.plaintext.count
            }
            // Match sender by signing-key bytes against the saved recipient list.
            if let match = recipients.first(where: { $0.signingPublicKeyData == opened.senderSigningPublicKey }) {
                senderDisplayName = match.displayName
                senderFingerprintHex = nil
            } else {
                senderDisplayName = nil
                let digest = SHA256.hash(data: opened.senderSigningPublicKey)
                senderFingerprintHex = Data(digest.prefix(8)).groupedHex
            }
            errorMessage = nil
        } catch let error as CryptoEnvelope.Error {
            errorMessage = describe(error)
        } catch {
            errorMessage = "Couldn't decrypt: \(error.localizedDescription)"
        }
    }

    private func describe(_ error: CryptoEnvelope.Error) -> String {
        switch error {
        case .malformedEnvelope:
            return "This doesn't look like an Exchange envelope (expected EXC2: prefix and a base64 body)."
        case .unsupportedVersion(let version):
            return "Unsupported envelope version: 0x\(String(version, radix: 16)). You may need a newer build of Exchange."
        case .fingerprintMismatch:
            return "This message wasn't sent to your identity. Either it's for someone else, or your identity has changed since the sender encrypted it."
        case .signatureVerificationFailed:
            return "The sender's signature didn't verify. The envelope was tampered with after it was signed."
        case .decryptionFailed:
            return "The message is corrupt or has been tampered with after it was sent."
        }
    }
}

#Preview {
    DecryptView()
        .modelContainer(for: Recipient.self, inMemory: true)
}
