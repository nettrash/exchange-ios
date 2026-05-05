//
//  CryptoEnvelope.swift
//  Exchange
//
//  Hybrid public-key encryption with sender authentication. Format v2.
//
//  Per-message scheme:
//    1. Sender generates a fresh ephemeral Curve25519 keypair.
//    2. ECDH(ephemeral_priv, recipient_encryption_pub) -> shared secret.
//    3. HKDF-SHA256(shared, salt: ephemeral_pub, info: domain-tag)
//       -> 32-byte key-wrapping key.
//    4. Generate a fresh random 32-byte message key K.
//    5. ChaCha20-Poly1305 wrap K under the wrapping key.
//    6. ChaCha20-Poly1305 encrypt the plaintext under K.
//    7. Pack the bytes (see binary layout below).
//    8. Ed25519-sign all the packed bytes with the sender's signing
//       private key. Append the 64-byte signature.
//    9. Base64 the final blob and prefix with "EXC2:".
//
//  Recipient checks, in order:
//    - The 0x02 version byte is what we expect.
//    - The 8-byte recipient fingerprint matches our identity's
//      encryption fingerprint. (Cheap reject for "not for me.")
//    - The Ed25519 signature verifies under the embedded sender
//      signing public key.
//    - ECDH + HKDF + AEAD recover K and the plaintext.
//
//  The signature *embeds* the sender's signing public key inside the
//  envelope, so verification needs no out-of-band lookup. Whether that
//  embedded key actually belongs to a contact you trust is a UI-layer
//  concern — Decrypt views can match the key's bytes against the
//  Recipient list and either show "From Alice" or "Unknown sender".
//
//  Binary layout (v2, all fixed sizes):
//      offset  size  field
//      0       1     version byte (0x02)
//      1       8     recipient encryption-key fingerprint
//      9       32    sender Ed25519 signing public key
//      41      32    ephemeral X25519 public key
//      73      12    wrap nonce
//      85      32    wrapped K (ciphertext)
//      117     16    wrapped K (Poly1305 tag)
//      133     12    message nonce
//      145     N     message ciphertext
//      145+N   16    message Poly1305 tag
//      161+N   64    Ed25519 signature over bytes [0 .. 161+N-1]
//
//  Total fixed overhead: 225 bytes. Plus message length, plus base64
//  expansion, plus the "EXC2:" prefix. A 100-byte plaintext goes out as
//  ~440 base64 characters + 5 prefix = 445 chars.
//

import CryptoKit
import Foundation

nonisolated enum CryptoEnvelope {
    static let version: UInt8 = 0x02
    static let prefix: String = "EXC2:"
    static let hkdfInfo: Data = Data("exchange-v2-keywrap".utf8)

    // Fixed sizes (bytes)
    private static let fingerprintSize = 8
    private static let publicKeySize = 32
    private static let signingPublicKeySize = 32
    private static let nonceSize = 12
    private static let messageKeySize = 32
    private static let tagSize = 16
    private static let signatureSize = 64

    /// Total fixed overhead in the binary blob, before base64 / prefix.
    static let fixedOverhead = 1
        + fingerprintSize          // 8
        + signingPublicKeySize     // 32
        + publicKeySize            // 32
        + nonceSize                // 12
        + messageKeySize           // 32
        + tagSize                  // 16
        + nonceSize                // 12
        + tagSize                  // 16
        + signatureSize            // 64
                                   // == 225

    /// Offset (within the binary blob) at which the trailing signature begins.
    /// In other words: the signature covers bytes `[0 ..< signedRegionEnd(for:)]`
    /// where `signedRegionEnd(for: blobLength) = blobLength - signatureSize`.

    enum Error: Swift.Error, Equatable {
        /// The string is not a well-formed Exchange envelope.
        case malformedEnvelope
        /// We understand the framing but the version byte is one we don't speak.
        case unsupportedVersion(UInt8)
        /// The envelope is addressed to a different identity than the one we tried to open it with.
        case fingerprintMismatch
        /// The Ed25519 signature didn't verify under the embedded sender key.
        /// The envelope was tampered with after it was signed, OR the embedded
        /// sender public key is bogus.
        case signatureVerificationFailed
        /// AEAD failed: ciphertext or tag was modified, or key derivation went wrong.
        case decryptionFailed
    }

    /// Result of opening an envelope.
    struct Opened: Equatable {
        /// Decrypted message body.
        let plaintext: Data
        /// Recipient fingerprint the envelope was addressed to (matches the opener).
        let recipientFingerprint: Data
        /// Raw 32-byte Ed25519 public key of the sender (as the envelope claimed).
        /// The signature has been verified against this key. Whether this key
        /// actually belongs to a known contact is a UI-layer decision.
        let senderSigningPublicKey: Data
        /// Ephemeral X25519 public key, useful as a per-message session ID.
        let ephemeralPublicKey: Data
    }

    // MARK: - Seal

    /// Encrypt `plaintext` for delivery to `recipientEncryptionPublicKey`,
    /// signed by `sender`. Returns an ASCII-armored envelope string.
    nonisolated static func seal(
        plaintext: Data,
        to recipientEncryptionPublicKey: Curve25519.KeyAgreement.PublicKey,
        from sender: Identity
    ) throws -> String {
        let recipientFingerprint = Identity.encryptionFingerprint(
            of: recipientEncryptionPublicKey
        )
        let senderSigningPublicKey = sender.signingPublicKey.rawRepresentation

        // (1) ephemeral keypair
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicData = ephemeralPrivate.publicKey.rawRepresentation

        // (2) ECDH and (3) HKDF -> wrapping key
        let wrappingKey = try deriveWrappingKey(
            ephemeralPrivate: ephemeralPrivate,
            otherPublic: recipientEncryptionPublicKey,
            ephemeralPublicData: ephemeralPublicData
        )

        // (4) fresh per-message symmetric key
        let messageKey = SymmetricKey(size: .bits256)
        let messageKeyBytes = messageKey.withUnsafeBytes { Data($0) }

        // (5) wrap K
        let wrappedKey = try ChaChaPoly.seal(messageKeyBytes, using: wrappingKey)
        // (6) encrypt body
        let body = try ChaChaPoly.seal(plaintext, using: messageKey)

        // (7) pack everything except the trailing signature
        var blob = Data(capacity: fixedOverhead + plaintext.count)
        blob.append(version)
        blob.append(recipientFingerprint)
        blob.append(senderSigningPublicKey)
        blob.append(ephemeralPublicData)
        blob.append(contentsOf: wrappedKey.nonce)
        blob.append(wrappedKey.ciphertext)
        blob.append(wrappedKey.tag)
        blob.append(contentsOf: body.nonce)
        blob.append(body.ciphertext)
        blob.append(body.tag)

        // (8) sign and append
        let signature = try sender.signingPrivateKey.signature(for: blob)
        blob.append(signature)

        // (9) ASCII armor
        return prefix + blob.base64EncodedString()
    }

    // MARK: - Open

    /// Decrypt an envelope string with the supplied identity. Throws if
    /// the envelope is malformed, addressed elsewhere, signature-invalid,
    /// or AEAD-tampered.
    nonisolated static func open(
        envelope: String,
        with identity: Identity
    ) throws -> Opened {
        let trimmed = envelope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw Error.malformedEnvelope }
        let base64 = String(trimmed.dropFirst(prefix.count))
        guard let blob = Data(base64Encoded: base64) else { throw Error.malformedEnvelope }
        guard blob.count >= fixedOverhead else { throw Error.malformedEnvelope }

        let bytes = [UInt8](blob)
        var offset = 0

        // version
        let versionByte = bytes[offset]; offset += 1
        guard versionByte == version else { throw Error.unsupportedVersion(versionByte) }

        // recipient fingerprint
        let fingerprint = Data(bytes[offset..<offset + fingerprintSize])
        offset += fingerprintSize

        // sender signing public key
        let senderSigningPublicKeyData = Data(bytes[offset..<offset + signingPublicKeySize])
        offset += signingPublicKeySize

        // ephemeral X25519 public key
        let ephemeralPublicData = Data(bytes[offset..<offset + publicKeySize])
        offset += publicKeySize

        // wrap nonce + wrapped K + tag
        let wrapNonceData = Data(bytes[offset..<offset + nonceSize])
        offset += nonceSize
        let wrappedCiphertext = Data(bytes[offset..<offset + messageKeySize])
        offset += messageKeySize
        let wrappedTag = Data(bytes[offset..<offset + tagSize])
        offset += tagSize

        // body
        let messageNonceData = Data(bytes[offset..<offset + nonceSize])
        offset += nonceSize

        // The body ciphertext is everything from `offset` up to
        // (totalLength - signatureSize - tagSize) and the body tag is the
        // 16 bytes immediately before the trailing 64-byte signature.
        let signatureStart = bytes.count - signatureSize
        let bodyCiphertextEnd = signatureStart - tagSize
        guard bodyCiphertextEnd >= offset else { throw Error.malformedEnvelope }
        let messageCiphertext = Data(bytes[offset..<bodyCiphertextEnd])
        let messageTag = Data(bytes[bodyCiphertextEnd..<signatureStart])
        let signatureData = Data(bytes[signatureStart..<bytes.count])

        // 1. Cheap "not for me" reject before any expensive crypto.
        guard fingerprint == identity.encryptionFingerprint else {
            throw Error.fingerprintMismatch
        }

        // 2. Verify the signature next, before doing any ECDH or AEAD work.
        //    This means we never touch the recipient's private key for an
        //    envelope that's been forged or modified.
        let senderSigningPublicKey: Curve25519.Signing.PublicKey
        do {
            senderSigningPublicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: senderSigningPublicKeyData
            )
        } catch {
            throw Error.malformedEnvelope
        }
        let signedRegion = blob.prefix(blob.count - signatureSize)
        guard senderSigningPublicKey.isValidSignature(signatureData, for: signedRegion) else {
            throw Error.signatureVerificationFailed
        }

        // 3. ECDH + HKDF -> wrapping key
        let ephemeralPublic: Curve25519.KeyAgreement.PublicKey
        do {
            ephemeralPublic = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: ephemeralPublicData
            )
        } catch {
            throw Error.malformedEnvelope
        }

        let wrappingKey: SymmetricKey
        do {
            wrappingKey = try deriveWrappingKey(
                ephemeralPrivate: identity.encryptionPrivateKey,
                otherPublic: ephemeralPublic,
                ephemeralPublicData: ephemeralPublicData
            )
        } catch {
            throw Error.decryptionFailed
        }

        // 4. Unwrap K
        let messageKeyBytes: Data
        do {
            let nonce = try ChaChaPoly.Nonce(data: wrapNonceData)
            let sealed = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: wrappedCiphertext,
                tag: wrappedTag
            )
            messageKeyBytes = try ChaChaPoly.open(sealed, using: wrappingKey)
        } catch {
            throw Error.decryptionFailed
        }
        guard messageKeyBytes.count == messageKeySize else {
            throw Error.decryptionFailed
        }
        let messageKey = SymmetricKey(data: messageKeyBytes)

        // 5. Decrypt body
        let plaintext: Data
        do {
            let nonce = try ChaChaPoly.Nonce(data: messageNonceData)
            let sealed = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: messageCiphertext,
                tag: messageTag
            )
            plaintext = try ChaChaPoly.open(sealed, using: messageKey)
        } catch {
            throw Error.decryptionFailed
        }

        return Opened(
            plaintext: plaintext,
            recipientFingerprint: fingerprint,
            senderSigningPublicKey: senderSigningPublicKeyData,
            ephemeralPublicKey: ephemeralPublicData
        )
    }

    // MARK: - Helpers

    /// X25519 ECDH + HKDF-SHA256 -> 32-byte symmetric key.
    /// `ephemeralPublicData` is included in the salt for domain
    /// separation across messages even though the ECDH already binds to it.
    private nonisolated static func deriveWrappingKey(
        ephemeralPrivate: Curve25519.KeyAgreement.PrivateKey,
        otherPublic: Curve25519.KeyAgreement.PublicKey,
        ephemeralPublicData: Data
    ) throws -> SymmetricKey {
        let shared = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: otherPublic)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPublicData,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
    }
}
