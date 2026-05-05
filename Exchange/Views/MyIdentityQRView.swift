//
//  MyIdentityQRView.swift
//  Exchange
//
//  Sheet that shows the local identity's public-key bundle as a QR code,
//  plus the human-readable fingerprint underneath. The recipient on the
//  other phone scans this; their AddRecipientView fills with the bundle
//  text, they type a name, save.
//
//  We deliberately don't include display name or any other metadata in
//  the QR — just the base64 bundle, so it stays small and matches
//  exactly what the paste path produces.
//

import CryptoKit
import SwiftUI
import UIKit

struct MyIdentityQRView: View {
    @Environment(\.dismiss) private var dismiss
    let identity: Identity

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    QRCodeView(payload: payload)
                        .frame(maxWidth: 320, maxHeight: 320)
                        .padding(.horizontal)

                    VStack(spacing: 6) {
                        Text("Fingerprint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(identity.fingerprint.groupedHex)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }

                    Text("Have the other person scan this to add you as a recipient. Always verify the fingerprint matches what they see on their phone — that's how you confirm the key wasn't intercepted in transit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button {
                        UIPasteboard.general.string = payload
                    } label: {
                        Label("Copy public key bundle", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical)
            }
            .navigationTitle("My identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var payload: String {
        Identity.encode(publicBundle: identity.publicBundle)
    }
}
