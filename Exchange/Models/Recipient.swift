//
//  Recipient.swift
//  Exchange
//
//  A contact we can send signed, encrypted messages to.
//
//  Stores both of the contact's public keys (encryption + signing), the
//  combined identity fingerprint we use to address them in the UI, plus a
//  display name, free-form notes, and creation timestamp.
//

import CryptoKit
import Foundation
import SwiftData

@Model
final class Recipient {
    @Attribute(.unique) var id: UUID

    /// Human-friendly name shown in the UI.
    var displayName: String

    /// Raw 32-byte Curve25519 X25519 public key (used for ECDH).
    var encryptionPublicKeyData: Data

    /// Raw 32-byte Ed25519 public key (used to verify the sender's signature
    /// on incoming envelopes).
    var signingPublicKeyData: Data

    /// 8 bytes of SHA-256 over the concatenation of both public keys.
    /// Stored so we can deduplicate on import without recomputing.
    var fingerprintData: Data

    /// Free-form notes (where you got this key, when you verified it, etc.)
    var notes: String

    var createdAt: Date

    /// User-defined position in the recipient list (manual drag-to-reorder).
    /// Lower sorts first; ties are broken by `createdAt` descending so the
    /// pre-reorder default stays "newest first". Added in v1.2 with a
    /// default of 0 so SwiftData lightweight migration leaves existing
    /// rows tied (and therefore in their previous order).
    var orderIndex: Int = 0

    /// Last time the user edited this recipient's display label or its
    /// position. Used by the iCloud-Keychain sync merge to resolve
    /// rename/reorder conflicts (latest write wins). Optional so that
    /// rows migrated from a pre-v1.2 store decode as `nil`; callers treat
    /// `nil` as `createdAt` (see `effectiveUpdatedAt`).
    var updatedAt: Date?

    init(displayName: String,
         publicBundle: Identity.PublicBundle,
         notes: String = "",
         createdAt: Date = .now,
         orderIndex: Int = 0,
         updatedAt: Date? = nil) {
        self.id = UUID()
        self.displayName = displayName
        self.encryptionPublicKeyData = publicBundle.encryptionPublicKey.rawRepresentation
        self.signingPublicKeyData = publicBundle.signingPublicKey.rawRepresentation
        self.fingerprintData = Identity.fingerprint(of: publicBundle)
        self.notes = notes
        self.createdAt = createdAt
        self.orderIndex = orderIndex
        // A freshly-created row's "last edited" time is its creation time
        // unless the caller overrides it (e.g. the sync merge preserving a
        // remote timestamp).
        self.updatedAt = updatedAt ?? createdAt
    }
}

extension Recipient {
    /// Reconstruct the typed public bundle from stored bytes.
    /// Returns `nil` only if the stored bytes are corrupt — the model
    /// invariant is that this never happens for rows we wrote ourselves.
    var publicBundle: Identity.PublicBundle? {
        guard let encryption = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: encryptionPublicKeyData
        ),
              let signing = try? Curve25519.Signing.PublicKey(
                rawRepresentation: signingPublicKeyData
              ) else {
            return nil
        }
        return Identity.PublicBundle(
            encryptionPublicKey: encryption,
            signingPublicKey: signing
        )
    }

    /// Encryption-only fingerprint (8 bytes), used to address envelopes.
    var encryptionFingerprintData: Data? {
        guard let encryption = publicBundle?.encryptionPublicKey else { return nil }
        return Identity.encryptionFingerprint(of: encryption)
    }

    /// Display-friendly identity fingerprint, e.g. "a1b2-c3d4-e5f6-0708".
    var fingerprintDisplay: String { fingerprintData.groupedHex }

    /// `updatedAt`, falling back to `createdAt` for rows migrated from a
    /// store written before the field existed.
    var effectiveUpdatedAt: Date { updatedAt ?? createdAt }
}
