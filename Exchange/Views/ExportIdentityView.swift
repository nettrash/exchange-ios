//
//  ExportIdentityView.swift
//  Exchange
//
//  Sheet for producing an `EXCBKP1:` passphrase-encrypted backup of the
//  user's identity + recipient list. The user enters a passphrase
//  twice, the view runs PBKDF2 + ChaCha20-Poly1305, and shows the
//  resulting blob with Copy and Share buttons. Suitable for stashing
//  in a password manager or sending to oneself over a trusted channel.
//

import CryptoKit
import SwiftData
import SwiftUI
import UIKit

struct ExportIdentityView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Recipient.createdAt, order: .reverse)])
    private var recipients: [Recipient]

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?

    @State private var passphrase: String = ""
    @State private var confirmation: String = ""
    @State private var isWorking = false
    @State private var blob: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let blob {
                    resultView(blob: blob)
                } else if identity != nil {
                    inputForm
                } else if let identityErrorMessage {
                    Text(identityErrorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    ProgressView("Loading identity…")
                }
            }
            .navigationTitle("Export identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(blob == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .task { await loadIdentity() }
    }

    // MARK: - Input

    private var inputForm: some View {
        Form {
            Section {
                SecureField("Passphrase", text: $passphrase)
                    .textContentType(.newPassword)
                    .autocorrectionDisabled()
                SecureField("Confirm passphrase", text: $confirmation)
                    .textContentType(.newPassword)
                    .autocorrectionDisabled()
            } header: {
                Text("Passphrase")
            } footer: {
                Text("At least \(IdentityBackup.minPassphraseLength) characters. The strength of this passphrase is the only thing protecting your private key in the exported blob — pick something long, memorable, and unique. There's no way to recover the export if you forget it.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await encrypt() }
                } label: {
                    HStack {
                        Label("Encrypt and export", systemImage: "lock.fill")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canEncrypt || isWorking)
            } footer: {
                Text("Identity (private keys) and your full recipient list will be encrypted with this passphrase. The result is one line of base64 you can paste into a password manager or send to yourself over a trusted channel.")
            }
        }
    }

    private var canEncrypt: Bool {
        passphrase.count >= IdentityBackup.minPassphraseLength
            && passphrase == confirmation
    }

    // MARK: - Result

    @ViewBuilder
    private func resultView(blob: String) -> some View {
        Form {
            Section {
                Text(blob)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(nil)
            } header: {
                Text("Encrypted backup")
            } footer: {
                Text("Save this somewhere safe (a password manager works well). To restore on another device, use Settings → Import identity and supply the same passphrase.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = blob
                } label: {
                    Label("Copy to clipboard", systemImage: "doc.on.doc")
                }
                ShareLink(item: blob) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                // A second pass is most likely a different passphrase, so
                // wipe the buffers — cheaper than asking which one they
                // meant if they bounce between two attempts.
                Button("Encrypt again with a different passphrase") {
                    self.blob = nil
                    self.passphrase = ""
                    self.confirmation = ""
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

    /// Run the (intentionally-slow) PBKDF2 derivation off the main
    /// actor so the spinner stays animated. Identities are tiny so the
    /// memory footprint of the encode call is negligible.
    private func encrypt() async {
        guard let identity else { return }
        guard canEncrypt else { return }
        errorMessage = nil
        isWorking = true
        let snapshots = recipients.map { recipient in
            IdentityBackup.RecipientSnapshot(
                displayName: recipient.displayName,
                encryptionPublicKey: recipient.encryptionPublicKeyData,
                signingPublicKey: recipient.signingPublicKeyData,
                notes: recipient.notes,
                createdAt: recipient.createdAt,
                orderIndex: recipient.orderIndex,
                updatedAt: recipient.effectiveUpdatedAt
            )
        }
        let pass = passphrase
        let result = await Task.detached(priority: .userInitiated) {
            do {
                let encoded = try IdentityBackup.encode(
                    identity: identity,
                    recipients: snapshots,
                    passphrase: pass
                )
                return Result<String, Swift.Error>.success(encoded)
            } catch {
                return Result<String, Swift.Error>.failure(error)
            }
        }.value
        isWorking = false
        switch result {
        case .success(let encoded):
            blob = encoded
        case .failure(let error):
            errorMessage = "Couldn't encrypt the backup: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ExportIdentityView()
        .modelContainer(for: Recipient.self, inMemory: true)
}
