//
//  ImportIdentityView.swift
//  Exchange
//
//  Sheet for restoring an identity + recipient list from an
//  `EXCBKP1:` passphrase-encrypted backup. The user pastes the blob,
//  enters the original passphrase, and confirms the destructive
//  replacement of the local identity.
//

import CryptoKit
import SwiftData
import SwiftUI
import UIKit

struct ImportIdentityView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RecipientsSyncCoordinator.self) private var recipientsSync
    @Query private var existingRecipients: [Recipient]

    @State private var blobText: String = ""
    @State private var passphrase: String = ""
    @State private var isWorking = false
    @State private var pendingPreview: Preview?
    @State private var errorMessage: String?
    @State private var didImport = false

    var body: some View {
        NavigationStack {
            Group {
                if didImport {
                    importedView
                } else if let pendingPreview {
                    confirmationView(preview: pendingPreview)
                } else {
                    inputForm
                }
            }
            .navigationTitle("Import identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(didImport ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Input

    private var inputForm: some View {
        Form {
            Section {
                TextEditor(text: $blobText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 120)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Encrypted backup")
            } footer: {
                Text("Paste the EXCBKP1: blob you exported earlier (or pulled from a password manager).")
            }

            Section {
                Button {
                    if let pasted = UIPasteboard.general.string {
                        blobText = pasted
                    }
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
            }

            Section {
                SecureField("Passphrase", text: $passphrase)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            } header: {
                Text("Passphrase")
            } footer: {
                Text("The passphrase you set when you exported. There's no way to recover the export without it.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await decryptToPreview() }
                } label: {
                    HStack {
                        Label("Decrypt", systemImage: "lock.open")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canDecrypt || isWorking)
            }
        }
    }

    private var canDecrypt: Bool {
        !blobText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !passphrase.isEmpty
    }

    // MARK: - Confirmation

    @ViewBuilder
    private func confirmationView(preview: Preview) -> some View {
        Form {
            Section {
                LabeledContent("Identity fingerprint") {
                    Text(preview.fingerprint)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Recipients in backup") {
                    Text("\(preview.recipientCount)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Backup contents")
            } footer: {
                Text("Confirm the fingerprint matches the device the backup was made on.")
            }

            Section {
                Button(role: .destructive) {
                    Task { await commitImport(preview: preview) }
                } label: {
                    HStack {
                        Label("Replace local identity", systemImage: "arrow.triangle.2.circlepath")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isWorking)
            } footer: {
                Text("Your current private key will be overwritten with the imported one. Existing recipients will be wiped and replaced with the recipients from the backup. Anything previously encrypted to the old identity that isn't reachable through the imported one will become unreadable.")
            }

            Section {
                Button("Cancel") {
                    pendingPreview = nil
                }
            }
        }
    }

    // MARK: - Done

    private var importedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            VStack(spacing: 8) {
                Text("Identity imported")
                    .font(.headline)
                Text("Your identity and recipients have been restored from the backup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func decryptToPreview() async {
        errorMessage = nil
        isWorking = true
        let blob = blobText
        let pass = passphrase
        let result = await Task.detached(priority: .userInitiated) {
            do {
                let decoded = try IdentityBackup.decode(blob, passphrase: pass)
                return Result<IdentityBackup.DecodedBackup, Swift.Error>.success(decoded)
            } catch {
                return Result<IdentityBackup.DecodedBackup, Swift.Error>.failure(error)
            }
        }.value
        isWorking = false
        switch result {
        case .success(let decoded):
            let bundle = Identity.PublicBundle(
                encryptionPublicKey: decoded.identity.encryption.publicKey,
                signingPublicKey: decoded.identity.signing.publicKey
            )
            pendingPreview = Preview(
                decoded: decoded,
                fingerprint: Identity.fingerprint(of: bundle).groupedHex,
                recipientCount: decoded.recipients.count
            )
        case .failure(let error):
            errorMessage = describe(error)
        }
    }

    private func commitImport(preview: Preview) async {
        isWorking = true
        do {
            // Identity first — if this fails, we haven't touched recipients.
            let newIdentity = try IdentityStore.replace(
                encryption: preview.decoded.identity.encryption,
                signing: preview.decoded.identity.signing
            )
            // Then wipe + repopulate the recipient list.
            for recipient in existingRecipients {
                modelContext.delete(recipient)
            }
            for snapshot in preview.decoded.recipients {
                guard let bundle = bundleFromSnapshot(snapshot) else { continue }
                let row = Recipient(
                    displayName: snapshot.displayName,
                    publicBundle: bundle,
                    notes: snapshot.notes,
                    createdAt: snapshot.createdAt,
                    orderIndex: snapshot.orderIndex,
                    updatedAt: snapshot.updatedAt
                )
                modelContext.insert(row)
            }
            try modelContext.save()
            // Re-bind the sync coordinator to the new identity. This
            // re-derives the Keychain blob key, picks up any blob other
            // devices have already written under the same identity, and
            // pushes the imported recipient list back up so other
            // devices on this identity see them too.
            await recipientsSync.bind(identity: newIdentity)
            isWorking = false
            didImport = true
        } catch {
            isWorking = false
            errorMessage = "Couldn't apply the import: \(error.localizedDescription)"
            pendingPreview = nil
        }
    }

    private func bundleFromSnapshot(_ snapshot: IdentityBackup.RecipientSnapshot) -> Identity.PublicBundle? {
        guard let encryption = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: snapshot.encryptionPublicKey
        ),
              let signing = try? Curve25519.Signing.PublicKey(
                rawRepresentation: snapshot.signingPublicKey
              )
        else { return nil }
        return Identity.PublicBundle(
            encryptionPublicKey: encryption,
            signingPublicKey: signing
        )
    }

    private func describe(_ error: Swift.Error) -> String {
        if let e = error as? IdentityBackup.Error {
            switch e {
            case .malformed:
                return "This doesn't look like an Exchange backup blob."
            case .unsupportedVersion(let v):
                return "Unsupported backup version (\(v)). You may need a newer build of Exchange."
            case .wrongPassphraseOrTampered:
                return "The passphrase didn't decrypt the backup. It may be wrong, or the blob may have been corrupted in transport."
            }
        }
        return "Couldn't decrypt: \(error.localizedDescription)"
    }

    // MARK: - Local types

    private struct Preview: Equatable {
        let decoded: IdentityBackup.DecodedBackup
        let fingerprint: String
        let recipientCount: Int

        static func == (lhs: Preview, rhs: Preview) -> Bool {
            lhs.fingerprint == rhs.fingerprint
                && lhs.recipientCount == rhs.recipientCount
        }
    }
}

#Preview {
    ImportIdentityView()
        .modelContainer(for: Recipient.self, inMemory: true)
}
