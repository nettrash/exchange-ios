//
//  AddRecipientView.swift
//  Exchange
//
//  Sheet for importing a recipient's public-key bundle — either by paste
//  or by scanning a QR code from the other person's "My identity" sheet.
//
//  In v2 the bundle is base64 of 64 bytes (encryption + signing public
//  keys concatenated), not the 32-byte single-key blob from v1.
//

import CryptoKit
import SwiftData
import SwiftUI

struct AddRecipientView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var existingRecipients: [Recipient]

    @State private var displayName: String = ""
    @State private var publicBundleText: String = ""
    @State private var notes: String = ""
    @State private var errorMessage: String?

    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("e.g. Alice", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                Section {
                    TextEditor(text: $publicBundleText)
                        .font(.caption.monospaced())
                        .frame(minHeight: 90)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Public key bundle (base64)")
                } footer: {
                    Text("Paste the recipient's Exchange public key bundle, or use Scan QR. The bundle includes both their encryption key and their signing key, so received messages can be authenticated.")
                }
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                }
                Section("Notes (optional)") {
                    TextField("Where you got this key", text: $notes, axis: .vertical)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add recipient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $scanning) {
                scanSheet
            }
        }
    }

    private var scanSheet: some View {
        NavigationStack {
            QRScannerView(
                onScan: { value in
                    publicBundleText = value
                    errorMessage = nil
                    scanning = false
                },
                onError: { message in
                    errorMessage = message
                    scanning = false
                }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Scan public key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { scanning = false }
                }
            }
        }
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicBundleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBundle = publicBundleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicBundle: Identity.PublicBundle
        do {
            publicBundle = try Identity.decode(publicBundle: trimmedBundle)
        } catch {
            errorMessage = "That doesn't look like a valid Exchange public key bundle. Make sure you pasted the full base64 string from their My identity screen."
            return
        }
        let fingerprint = Identity.fingerprint(of: publicBundle)
        if existingRecipients.contains(where: { $0.fingerprintData == fingerprint }) {
            errorMessage = "A recipient with this key already exists."
            return
        }
        // New recipients sit at the top of the manual order (one below the
        // current minimum), preserving the historical "newest first"
        // default until the user drags things around.
        let topOrderIndex = (existingRecipients.map(\.orderIndex).min() ?? 0) - 1
        let recipient = Recipient(
            displayName: trimmedName,
            publicBundle: publicBundle,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            orderIndex: topOrderIndex
        )
        modelContext.insert(recipient)
        dismiss()
    }
}

#Preview {
    AddRecipientView()
        .modelContainer(for: Recipient.self, inMemory: true)
}
