//
//  EncryptFileView.swift
//  Exchange
//
//  Encrypt-a-file flow. Pick a recipient, pick a file, and Exchange seals
//  the file (name + bytes) into an `EXC2:` envelope written to a `.exc2`
//  file you can send through any app. Reuses the same crypto as text
//  messages — the file just rides inside the envelope's plaintext (see
//  FilePayload).
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct EncryptFileView: View {
    @Environment(\.dismiss) private var dismiss
    // Same order as the home screen / Compose.
    @Query(sort: [
        SortDescriptor(\Recipient.orderIndex, order: .forward),
        SortDescriptor(\Recipient.createdAt, order: .reverse),
    ])
    private var recipients: [Recipient]

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?
    @State private var selectedRecipient: Recipient?

    @State private var errorMessage: String?

    /// Set once a file has been encrypted: the temp `.exc2` to share.
    @State private var outputURL: URL?
    @State private var sourceName: String?
    @State private var outputByteCount: Int = 0

    /// Soft warning threshold — encryption is in-memory, so very large
    /// files are slow/heavy. We warn but don't block.
    private let warnSizeBytes = 20 * 1024 * 1024

    var body: some View {
        NavigationStack {
            Group {
                if recipients.isEmpty {
                    emptyState
                } else if let outputURL {
                    resultView(outputURL: outputURL)
                } else if let identity {
                    form(identity: identity)
                } else if let identityErrorMessage {
                    Text(identityErrorMessage).foregroundStyle(.red).padding()
                } else {
                    ProgressView("Loading identity…")
                }
            }
            .navigationTitle("Encrypt file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(outputURL == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .task {
            await loadIdentity()
            if selectedRecipient == nil { selectedRecipient = preferredInitialRecipient() }
        }
        .onChange(of: selectedRecipient) { _, newValue in
            if let id = newValue?.id { AppConstants.saveLastRecipientID(id) }
        }
    }

    // MARK: - Sub-views

    private var emptyState: some View {
        ContentUnavailableView(
            "No recipients yet",
            systemImage: "person.crop.circle.badge.plus",
            description: Text("Add a recipient's public key from the home screen first, then come back to send them an encrypted file.")
        )
    }

    private func form(identity: Identity) -> some View {
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

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                Button {
                    DocumentPicker.pick(contentTypes: [.item]) { url in
                        handleImport(url: url)
                    }
                } label: {
                    Label("Choose file to encrypt…", systemImage: "doc.badge.plus")
                }
                .disabled(selectedRecipient == nil)
            } footer: {
                Text("The file is encrypted to \(selectedRecipient?.displayName ?? "your recipient") and signed by you, then saved as an .exc2 file you can send through any app. Only they can open it.")
            }
        }
    }

    @ViewBuilder
    private func resultView(outputURL: URL) -> some View {
        Form {
            Section {
                LabeledContent("Original", value: sourceName ?? "—")
                LabeledContent("Encrypted size", value: byteCountString(outputByteCount))
            } header: {
                Text("Encrypted file")
            } footer: {
                if outputByteCount > warnSizeBytes {
                    Text("That's a large file (\(byteCountString(outputByteCount))). Some messengers cap attachment sizes — Files, AirDrop and Mail handle big ones best.")
                } else {
                    Text("Send this .exc2 file through any app. Only \(selectedRecipient?.displayName ?? "the recipient") can decrypt it, and they can verify it came from you.")
                }
            }

            Section {
                ShareLink(item: outputURL) {
                    Label("Share encrypted file…", systemImage: "square.and.arrow.up")
                }
                Button("Encrypt another file") {
                    self.outputURL = nil
                    self.sourceName = nil
                    self.errorMessage = nil
                }
            }
        }
    }

    // MARK: - Actions

    private func handleImport(url: URL) {
        errorMessage = nil
        guard let identity, let recipient = selectedRecipient,
              let bundle = recipient.publicBundle else {
            errorMessage = "Couldn't read this recipient's public key. Try removing and re-adding the recipient."
            return
        }
        do {
            // `DocumentPicker` hands us a copy in the app container, so no
            // security-scoped access dance is needed here.
            let data = try Data(contentsOf: url)
            let payload = FilePayload.encode(filename: url.lastPathComponent, content: data)
            let envelope = try CryptoEnvelope.seal(
                plaintext: payload,
                to: bundle.encryptionPublicKey,
                from: identity
            )
            let outURL = try writeEnvelopeFile(envelope: envelope, sourceName: url.lastPathComponent)
            sourceName = url.lastPathComponent
            outputByteCount = Data(envelope.utf8).count
            outputURL = outURL
        } catch let error as CryptoEnvelope.Error {
            errorMessage = "Couldn't encrypt the file: \(describe(error))"
        } catch {
            errorMessage = "Couldn't read or encrypt that file: \(error.localizedDescription)"
        }
    }

    /// Write the envelope to a temp `<name>.exc2` file for sharing.
    private func writeEnvelopeFile(envelope: String, sourceName: String) throws -> URL {
        let base = (sourceName as NSString).deletingPathExtension
        let safeBase = base.isEmpty ? "file" : base
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeBase).exc2")
        try? FileManager.default.removeItem(at: url)
        try Data(envelope.utf8).write(to: url)
        return url
    }

    private func preferredInitialRecipient() -> Recipient? {
        if let id = AppConstants.loadLastRecipientID(),
           let match = recipients.first(where: { $0.id == id }) {
            return match
        }
        return recipients.first
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
        case .malformedEnvelope:           return "the data was malformed."
        case .unsupportedVersion(let v):   return "unsupported version 0x\(String(v, radix: 16))."
        case .fingerprintMismatch:         return "the recipient key didn't match."
        case .signatureVerificationFailed: return "the signature didn't verify."
        case .decryptionFailed:            return "the encryption step failed."
        }
    }
}

#Preview {
    EncryptFileView()
        .modelContainer(for: Recipient.self, inMemory: true)
}
