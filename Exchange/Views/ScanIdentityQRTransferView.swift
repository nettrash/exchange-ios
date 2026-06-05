//
//  ScanIdentityQRTransferView.swift
//  Exchange
//
//  Receiving-device side of the in-person QR transfer flow. Opens the
//  camera, decodes the next EXCQR1 QR it sees, decrypts to a candidate
//  identity, then asks the user to confirm by checking the fingerprint
//  matches what their other device shows.
//
//  Only after explicit confirmation does the local identity get
//  overwritten — the camera scan alone is *not* destructive, in case
//  the user pointed at the wrong QR or grabbed someone else's.
//

import CryptoKit
import SwiftUI

struct ScanIdentityQRTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RecipientsSyncCoordinator.self) private var recipientsSync

    @State private var pendingPreview: Preview?
    @State private var scanErrorMessage: String?
    @State private var importErrorMessage: String?
    @State private var didImport = false

    var body: some View {
        NavigationStack {
            Group {
                if didImport {
                    importedView
                } else if let pendingPreview {
                    confirmationView(preview: pendingPreview)
                } else if let scanErrorMessage {
                    errorView(message: scanErrorMessage)
                } else {
                    QRScannerView(
                        onScan: handleScan(_:),
                        onError: { message in
                            scanErrorMessage = message
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("Point the camera at the QR shown by your other device.")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                            .padding()
                    }
                }
            }
            .navigationTitle("Receive identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(didImport ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
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
            } header: {
                Text("Scanned identity")
            } footer: {
                Text("Compare this fingerprint with the one shown on the sending device. Both should match exactly.")
            }

            if let importErrorMessage {
                Section {
                    Text(importErrorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await commitImport(preview: preview) }
                } label: {
                    Label("Replace local identity", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("Your current private key on this device will be overwritten with the scanned one. Anything previously encrypted to the old identity that isn't reachable through the new one will become unreadable.")
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
                Text("This device now uses the same identity as the one you scanned from.")
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

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func handleScan(_ scanned: String) {
        do {
            let decoded = try IdentityTransferQR.decode(scanned)
            let fingerprint = IdentityTransferQR.fingerprint(of: decoded).groupedHex
            pendingPreview = Preview(decoded: decoded, fingerprint: fingerprint)
        } catch let error as IdentityTransferQR.Error {
            switch error {
            case .malformed:
                scanErrorMessage = "That QR doesn't look like an Exchange transfer code. On the sending device, choose Settings → Send identity and try again."
            case .tampered:
                scanErrorMessage = "The transfer code couldn't be decrypted. The QR may have been corrupted in capture, or it's not the one your sending device produced."
            }
        } catch {
            scanErrorMessage = "Couldn't decode the transfer: \(error.localizedDescription)"
        }
    }

    private func commitImport(preview: Preview) async {
        importErrorMessage = nil
        do {
            let newIdentity = try IdentityStore.replace(
                encryption: preview.decoded.encryption,
                signing: preview.decoded.signing
            )
            // Re-bind the recipients sync coordinator. The interesting
            // case here is the same-identity-on-two-devices flow: if
            // another device already has the same identity and has
            // pushed a recipient blob, this bind triggers the pull and
            // recipients appear automatically — even though the QR
            // payload itself only carried the identity.
            await recipientsSync.bind(identity: newIdentity)
            didImport = true
        } catch {
            importErrorMessage = "Couldn't apply the import: \(error.localizedDescription)"
        }
    }

    // MARK: - Local types

    private struct Preview: Equatable {
        let decoded: IdentityTransferQR.DecodedTransfer
        let fingerprint: String

        static func == (lhs: Preview, rhs: Preview) -> Bool {
            lhs.fingerprint == rhs.fingerprint
        }
    }
}

#Preview {
    ScanIdentityQRTransferView()
}
