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
///
/// As of v1.1 the identity private keys default to **iCloud-Keychain
/// synchronised** storage so that the same identity flows across the
/// user's devices on the same Apple ID (iPhone ↔ Mac Catalyst, and
/// across device replacement). v1.0 wrote everything as ThisDeviceOnly;
/// `loadOrCreate` auto-migrates that legacy entry to the synchronised
/// mode on first launch under v1.1.
///
/// Users who want the original v1.0 forward-secrecy guarantee can flip
/// the toggle in Settings, which calls `setSyncEnabled(false)` and
/// migrates the entry back to `.deviceOnly`. Either way, the keys
/// never leave the user's devices in plaintext — iCloud Keychain is
/// itself end-to-end encrypted with a device-class secret.
nonisolated enum IdentityStore {
    /// Keychain account under which the 64-byte combined private-key blob
    /// is stored. Versioned so a future format change doesn't collide
    /// with existing data.
    static let account = "identity.private-keys.v2"

    /// Storage mode used when *creating* a fresh identity (i.e. no
    /// existing entry on this device or in iCloud Keychain). v1.1
    /// chooses `.syncing` so multi-device users get the smooth flow
    /// without having to know that an iCloud-Keychain toggle exists.
    static let defaultStorageMode: KeychainStore.StorageMode = .syncing

    // MARK: - Public load / create

    /// Return the existing identity, generating + persisting a new one
    /// if absent. Implicitly upgrades a v1.0 ThisDeviceOnly entry to the
    /// v1.1 default by writing a new synchronised entry and deleting the
    /// old one — so users who had Exchange installed before v1.1 silently
    /// gain iCloud Keychain sync without any prompt or surprise.
    nonisolated static func loadOrCreate() throws -> Identity {
        if let existing = try load() {
            // Auto-migration: a v1.0 install would only have a
            // .deviceOnly entry. Promote it to .syncing so the user
            // gets the v1.1 default. They can opt back out via
            // Settings if they prefer the old guarantee.
            if try KeychainStore.currentMode(account: account) == .deviceOnly {
                try KeychainStore.migrate(account: account, to: .syncing)
            }
            return existing
        }
        let encryption = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        try persist(encryption: encryption, signing: signing, mode: defaultStorageMode)
        return Identity(encryptionPrivateKey: encryption, signingPrivateKey: signing)
    }

    /// Return the existing identity, or `nil` if no identity has been
    /// generated yet. Reads from either storage mode — useful in early
    /// boot before we've decided what mode the user wants going forward.
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

    /// Replace the stored identity with the supplied keys. Used by the
    /// import / restore / QR-receive flows. Preserves whatever storage
    /// mode is currently active (so a user who's turned sync off doesn't
    /// have it silently turned back on by performing a restore).
    @discardableResult
    nonisolated static func replace(
        encryption: Curve25519.KeyAgreement.PrivateKey,
        signing: Curve25519.Signing.PrivateKey
    ) throws -> Identity {
        let mode = try KeychainStore.currentMode(account: account) ?? defaultStorageMode
        try persist(encryption: encryption, signing: signing, mode: mode)
        return Identity(encryptionPrivateKey: encryption, signingPrivateKey: signing)
    }

    /// Wipe the identity from Keychain. Irreversible — every envelope ever
    /// addressed to the old key becomes unreadable. Removes both
    /// synchronised and device-only variants, in case the user toggled
    /// modes in the past and a stale entry of the other type lingers.
    nonisolated static func reset() throws {
        try KeychainStore.delete(account: account)
    }

    // MARK: - Sync toggle

    /// Whether the identity is currently stored in iCloud-Keychain-
    /// synchronised mode. Returns the v1.1 default when the keychain is
    /// empty (so the Settings toggle reflects what *would* happen for
    /// the next identity generated).
    nonisolated static func isSyncEnabled() throws -> Bool {
        let mode = try KeychainStore.currentMode(account: account)
            ?? defaultStorageMode
        return mode == .syncing
    }

    /// Switch the identity Keychain entry between synchronised and
    /// device-only storage. No-op if no identity exists yet — the next
    /// `loadOrCreate` will pick up `defaultStorageMode`. The migration
    /// is silent and reversible; the same 64 bytes survive the move.
    nonisolated static func setSyncEnabled(_ enabled: Bool) throws {
        let target: KeychainStore.StorageMode = enabled ? .syncing : .deviceOnly
        try KeychainStore.migrate(account: account, to: target)
    }

    // MARK: - Internals

    private nonisolated static func persist(
        encryption: Curve25519.KeyAgreement.PrivateKey,
        signing: Curve25519.Signing.PrivateKey,
        mode: KeychainStore.StorageMode
    ) throws {
        let blob = encryption.rawRepresentation + signing.rawRepresentation
        try KeychainStore.set(blob, account: account, mode: mode)
    }
}
