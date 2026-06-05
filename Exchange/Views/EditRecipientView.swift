//
//  EditRecipientView.swift
//  Exchange
//
//  Sheet for renaming a saved recipient — i.e. editing the local display
//  label shown in the list. The underlying public-key identity (and its
//  fingerprint) is immutable: to change *who* a row points at you remove
//  it and add the new key. So this sheet edits the display name and the
//  free-form notes only, and always shows the fingerprint beneath the
//  editable field so the user never loses track of which identity they're
//  relabelling.
//
//  Saving stamps `updatedAt = .now`, which is what the iCloud-Keychain
//  sync merge uses to decide that this rename should win over an older
//  copy of the same row on another device.
//

import CryptoKit
import SwiftData
import SwiftUI

struct EditRecipientView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The row being edited. `@Bindable` so edits to the text fields can
    /// be applied directly on Save (we deliberately don't mutate it live —
    /// we stage into local @State and commit on Save so Cancel is a true
    /// no-op).
    let recipient: Recipient

    @State private var displayName: String
    @State private var notes: String

    init(recipient: Recipient) {
        self.recipient = recipient
        _displayName = State(initialValue: recipient.displayName)
        _notes = State(initialValue: recipient.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("e.g. Alice", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                Section {
                    Text(recipient.fingerprintDisplay)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Identity fingerprint")
                } footer: {
                    Text("The recipient's key identity can't be changed here. To point this row at a different key, delete it and add the new one.")
                }
                Section("Notes (optional)") {
                    TextField("Where you got this key", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle("Edit recipient")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func save() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name falls back to the fingerprint display so the row is
        // never blank in the list.
        recipient.displayName = trimmedName.isEmpty ? recipient.fingerprintDisplay : trimmedName
        recipient.notes = trimmedNotes
        recipient.updatedAt = .now
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    // Preview needs a row to edit; build an in-memory container and seed one.
    let container = try! ModelContainer(
        for: Recipient.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let bundle = Identity.PublicBundle(
        encryptionPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey,
        signingPublicKey: Curve25519.Signing.PrivateKey().publicKey
    )
    let recipient = Recipient(displayName: "Alice", publicBundle: bundle)
    container.mainContext.insert(recipient)
    return EditRecipientView(recipient: recipient)
        .modelContainer(container)
}
