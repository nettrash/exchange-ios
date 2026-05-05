//
//  ShareDecryptView.swift
//  ShareExtension
//
//  SwiftUI shell hosted by ShareViewController. Renders one of four
//  states driven by the @Observable model:
//    - loading      : initial state while we pull and decrypt
//    - plaintext    : decrypted text, with a Copy button
//    - binary       : decrypted, but not UTF-8 text
//    - error        : a typed user-facing message
//

import Observation
import SwiftUI
import UIKit

@Observable
final class ShareDecryptModel {
    enum DisplayState: Equatable {
        case loading
        case plaintext(String)
        case binary(byteCount: Int)
        case error(message: String)
    }

    var state: DisplayState = .loading
}

struct ShareDecryptView: View {
    @Bindable var model: ShareDecryptModel
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Exchange")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done", action: onDone)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Decrypting…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .plaintext(let plaintext):
            Form {
                Section {
                    Text(plaintext)
                        .textSelection(.enabled)
                } header: {
                    Text("Decrypted message")
                } footer: {
                    Text("Verified as addressed to your identity. Sender authenticity is not yet verified.")
                }
                Section {
                    Button {
                        UIPasteboard.general.string = plaintext
                    } label: {
                        Label("Copy plaintext", systemImage: "doc.on.doc")
                    }
                }
            }

        case .binary(let byteCount):
            Form {
                Section("Decrypted") {
                    Text("Binary content, \(byteCount) bytes — not displayable as text.")
                        .foregroundStyle(.secondary)
                }
            }

        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "lock.slash")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
