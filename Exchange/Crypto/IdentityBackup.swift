//
//  IdentityBackup.swift
//  Exchange
//
//  Passphrase-encrypted, copy-paste-friendly backup of the user's
//  identity *and* their saved recipient list.
//
//  Wire format:
//
//      EXCBKP1: base64( salt[16] || nonce[12] || ciphertext_with_tag )
//
//  Where:
//
//    - salt is 16 random bytes used for the passphrase KDF.
//    - nonce is 12 random bytes used for ChaCha20-Poly1305.
//    - ciphertext_with_tag is the AEAD output (plaintext length + 16 byte tag).
//    - The plaintext is a JSON-encoded `Payload` struct (see below) that
//      carries the identity private keys and the full recipient list.
//
//  Crypto choices:
//
//    - KDF: PBKDF2-HMAC-SHA256 with 600,000 iterations, matching current
//      OWASP recommendations. PBKDF2 is implemented in-Swift on top of
//      CryptoKit's HMAC primitive — keeps the crypto stack to one well-
//      understood Apple framework, no CommonCrypto bridging.
//    - Cipher: ChaCha20-Poly1305 (`CryptoKit.ChaChaPoly`). Same primitive
//      Exchange uses everywhere else, so we don't introduce a second
//      AEAD with its own implementation surface.
//
//  Size: a fresh identity with a handful of recipients fits in a few
//  hundred bytes. A user with hundreds of recipients still fits in a
//  few KB — easily pasteable, easily stored in a password manager.
//

import CryptoKit
import Foundation

nonisolated enum IdentityBackup {
    static let prefix = "EXCBKP1:"

    /// Iteration count for PBKDF2-HMAC-SHA256. Tuned to keep the
    /// derivation under ~1.5 s on an iPhone 14-class device while still
    /// being expensive enough that brute-forcing a moderately strong
    /// passphrase is impractical. Bump this in a future EXCBKP2 if
    /// hardware moves the goalposts; this version is locked at 600k so
    /// existing exports stay decryptable.
    static let pbkdf2Iterations = 600_000

    /// Minimum passphrase length the export sheet will accept. Doesn't
    /// affect import — old backups with shorter passphrases still
    /// decrypt — but prevents users from creating new backups with a
    /// passphrase that the KDF can't meaningfully protect.
    static let minPassphraseLength = 12

    // MARK: - Public API

    /// Encrypt the supplied identity + recipient list under `passphrase`,
    /// returning a single-line string suitable for copy-paste into a
    /// password manager or sending to oneself over a secure channel.
    nonisolated static func encode(
        identity: Identity,
        recipients: [RecipientSnapshot],
        passphrase: String
    ) throws -> String {
        let payload = Payload(
            version: 1,
            identity: Payload.IdentityBlob(identity: identity),
            recipients: recipients.map(Payload.RecipientBlob.init(snapshot:))
        )
        let plaintext = try JSONEncoder().encode(payload)

        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        let key = pbkdf2(
            password: passphrase,
            salt: salt,
            iterations: pbkdf2Iterations,
            keyLength: 32
        )

        let nonce = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: nonce
        )

        let payloadBytes = salt + Data(nonce) + sealed.ciphertext + sealed.tag
        return prefix + payloadBytes.base64EncodedString()
    }

    /// Reverse of `encode`. Throws on prefix mismatch, base64 corruption,
    /// length mismatch, wrong passphrase, or AEAD tag failure. The
    /// caller can distinguish "wrong passphrase / tampering" (the AEAD
    /// rejected the data) from "this isn't a backup at all" via the
    /// thrown error.
    nonisolated static func decode(
        _ blob: String,
        passphrase: String
    ) throws -> DecodedBackup {
        let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else {
            throw Error.malformed
        }
        let body = String(trimmed.dropFirst(prefix.count))
        guard let bytes = Data(base64Encoded: body) else {
            throw Error.malformed
        }
        // 16 (salt) + 12 (nonce) + 16 (tag) = 44 bytes minimum, before
        // any actual ciphertext. Anything shorter is structurally invalid.
        guard bytes.count >= 44 else { throw Error.malformed }

        let salt = bytes.prefix(16)
        let nonceBytes = bytes.dropFirst(16).prefix(12)
        let ciphertextAndTag = bytes.dropFirst(28)
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)

        let key = pbkdf2(
            password: passphrase,
            salt: Data(salt),
            iterations: pbkdf2Iterations,
            keyLength: 32
        )

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

        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(sealedBox, using: SymmetricKey(data: key))
        } catch {
            // ChaChaPoly throws on tag mismatch, which on a structurally
            // sound blob means the passphrase is wrong (or the blob has
            // been tampered with after sealing — same recovery flow
            // either way: re-enter the passphrase).
            throw Error.wrongPassphraseOrTampered
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: plaintext)
        } catch {
            throw Error.malformed
        }
        guard payload.version == 1 else { throw Error.unsupportedVersion(payload.version) }

        let identity = try payload.identity.toIdentity()
        let recipients = try payload.recipients.map { try $0.toSnapshot() }
        return DecodedBackup(identity: identity, recipients: recipients)
    }

    // MARK: - Snapshot of a recipient

    /// Lightweight in-memory shape of a `Recipient` row, used by the
    /// backup encode path so this file doesn't pull in SwiftData.
    /// The Settings/import flow builds these from the live `[Recipient]`
    /// query, and on import re-inserts them as fresh SwiftData rows.
    nonisolated struct RecipientSnapshot: Equatable {
        let displayName: String
        let encryptionPublicKey: Data  // raw 32 bytes
        let signingPublicKey: Data     // raw 32 bytes
        let notes: String
        let createdAt: Date
        /// Manual sort position (0 for backups written before v1.2).
        let orderIndex: Int
        /// Last edit time for label/position (falls back to createdAt).
        let updatedAt: Date
    }

    nonisolated struct DecodedBackup {
        let identity: (
            encryption: Curve25519.KeyAgreement.PrivateKey,
            signing: Curve25519.Signing.PrivateKey
        )
        let recipients: [RecipientSnapshot]
    }

    nonisolated enum Error: Swift.Error, Equatable {
        case malformed
        case unsupportedVersion(Int)
        case wrongPassphraseOrTampered
    }

    // MARK: - JSON payload
    //
    // Inner Codable types are named `IdentityBlob` / `RecipientBlob` to
    // avoid colliding with the top-level `Identity` struct and the
    // SwiftData `Recipient` model used in the rest of the project.

    private struct Payload: Codable {
        let version: Int
        let identity: IdentityBlob
        let recipients: [RecipientBlob]

        struct IdentityBlob: Codable {
            let encryptionPrivateKey: Data  // raw 32 bytes
            let signingPrivateKey: Data     // raw 32 bytes

            init(identity: Identity) {
                self.encryptionPrivateKey = identity.encryptionPrivateKey.rawRepresentation
                self.signingPrivateKey = identity.signingPrivateKey.rawRepresentation
            }

            func toIdentity() throws -> (
                encryption: Curve25519.KeyAgreement.PrivateKey,
                signing: Curve25519.Signing.PrivateKey
            ) {
                let encryption = try Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: encryptionPrivateKey
                )
                let signing = try Curve25519.Signing.PrivateKey(
                    rawRepresentation: signingPrivateKey
                )
                return (encryption, signing)
            }
        }

        struct RecipientBlob: Codable {
            let displayName: String
            let encryptionPublicKey: Data
            let signingPublicKey: Data
            let notes: String
            let createdAt: Date
            // Optional so old backups (which lack these keys) still decode,
            // and so older app versions ignore them when reading ours. The
            // payload version stays 1; the schema only grows optional fields.
            let orderIndex: Int?
            let updatedAt: Date?

            init(snapshot: RecipientSnapshot) {
                self.displayName = snapshot.displayName
                self.encryptionPublicKey = snapshot.encryptionPublicKey
                self.signingPublicKey = snapshot.signingPublicKey
                self.notes = snapshot.notes
                self.createdAt = snapshot.createdAt
                self.orderIndex = snapshot.orderIndex
                self.updatedAt = snapshot.updatedAt
            }

            func toSnapshot() throws -> RecipientSnapshot {
                // Validate the raw bytes parse as proper public keys
                // before we hand them on to the SwiftData layer; cheaper
                // to fail the whole import than to leave a corrupt row
                // for the user to discover later.
                _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: encryptionPublicKey)
                _ = try Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
                return RecipientSnapshot(
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

    // MARK: - PBKDF2-HMAC-SHA256 (CryptoKit-only)

    /// Standard PBKDF2 derivation on top of CryptoKit's HMAC<SHA256>.
    /// Output length is in bytes; for our use it's always 32 (the
    /// ChaCha20-Poly1305 key length). 600 k iterations on an iPhone 14
    /// runs in a little under a second; the cost scales linearly.
    private nonisolated static func pbkdf2(
        password: String,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var output = Data()
        var blockIndex: UInt32 = 1
        while output.count < keyLength {
            // Big-endian 4-byte block index per RFC 2898.
            let indexBytes = withUnsafeBytes(of: blockIndex.bigEndian) { Data($0) }
            var u = Data(HMAC<SHA256>.authenticationCode(
                for: salt + indexBytes,
                using: passwordKey
            ))
            var block = u
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
                for j in 0..<block.count {
                    block[j] ^= u[j]
                }
            }
            output.append(block)
            blockIndex += 1
        }
        return output.prefix(keyLength)
    }
}
