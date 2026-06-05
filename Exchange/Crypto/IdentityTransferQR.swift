//
//  IdentityTransferQR.swift
//  Exchange
//
//  One-shot, in-person identity transfer via QR code.
//
//  Wire format:
//
//      EXCQR1: base64( key[32] || nonce[12] || ciphertext_with_tag )
//
//  Where:
//
//    - key is a fresh 32-byte symmetric key generated for this single
//      transfer. Embedded in the QR alongside the ciphertext, so the
//      QR is itself the secret.
//    - nonce is 12 random bytes used for ChaCha20-Poly1305.
//    - ciphertext_with_tag is the AEAD output, plaintext = the 64-byte
//      identity blob (32 ECDH + 32 Ed25519, same layout as Keychain).
//
//  Trust model:
//
//  The QR contains everything an attacker would need to decrypt and
//  impersonate the identity. The protection comes entirely from the
//  user keeping the QR visible only to the receiving device — typically
//  the same room, on a screen they control. Don't let anyone photograph
//  the screen, don't post a screenshot, don't transfer over a video call.
//
//  Why not include recipients here too:
//
//  QR codes have a finite information density (a few KB for a busy QR
//  before scanability falls off a cliff on shared phone screens). The
//  identity is 64 bytes; including a few hundred recipients of ~150
//  bytes each pushes us well past comfortable QR sizes. Identity-only
//  is the high-value transfer; recipients can be re-added or imported
//  separately via `IdentityBackup` (the passphrase route) which has no
//  size constraint.
//
//  Why a fresh key per transfer instead of, say, a passphrase or PAKE:
//
//  We're optimising for "user is holding two of their own devices."
//  A single QR scan is faster and harder to mistype than a passphrase,
//  and we don't need ECDH between the devices because the QR itself is
//  the channel and we trust the channel by inspection.
//

import CryptoKit
import Foundation

nonisolated enum IdentityTransferQR {
    static let prefix = "EXCQR1:"

    // MARK: - Public API

    /// Encrypt the supplied identity under a freshly-generated symmetric
    /// key, package as the EXCQR1 wire format, return the string to drop
    /// into a `QRCodeView`.
    nonisolated static func encode(identity: Identity) throws -> String {
        let plaintext = identity.encryptionPrivateKey.rawRepresentation
            + identity.signingPrivateKey.rawRepresentation
        precondition(plaintext.count == 64, "Identity blob must be 64 bytes")

        let key = SymmetricKey(size: .bits256)
        let nonce = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

        let keyBytes = key.withUnsafeBytes { Data($0) }
        let payloadBytes = keyBytes + Data(nonce) + sealed.ciphertext + sealed.tag
        return prefix + payloadBytes.base64EncodedString()
    }

    /// Reverse of `encode`. Throws on prefix mismatch, base64 corruption,
    /// length mismatch, or AEAD tag failure (which on a structurally
    /// sound payload means tampering — the QR has been swapped for a
    /// different one mid-scan, or the bytes were corrupted in transport).
    nonisolated static func decode(_ blob: String) throws -> DecodedTransfer {
        let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw Error.malformed }
        let body = String(trimmed.dropFirst(prefix.count))
        guard let bytes = Data(base64Encoded: body) else { throw Error.malformed }
        // 32 (key) + 12 (nonce) + 64 (plaintext) + 16 (tag) = 124 bytes.
        // Anything shorter is structurally invalid.
        guard bytes.count == 32 + 12 + 64 + 16 else { throw Error.malformed }

        let keyBytes = bytes.prefix(32)
        let nonceBytes = bytes.dropFirst(32).prefix(12)
        let ciphertextAndTag = bytes.dropFirst(32 + 12)
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

        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                sealedBox,
                using: SymmetricKey(data: keyBytes)
            )
        } catch {
            throw Error.tampered
        }

        guard plaintext.count == 64 else { throw Error.malformed }
        let encryption: Curve25519.KeyAgreement.PrivateKey
        let signing: Curve25519.Signing.PrivateKey
        do {
            encryption = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: plaintext.prefix(32)
            )
            signing = try Curve25519.Signing.PrivateKey(
                rawRepresentation: plaintext.suffix(32)
            )
        } catch {
            throw Error.malformed
        }

        return DecodedTransfer(encryption: encryption, signing: signing)
    }

    // MARK: - Helper for fingerprint preview

    /// Compute the identity fingerprint for an in-flight DecodedTransfer
    /// so the receiving device can show "Replace with identity <ABCD-…>?"
    /// before destroying the local one. Mirrors the on-device
    /// `Identity.fingerprint` so the displayed value matches what the
    /// sending device shows in its identity card.
    nonisolated static func fingerprint(of transfer: DecodedTransfer) -> Data {
        let bundle = Identity.PublicBundle(
            encryptionPublicKey: transfer.encryption.publicKey,
            signingPublicKey: transfer.signing.publicKey
        )
        return Identity.fingerprint(of: bundle)
    }

    // MARK: - Types

    nonisolated struct DecodedTransfer {
        let encryption: Curve25519.KeyAgreement.PrivateKey
        let signing: Curve25519.Signing.PrivateKey
    }

    nonisolated enum Error: Swift.Error, Equatable {
        case malformed
        case tampered
    }
}
