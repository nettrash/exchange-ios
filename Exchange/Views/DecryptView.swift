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

    /// Optional envelope to pre-fill the text field with — used when the
    /// view is opened from a Universal Link (`.onOpenURL` in ExchangeApp)
    /// so the user doesn't have to paste anything. Nil for a regular
    /// Decrypt sheet, where the clipboard auto-fill path takes over.
    var prefilledEnvelope: String? = nil

    /// Optional close handler — replaces the default `dismiss()` action
    /// when set. ContentView passes this in when DecryptView is rendered
    /// as the root content for the Universal-Link flow (where there's no
    /// presenting sheet to dismiss); the closure clears the pending
    /// envelope so ContentView can fall back to its main UI.
    var onDone: (() -> Void)? = nil

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?

    @State private var envelopeText: String = ""
    @State private var plaintext: String?
    @State private var binaryByteCount: Int?
    @State private var senderDisplayName: String?
    @State private var senderFingerprintHex: String?
    @State private var errorMessage: String?

    /// Tracks whether the prefilled-envelope decrypt path has run yet.
    /// Used to suppress a brief flash of the raw input form (with the
    /// URL/EXC2 text visible) between identity-load and decrypt-complete
    /// when the view was opened from a Universal Link. While this is
    /// false and `prefilledEnvelope` is set, we render a "Decrypting…"
    /// placeholder instead of the input form.
    @State private var initialDecryptAttempted = false

    var body: some View {
        NavigationStack {
            Group {
                if let identity {
                    if plaintext != nil || binaryByteCount != nil {
                        resultView
                    } else if prefilledEnvelope != nil
                                && !initialDecryptAttempted
                                && errorMessage == nil {
                        // Universal-Link path: identity is ready but
                        // decrypt hasn't completed (or hasn't started)
                        // yet. Show a focused "Decrypting…" indicator
                        // so the user never sees the raw URL or EXC2:
                        // text we'd otherwise drop into the input form.
                        decryptingPlaceholder
                    } else {
                        inputForm(identity: identity)
                    }
                } else if let identityErrorMessage {
                    Text(identityErrorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else if prefilledEnvelope != nil {
                    // Cold start from a Universal Link — the splash in
                    // ContentView normally covers this state, but if the
                    // view ever renders before identity is ready (e.g.
                    // re-presentation), keep the visual continuous with
                    // the eventual "Decrypting…" placeholder rather than
                    // a generic spinner with stale wording.
                    decryptingPlaceholder
                } else {
                    ProgressView("Loading identity…")
                }
            }
            .navigationTitle("Decrypt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button((plaintext == nil && binaryByteCount == nil) ? "Cancel" : "Done") {
                        if let onDone {
                            onDone()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .task {
            await loadIdentity()
            // Universal Link path: an envelope was passed in via
            // ExchangeApp's .onOpenURL handler. Pre-fill the field
            // and decrypt immediately — the user taps once to open
            // the sheet from outside the app, sees the result, done.
            if let prefilledEnvelope, envelopeText.isEmpty {
                envelopeText = prefilledEnvelope
                if let identity {
                    decrypt(with: identity)
                }
                initialDecryptAttempted = true
                return
            }
            // No incoming URL: fall back to the clipboard auto-fill.
            // If the clipboard already holds an Exchange envelope (raw
            // EXC2: text or our URL form copied from Messages.app on
            // Mac, etc.), pre-fill the field so the user just taps Decrypt.
            autoFillFromClipboardIfPossible()
        }
    }

    /// Centred "Decrypting…" indicator shown while a Universal-Link
    /// envelope is being processed. Visually focused so the user feels
    /// the app is actively working on their tap rather than waiting on
    /// them for input.
    private var decryptingPlaceholder: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Decrypting…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text("EXC2: blob or a Messages.app link starting with https://exchange.nettrash.me/msg.")
            }

            Section {
                Button {
                    if let pasted = UIPasteboard.general.string {
                        envelopeText = EnvelopeURL.envelopeIfPresent(in: pasted) ?? pasted
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

    /// Read the system pasteboard, normalize an Exchange envelope (raw
    /// or URL form) if present, and pre-fill the text field. No-op if
    /// the clipboard doesn't hold one. Called once on first appear.
    private func autoFillFromClipboardIfPossible() {
        guard envelopeText.isEmpty else { return }
        guard let pasted = UIPasteboard.general.string else { return }
        if let envelope = EnvelopeURL.envelopeIfPresent(in: pasted) {
            envelopeText = envelope
        }
    }

    private func decrypt(with identity: Identity) {
        do {
            // Normalize: accept a URL paste (https://exchange.nettrash.me/msg?...)
            // by extracting the embedded envelope before handing to CryptoEnvelope.
            let canonical = EnvelopeURL.envelopeIfPresent(in: envelopeText) ?? envelopeText
            let opened = try CryptoEnvelope.open(envelope: canonical, with: identity)
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
