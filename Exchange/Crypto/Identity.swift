//
//  Identity.swift
//  Exchange
//
//  The local user's long-term keys.
//
//  An identity is a *pair* of Curve25519 keypairs:
//
//    - Encryption (X25519 / Curve25519.KeyAgreement). Used as the
//      recipient's static key in the hybrid ECDH+AEAD envelope.
//
//    - Signing (Ed25519 / Curve25519.Signing). Used by the sender to
//      sign every envelope so the recipient can authenticate who sent
//      it. (CryptoKit's "Curve25519.Signing" is, despite the name,
//      Ed25519 over the same underlying curve in its Edwards form.)
//
//  Both private keys live in the iOS Keychain as a single 64-byte blob
//  (32 ECDH + 32 Ed25519) under one account, accessible only after the
//  device is unlocked at least once and never via iCloud sync.
//
//  The "public bundle" is the pair of public keys that two users
//  exchange out of band — by QR or paste. It serializes as base64 of
//  64 bytes (the two raw representations concatenated, ECDH first).
//

import CryptoKit
import Foundation

nonisolated struct Identity {
    let encryptionPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let signingPrivateKey: Curve25519.Signing.PrivateKey

    var encryptionPublicKey: Curve25519.KeyAgreement.PublicKey {
        encryptionPrivateKey.publicKey
    }

    var signingPublicKey: Curve25519.Signing.PublicKey {
        signingPrivateKey.publicKey
    }

    var publicBundle: PublicBundle {
        PublicBundle(
            encryptionPublicKey: encryptionPublicKey,
            signingPublicKey: signingPublicKey
        )
    }

    /// Combined identity fingerprint (8 bytes of SHA-256 over both raw
    /// public keys, ECDH first). This is what the user sees in the UI;
    /// it changes if either of the keypairs is regenerated.
    var fingerprint: Data {
        Identity.fingerprint(of: publicBundle)
    }

    /// Encryption-only fingerprint, used inside the envelope to identify
    /// which recipient key it's addressed to. Exists separately from the
    /// combined fingerprint because the signing key isn't relevant to
    /// "is this envelope for me?".
    var encryptionFingerprint: Data {
        Identity.encryptionFingerprint(of: encryptionPublicKey)
    }

    // MARK: - Fingerprints

    nonisolated static func fingerprint(of bundle: PublicBundle) -> Data {
        let combined = bundle.encryptionPublicKey.rawRepresentation
            + bundle.signingPublicKey.rawRepresentation
        let digest = SHA256.hash(data: combined)
        return Data(digest.prefix(8))
    }

    nonisolated static func encryptionFingerprint(
        of key: Curve25519.KeyAgreement.PublicKey
    ) -> Data {
        let digest = SHA256.hash(data: key.rawRepresentation)
        return Data(digest.prefix(8))
    }

    // MARK: - PublicBundle text encoding

    /// Encode a public bundle as base64(encryption_pub || signing_pub),
    /// 64 raw bytes -> ~88 base64 characters. Suitable for paste / QR.
    nonisolated static func encode(publicBundle bundle: PublicBundle) -> String {
        (bundle.encryptionPublicKey.rawRepresentation
            + bundle.signingPublicKey.rawRepresentation)
            .base64EncodedString()
    }

    /// Inverse of encode(publicBundle:). Throws on malformed input.
    nonisolated static func decode(publicBundle base64: String) throws -> PublicBundle {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 64 else {
            throw IdentityError.malformedPublicKey
        }
        let encryptionPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: data.prefix(32)
        )
        let signingPub = try Curve25519.Signing.PublicKey(
            rawRepresentation: data.suffix(32)
        )
        return PublicBundle(
            encryptionPublicKey: encryptionPub,
            signingPublicKey: signingPub
        )
    }

    // MARK: - Nested types

    struct PublicBundle {
        let encryptionPublicKey: Curve25519.KeyAgreement.PublicKey
        let signingPublicKey: Curve25519.Signing.PublicKey
    }

    enum IdentityError: Error, Equatable {
        case malformedPublicKey
        case malformedPrivateKey
    }
}

/// Persistence boundary for `Identity`. Backed by Keychain.
nonisolated enum IdentityStore {
    /// Keychain account under which the 64-byte combined private-key blob
    /// is stored. Versioned so a future format change doesn't collide
    /// with existing data.
    static let account = "identity.private-keys.v2"

    /// Return the existing identity, or generate + persist a new one if absent.
    nonisolated static func loadOrCreate() throws -> Identity {
        if let existing = try load() {
            return existing
        }
        let encryption = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        try persist(encryption: encryption, signing: signing)
        return Identity(encryptionPrivateKey: encryption, signingPrivateKey: signing)
    }

    /// Return the existing identity, or `nil` if no identity has been generated yet.
    nonisolated static func load() throws -> Identity? {
        guard let data = try KeychainStore.get(account: account) else { return nil }
        guard data.count == 64 else { throw Identity.IdentityError.malformedPrivateKey }
        let encryption = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: data.prefix(32)
        )
        let signing = try Curve25519.Signing.PrivateKey(
            rawRepresentation: data.suffix(32)
        )
        return Identity(encryptionPrivateKey: encryption, signingPrivateKey: signing)
    }

    /// Replace the stored identity with the supplied keys. Used by import flow.
    @discardableResult
    nonisolated static func replace(
        encryption: Curve25519.KeyAgreement.PrivateKey,
        signing: Curve25519.Signing.PrivateKey
    ) throws -> Identity {
        try persist(encryption: encryption, signing: signing)
        return Identity(encryptionPrivateKey: encryption, signingPrivateKey: signing)
    }

    /// Wipe the identity from Keychain. Irreversible — every envelope ever
    /// addressed to the old key becomes unreadable.
    nonisolated static func reset() throws {
        try KeychainStore.delete(account: account)
    }

    private nonisolated static func persist(
        encryption: Curve25519.KeyAgreement.PrivateKey,
        signing: Curve25519.Signing.PrivateKey
    ) throws {
        let blob = encryption.rawRepresentation + signing.rawRepresentation
        try KeychainStore.set(blob, account: account)
    }
}
