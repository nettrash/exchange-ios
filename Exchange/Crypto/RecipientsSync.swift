//
//  RecipientsSync.swift
//  Exchange
//
//  Encode / decode of the recipient-list blob that flows through iCloud
//  Keychain to keep the user's saved recipients in sync across the
//  iPhone and Mac on the same Apple ID.
//
//  Threat model recap (matching identity sync):
//
//  We deliberately do *not* use SwiftData + CloudKit private database
//  because that would put recipient metadata (display names, public
//  keys, fingerprints, free-form notes) on Apple's servers under
//  Apple-managed keys (E2E only with Advanced Data Protection on).
//  Instead, the recipient list is encrypted on-device with a key
//  derived from the user's identity, and the resulting opaque blob
//  rides iCloud Keychain — which IS end-to-end encrypted with a
//  device-class secret regardless of ADP. Apple sees ciphertext only.
//
//  Wire format (Keychain item value):
//
//      nonce[12] || ciphertext || tag[16]
//
//  Where the plaintext is a JSON-encoded `Blob` struct (see below) that
//  carries a version field, a "last write" timestamp used by the merge
//  logic, and a list of recipient entries.
//
//  Key derivation: HKDF<SHA256> over the identity's encryption private
//  key (32 bytes) with the constant info string "Exchange.recipients.v1".
//  No salt — we can't share a salt across devices without an extra
//  bootstrap exchange, and HKDF without salt is fine when the input
//  key material is already a uniformly distributed Curve25519 scalar.
//

import CryptoKit
import Foundation

nonisolated enum RecipientsSync {
    /// Keychain account under which the encrypted recipient blob is stored.
    /// Versioned alongside the format so a future schema bump can write
    /// `recipients.blob.v2` without trampling the v1 entry.
    static let account = "recipients.blob.v1"

    /// HKDF context string. Bumped if the blob format ever changes
    /// incompatibly so we don't conflate the keys for two formats.
    static let kdfInfo = "Exchange.recipients.v1"

    // MARK: - Public encode / decode

    /// Encrypt and serialise the supplied recipient snapshot list into
    /// the binary form stored in Keychain.
    nonisolated static func encode(
        recipients: [RecipientSnapshot],
        lastWriteAt: Date,
        with identity: Identity
    ) throws -> Data {
        let blob = Blob(
            version: 1,
            lastWriteAt: lastWriteAt,
            recipients: recipients.map(Blob.Entry.init(snapshot:))
        )
        let plaintext = try JSONEncoder.iso8601().encode(blob)
        let key = derivedKey(for: identity)
        let nonce = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        return Data(nonce) + sealed.ciphertext + sealed.tag
    }

    /// Decrypt and parse the binary form. Throws on length / nonce / tag
    /// failures — those mean either the identity has changed (so the
    /// derived key no longer matches), or the blob is corrupted, both
    /// of which the coordinator handles by writing a fresh blob from
    /// the local recipient list rather than blowing up.
    nonisolated static func decode(
        _ data: Data,
        with identity: Identity
    ) throws -> DecodedBlob {
        // 12 (nonce) + 16 (tag) = 28 bytes minimum, before any plaintext.
        guard data.count >= 28 else { throw Error.malformed }
        let nonceBytes = data.prefix(12)
        let ciphertextAndTag = data.dropFirst(12)
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)
        let nonce: ChaChaPoly.Nonce
        do {
            nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        } catch {
            throw Error.malformed
        }
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
        } catch {
            throw Error.malformed
        }
        let key = derivedKey(for: identity)
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(sealedBox, using: key)
        } catch {
            throw Error.identityMismatchOrTampered
        }
        let blob: Blob
        do {
            blob = try JSONDecoder.iso8601().decode(Blob.self, from: plaintext)
        } catch {
            throw Error.malformed
        }
        guard blob.version == 1 else { throw Error.unsupportedVersion(blob.version) }
        return DecodedBlob(
            lastWriteAt: blob.lastWriteAt,
            recipients: blob.recipients.map { try? $0.toSnapshot() }.compactMap { $0 }
        )
    }

    // MARK: - Snapshot

    /// Storage-agnostic shape of a recipient row, used to bridge between
    /// SwiftData and the JSON wire format without dragging SwiftData
    /// imports into this file.
    nonisolated struct RecipientSnapshot: Equatable {
        let id: UUID
        let displayName: String
        let encryptionPublicKey: Data
        let signingPublicKey: Data
        let notes: String
        let createdAt: Date
        /// Manual sort position. Defaults to 0 for blobs written before
        /// the field existed (all rows tie → fall back to createdAt order).
        let orderIndex: Int
        /// Last edit time for the display label / position. Used by the
        /// merge to resolve rename/reorder conflicts. Defaults to
        /// `createdAt` for pre-v1.2 blobs.
        let updatedAt: Date
    }

    nonisolated struct DecodedBlob {
        let lastWriteAt: Date
        let recipients: [RecipientSnapshot]
    }

    nonisolated enum Error: Swift.Error, Equatable {
        case malformed
        case unsupportedVersion(Int)
        /// AEAD tag rejection — typically because the identity in use
        /// doesn't match the one the blob was sealed under (e.g. user
        /// reset identity since the last sync, or a foreign blob
        /// somehow ended up in the same Keychain account).
        case identityMismatchOrTampered
    }

    // MARK: - JSON shape

    private struct Blob: Codable {
        let version: Int
        let lastWriteAt: Date
        let recipients: [Entry]

        struct Entry: Codable {
            let id: UUID
            let displayName: String
            let encryptionPublicKey: Data
            let signingPublicKey: Data
            let notes: String
            let createdAt: Date
            // Optional on the wire so that (a) a blob written by a pre-v1.2
            // client decodes here with these absent, and (b) a pre-v1.2
            // client decoding our blob simply ignores the extra keys. No
            // version bump needed — the format stays v1 and gains two
            // optional fields.
            let orderIndex: Int?
            let updatedAt: Date?

            init(snapshot: RecipientSnapshot) {
                self.id = snapshot.id
                self.displayName = snapshot.displayName
                self.encryptionPublicKey = snapshot.encryptionPublicKey
                self.signingPublicKey = snapshot.signingPublicKey
                self.notes = snapshot.notes
                self.createdAt = snapshot.createdAt
                self.orderIndex = snapshot.orderIndex
                self.updatedAt = snapshot.updatedAt
            }

            func toSnapshot() throws -> RecipientSnapshot {
                _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: encryptionPublicKey)
                _ = try Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
                return RecipientSnapshot(
                    id: id,
                    displayName: displayName,
                    encryptionPublicKey: encryptionPublicKey,
                    signingPublicKey: signingPublicKey,
                    notes: notes,
                    createdAt: createdAt,
                    orderIndex: orderIndex ?? 0,
                    updatedAt: updatedAt ?? createdAt
                )
            }
        }
    }

    // MARK: - Key derivation

    /// HKDF<SHA256>-derived 32-byte symmetric key from the identity's
    /// encryption private key. We use *only* the encryption private key
    /// (not the signing key) so a future change of signing material
    /// wouldn't invalidate every device's blob.
    private nonisolated static func derivedKey(for identity: Identity) -> SymmetricKey {
        let inputKey = SymmetricKey(data: identity.encryptionPrivateKey.rawRepresentation)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            info: Data(kdfInfo.utf8),
            outputByteCount: 32
        )
    }
}

// MARK: - JSON helpers
//
// The methods below are explicitly `nonisolated` because the project
// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would
// otherwise infer them as MainActor-isolated and prevent the
// `nonisolated` `RecipientsSync.encode` / `decode` from calling them.

private extension JSONEncoder {
    /// Encoder configured for our blob format — ISO-8601 dates so the
    /// blob is human-inspectable if a developer ever has to debug it,
    /// and stable key ordering for byte-identical re-encodes.
    nonisolated static func iso8601() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
