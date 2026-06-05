//
//  ShowIdentityQRTransferView.swift
//  Exchange
//
//  Source-device side of the in-person QR transfer flow. Encrypts the
//  local identity under a fresh ephemeral key and renders the EXCQR1
//  string as a large QR code for the receiving device's camera.
//
//  The ephemeral key lives inside the QR — there's no separate channel.
//  The user is expected to keep the QR visible only to their other
//  device in a physically trusted setting; the on-screen warning makes
//  that explicit.
//

import CryptoKit
import SwiftUI

struct ShowIdentityQRTransferView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var identity: Identity?
    @State private var identityErrorMessage: String?
    @State private var qrPayload: String?
    @State private var encodeErrorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let qrPayload, let identity {
                    qrView(payload: qrPayload, identity: identity)
                } else if let identityErrorMessage {
                    Text(identityErrorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else if let encodeErrorMessage {
                    Text(encodeErrorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    ProgressView("Preparing transfer code…")
                }
            }
            .navigationTitle("Send identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await prepare() }
    }

    private func qrView(payload: String, identity: Identity) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                QRCodeView(payload: payload, correctionLevel: .medium)
                    .frame(maxWidth: 320)
                    .padding(.horizontal)

                VStack(spacing: 6) {
                    Text("Fingerprint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(identity.fingerprint.groupedHex)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text("This QR carries your private key.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("Keep it visible only to the other device you're transferring to. Don't photograph it, screenshot it, or show it on a video call. Anyone who captures this image can decrypt every message ever addressed to your identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("On the other device: open Exchange → Settings → Receive identity, then point its camera here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)

                Spacer(minLength: 0)
            }
            .padding(.vertical)
        }
    }

    private func prepare() async {
        do {
            let loaded = try IdentityStore.loadOrCreate()
            identity = loaded
        } catch {
            identityErrorMessage = "Couldn't load identity: \(error.localizedDescription)"
            return
        }
        guard let identity else { return }
        do {
            qrPayload = try IdentityTransferQR.encode(identity: identity)
        } catch {
            encodeErrorMessage = "Couldn't prepare transfer code: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ShowIdentityQRTransferView()
}
