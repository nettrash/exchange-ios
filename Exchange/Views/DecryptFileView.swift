//
//  DecryptFileView.swift
//  Exchange
//
//  Decrypt-a-file flow. Pick an `.exc2` file, Exchange opens it against
//  your identity, and — if it carries a file (FilePayload magic) — restores
//  the original filename + bytes for you to save. If it's actually a text
//  message, it falls back to showing the text.
//

import CryptoKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DecryptFileView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var recipients: [Recipient]

    /// Optional file URL to open immediately — set when the view is shown
    /// for an `.exc2` opened from another app ("Open in Exchange").
    var incomingFileURL: URL? = nil
    var onDone: (() -> Void)? = nil

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?
    @State private var errorMessage: String?

    // Restored-file result.
    @State private var restoredURL: URL?
    @State private var restoredName: String?
    @State private var restoredByteCount: Int = 0
    // Plain-text fallback (the envelope wasn't a file after all).
    @State private var plaintextMessage: String?
    @State private var binaryByteCount: Int?
    // Sender verification.
    @State private var senderDisplayName: String?
    @State private var senderFingerprintHex: String?

    private var hasResult: Bool {
        restoredURL != nil || plaintextMessage != nil || binaryByteCount != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let identity {
                    if hasResult {
                        resultView
                    } else {
                        inputView(identity: identity)
                    }
                } else if let identityErrorMessage {
                    Text(identityErrorMessage).foregroundStyle(.red).padding()
                } else {
                    ProgressView("Loading identity…")
                }
            }
            .navigationTitle("Decrypt file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(hasResult ? "Done" : "Cancel") {
                        if let onDone { onDone() } else { dismiss() }
                    }
                }
            }
        }
        .task {
            await loadIdentity()
            // Opened from another app: decrypt the handed-in file at once.
            if let incomingFileURL, let identity {
                decrypt(fileURL: incomingFileURL, identity: identity)
            }
        }
    }

    // MARK: - Sub-views

    private func inputView(identity: Identity) -> some View {
        Form {
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
            Section {
                Button {
                    DocumentPicker.pick(contentTypes: [.item, .data, .text, .plainText]) { url in
                        decrypt(fileURL: url, identity: identity)
                    }
                } label: {
                    Label("Choose .exc2 file…", systemImage: "doc.badge.gearshape")
                }
            } footer: {
                Text("Pick an encrypted .exc2 file someone sent you. Exchange decrypts it against your identity and restores the original file.")
            }
        }
    }

    @ViewBuilder
    private var resultView: some View {
        Form {
            if let restoredURL {
                Section {
                    LabeledContent("File", value: restoredName ?? "—")
                    LabeledContent("Size", value: byteCountString(restoredByteCount))
                } header: {
                    Text("Decrypted file")
                } footer: {
                    senderFooter
                }
                Section {
                    ShareLink(item: restoredURL) {
                        Label("Save / share file…", systemImage: "square.and.arrow.down")
                    }
                }
            } else {
                Section {
                    if let plaintextMessage {
                        Text(plaintextMessage).textSelection(.enabled)
                    } else if let binaryByteCount {
                        Text("(Binary content, \(byteCountString(binaryByteCount)) — not a file or text.)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Decrypted message")
                } footer: {
                    senderFooter
                }
            }

            Section {
                Button("Decrypt another file") { resetResult() }
            }
        }
    }

    @ViewBuilder
    private var senderFooter: some View {
        if let senderDisplayName {
            Text("Signature verified — from \(senderDisplayName).")
        } else if let senderFingerprintHex {
            Text("Signature verified, but the sender's key (fingerprint \(senderFingerprintHex)) doesn't match anyone in your recipients. Add them to confirm their identity.")
        } else {
            Text("Verified as addressed to your identity.")
        }
    }

    // MARK: - Actions

    private func decrypt(fileURL: URL, identity: Identity) {
        errorMessage = nil
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let raw = try Data(contentsOf: fileURL)
            guard let text = String(data: raw, encoding: .utf8) else {
                errorMessage = "That doesn't look like an Exchange file."
                return
            }
            let canonical = EnvelopeURL.envelopeIfPresent(in: text) ?? text
            let opened = try CryptoEnvelope.open(envelope: canonical, with: identity)
            resolveSender(opened.senderSigningPublicKey)

            if let file = FilePayload.decode(opened.plaintext) {
                let outURL = try writeRestoredFile(name: file.filename, content: file.content)
                restoredName = (file.filename as NSString).lastPathComponent
                restoredByteCount = file.content.count
                restoredURL = outURL
            } else if let message = String(data: opened.plaintext, encoding: .utf8) {
                plaintextMessage = message
            } else {
                binaryByteCount = opened.plaintext.count
            }
        } catch let error as CryptoEnvelope.Error {
            errorMessage = describe(error)
        } catch {
            errorMessage = "Couldn't decrypt that file: \(error.localizedDescription)"
        }
    }

    private func resolveSender(_ senderSigningPublicKey: Data) {
        if let match = recipients.first(where: { $0.signingPublicKeyData == senderSigningPublicKey }) {
            senderDisplayName = match.displayName
            senderFingerprintHex = nil
        } else {
            senderDisplayName = nil
            let digest = SHA256.hash(data: senderSigningPublicKey)
            senderFingerprintHex = Data(digest.prefix(8)).groupedHex
        }
    }

    /// Write the restored bytes to a temp file under the original name.
    private func writeRestoredFile(name: String, content: Data) throws -> URL {
        let safeName = (name as NSString).lastPathComponent
        let finalName = safeName.isEmpty ? "decrypted-file" : safeName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(finalName)
        try? FileManager.default.removeItem(at: url)
        try content.write(to: url)
        return url
    }

    private func resetResult() {
        restoredURL = nil
        restoredName = nil
        plaintextMessage = nil
        binaryByteCount = nil
        senderDisplayName = nil
        senderFingerprintHex = nil
        errorMessage = nil
    }

    private func loadIdentity() async {
        do { identity = try IdentityStore.loadOrCreate() }
        catch { identityErrorMessage = "Couldn't load identity: \(error.localizedDescription)" }
    }

    private func byteCountString(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func describe(_ error: CryptoEnvelope.Error) -> String {
        switch error {
        case .malformedEnvelope:
            return "This doesn't look like an Exchange file (expected an EXC2 envelope)."
        case .unsupportedVersion(let version):
            return "Unsupported version: 0x\(String(version, radix: 16)). You may need a newer build of Exchange."
        case .fingerprintMismatch:
            return "This file wasn't encrypted to your identity. It's for someone else, or your identity changed since it was sealed."
        case .signatureVerificationFailed:
            return "The sender's signature didn't verify. The file was tampered with after signing."
        case .decryptionFailed:
            return "The file is corrupt or was tampered with after it was sealed."
        }
    }
}

#Preview {
    DecryptFileView()
        .modelContainer(for: Recipient.self, inMemory: true)
}
