//
//  CryptoEnvelopeTests.swift
//  ExchangeTests
//
//  Round-trip, signature verification, and tamper-detection tests for
//  the v2 hybrid envelope.
//

import CryptoKit
import Foundation
import Testing
@testable import Exchange

struct CryptoEnvelopeTests {

    // MARK: - Helpers

    private func makeIdentity() -> Identity {
        Identity(
            encryptionPrivateKey: .init(),
            signingPrivateKey: .init()
        )
    }

    // MARK: - Round trip

    @Test
    func roundTripsShortMessage() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        let plaintext = Data("hello bob".utf8)

        let envelope = try CryptoEnvelope.seal(
            plaintext: plaintext,
            to: bob.encryptionPublicKey,
            from: alice
        )
        let opened = try CryptoEnvelope.open(envelope: envelope, with: bob)

        #expect(opened.plaintext == plaintext)
        #expect(opened.recipientFingerprint == bob.encryptionFingerprint)
        #expect(opened.senderSigningPublicKey == alice.signingPublicKey.rawRepresentation)
        #expect(opened.ephemeralPublicKey.count == 32)
    }

    @Test
    func roundTripsLongMessage() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        var bytes = [UInt8](repeating: 0, count: 10_000)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let plaintext = Data(bytes)

        let envelope = try CryptoEnvelope.seal(
            plaintext: plaintext,
            to: bob.encryptionPublicKey,
            from: alice
        )
        let opened = try CryptoEnvelope.open(envelope: envelope, with: bob)

        #expect(opened.plaintext == plaintext)
        #expect(opened.senderSigningPublicKey == alice.signingPublicKey.rawRepresentation)
    }

    @Test
    func roundTripsEmptyMessage() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()

        let envelope = try CryptoEnvelope.seal(
            plaintext: Data(),
            to: bob.encryptionPublicKey,
            from: alice
        )
        let opened = try CryptoEnvelope.open(envelope: envelope, with: bob)

        #expect(opened.plaintext == Data())
    }

    @Test
    func envelopeUsesAsciiArmorPrefix() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        let envelope = try CryptoEnvelope.seal(
            plaintext: Data("hi".utf8),
            to: bob.encryptionPublicKey,
            from: alice
        )

        #expect(envelope.hasPrefix("EXC2:"))
        let body = String(envelope.dropFirst("EXC2:".count))
        #expect(Data(base64Encoded: body) != nil)
    }

    // MARK: - Freshness

    @Test
    func freshEphemeralProducesDifferentEnvelopes() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        let plaintext = Data("repeatable".utf8)

        let env1 = try CryptoEnvelope.seal(plaintext: plaintext, to: bob.encryptionPublicKey, from: alice)
        let env2 = try CryptoEnvelope.seal(plaintext: plaintext, to: bob.encryptionPublicKey, from: alice)

        #expect(env1 != env2)
        #expect(try CryptoEnvelope.open(envelope: env1, with: bob).plaintext == plaintext)
        #expect(try CryptoEnvelope.open(envelope: env2, with: bob).plaintext == plaintext)
    }

    // MARK: - Wrong recipient

    @Test
    func wrongRecipientRejectedByFingerprint() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        let mallory = makeIdentity()

        let envelope = try CryptoEnvelope.seal(
            plaintext: Data("for bob".utf8),
            to: bob.encryptionPublicKey,
            from: alice
        )
        let thrown = #expect(throws: CryptoEnvelope.Error.self) {
            _ = try CryptoEnvelope.open(envelope: envelope, with: mallory)
        }
        #expect(thrown == .fingerprintMismatch)
    }

    // MARK: - Signature verification

    @Test
    func flippedMessageTagFailsSignatureVerification() throws {
        // The signature covers everything in the binary blob except the
        // trailing 64-byte signature itself. So flipping a byte inside the
        // message ciphertext-or-tag region triggers signature failure
        // before we ever attempt AEAD.
        let alice = makeIdentity()
        let bob = makeIdentity()
        let envelope = try CryptoEnvelope.seal(
            plaintext: Data("important".utf8),
            to: bob.encryptionPublicKey,
            from: alice
        )
        // Byte at offset 200 is somewhere in the body / its tag — covered by sig.
        let tampered = try EnvelopeMutator.flipBit(in: envelope, atOffset: 200)
        let thrown = #expect(throws: CryptoEnvelope.Error.self) {
            _ = try CryptoEnvelope.open(envelope: tampered, with: bob)
        }
        #expect(thrown == .signatureVerificationFailed)
    }

    @Test
    func flippedSignatureByteFailsSignatureVerification() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        let envelope = try CryptoEnvelope.seal(
            plaintext: Data("important".utf8),
            to: bob.encryptionPublicKey,
            from: alice
        )
        // The last byte is the trailing signature byte.
        let tampered = try EnvelopeMutator.flipLastBit(in: envelope)
        let thrown = #expect(throws: CryptoEnvelope.Error.self) {
            _ = try CryptoEnvelope.open(envelope: tampered, with: bob)
        }
        #expect(thrown == .signatureVerificationFailed)
    }

    @Test
    func flippedFingerprintByteRejectedBeforeSignatureCheck() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        let envelope = try CryptoEnvelope.seal(
            plaintext: Data("x".utf8),
            to: bob.encryptionPublicKey,
            from: alice
        )
        // Fingerprint bytes are at offsets 1..9. We check fingerprint
        // before signature, so the typed error is fingerprintMismatch
        // (cheap reject for "not for me").
        let tampered = try EnvelopeMutator.flipBit(in: envelope, atOffset: 1)
        let thrown = #expect(throws: CryptoEnvelope.Error.self) {
            _ = try CryptoEnvelope.open(envelope: tampered, with: bob)
        }
        #expect(thrown == .fingerprintMismatch)
    }

    @Test
    func reSigningWithDifferentKeyChangesSenderInOpened() throws {
        // Mallory takes Alice's envelope addressed to Bob, replaces the
        // sender key + signature with her own. The fingerprint still
        // addresses Bob, so it decrypts. But the recovered sender key
        // is Mallory's, not Alice's — the receiver can detect the swap
        // by matching the senderSigningPublicKey against their contacts.
        let alice = makeIdentity()
        let bob = makeIdentity()
        let mallory = makeIdentity()

        let original = try CryptoEnvelope.seal(
            plaintext: Data("hello bob".utf8),
            to: bob.encryptionPublicKey,
            from: alice
        )

        // Decode, replace sender key bytes (offsets 9..41), re-sign with
        // mallory's signing key over bytes [0..end-64], replace sig bytes.
        let prefix = "EXC2:"
        let body = String(original.dropFirst(prefix.count))
        var blob = Array(Data(base64Encoded: body)!)

        let mallorySigningPub = mallory.signingPublicKey.rawRepresentation
        for (i, byte) in mallorySigningPub.enumerated() {
            blob[9 + i] = byte
        }
        let signedRegion = Data(blob[0..<(blob.count - 64)])
        let newSig = try mallory.signingPrivateKey.signature(for: signedRegion)
        for (i, byte) in newSig.enumerated() {
            blob[blob.count - 64 + i] = byte
        }
        let forged = prefix + Data(blob).base64EncodedString()

        let opened = try CryptoEnvelope.open(envelope: forged, with: bob)
        // Decryption succeeded — Mallory used a fresh ephemeral, ECDH'd
        // against bob's encryption pub, encrypted under that key. Fine.
        // BUT the senderSigningPublicKey reflects Mallory, not Alice:
        #expect(opened.senderSigningPublicKey == mallory.signingPublicKey.rawRepresentation)
        #expect(opened.senderSigningPublicKey != alice.signingPublicKey.rawRepresentation)
    }

    // MARK: - Versioning

    @Test
    func unsupportedVersionByteRejected() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        let envelope = try CryptoEnvelope.seal(
            plaintext: Data("x".utf8),
            to: bob.encryptionPublicKey,
            from: alice
        )
        let tampered = try EnvelopeMutator.replaceByte(in: envelope, atOffset: 0, with: 0x99)
        let thrown = #expect(throws: CryptoEnvelope.Error.self) {
            _ = try CryptoEnvelope.open(envelope: tampered, with: bob)
        }
        #expect(thrown == .unsupportedVersion(0x99))
    }

    // MARK: - Malformed input

    @Test
    func nonEnvelopeStringRejected() throws {
        let bob = makeIdentity()
        let thrown = #expect(throws: CryptoEnvelope.Error.self) {
            _ = try CryptoEnvelope.open(envelope: "not an envelope", with: bob)
        }
        #expect(thrown == .malformedEnvelope)
    }

    @Test
    func nonBase64BodyRejected() throws {
        let bob = makeIdentity()
        let thrown = #expect(throws: CryptoEnvelope.Error.self) {
            _ = try CryptoEnvelope.open(envelope: "EXC2:not_base64!!!!", with: bob)
        }
        #expect(thrown == .malformedEnvelope)
    }

    @Test
    func tooShortEnvelopeRejected() throws {
        let bob = makeIdentity()
        let shortBlob = Data([CryptoEnvelope.version]).base64EncodedString()
        let thrown = #expect(throws: CryptoEnvelope.Error.self) {
            _ = try CryptoEnvelope.open(envelope: "EXC2:" + shortBlob, with: bob)
        }
        #expect(thrown == .malformedEnvelope)
    }

    // MARK: - Identity helpers

    @Test
    func publicBundleEncodingRoundTrips() throws {
        let alice = makeIdentity()
        let encoded = Identity.encode(publicBundle: alice.publicBundle)
        let decoded = try Identity.decode(publicBundle: encoded)
        #expect(decoded.encryptionPublicKey.rawRepresentation
                == alice.encryptionPublicKey.rawRepresentation)
        #expect(decoded.signingPublicKey.rawRepresentation
                == alice.signingPublicKey.rawRepresentation)
    }

    @Test
    func malformedPublicBundleImportRejected() throws {
        #expect(throws: Identity.IdentityError.self) {
            _ = try Identity.decode(publicBundle: "%%%not base64%%%")
        }
        // Not 64 bytes after decode -> malformedPublicKey.
        #expect(throws: Identity.IdentityError.self) {
            _ = try Identity.decode(publicBundle: Data([0x01, 0x02]).base64EncodedString())
        }
    }

    @Test
    func combinedFingerprintIsStableEightBytes() throws {
        let identity = makeIdentity()
        let fp1 = Identity.fingerprint(of: identity.publicBundle)
        let fp2 = Identity.fingerprint(of: identity.publicBundle)
        #expect(fp1 == fp2)
        #expect(fp1.count == 8)
    }

    @Test
    func differentBundlesHaveDifferentFingerprints() throws {
        let a = makeIdentity().publicBundle
        let b = makeIdentity().publicBundle
        #expect(Identity.fingerprint(of: a) != Identity.fingerprint(of: b))
    }

    @Test
    func encryptionFingerprintMatchesEnvelopeAddressing() throws {
        let alice = makeIdentity()
        let bob = makeIdentity()
        let envelope = try CryptoEnvelope.seal(
            plaintext: Data("hi".utf8),
            to: bob.encryptionPublicKey,
            from: alice
        )
        let opened = try CryptoEnvelope.open(envelope: envelope, with: bob)
        #expect(opened.recipientFingerprint == bob.encryptionFingerprint)
    }
}

// MARK: - Test utilities

/// Helpers for surgically corrupting the binary envelope inside an
/// EXC2:<base64> string while keeping the framing intact.
private enum EnvelopeMutator {
    static func decodedBytes(_ envelope: String) throws -> [UInt8] {
        guard envelope.hasPrefix("EXC2:") else {
            throw CryptoEnvelope.Error.malformedEnvelope
        }
        let body = String(envelope.dropFirst("EXC2:".count))
        guard let data = Data(base64Encoded: body) else {
            throw CryptoEnvelope.Error.malformedEnvelope
        }
        return Array(data)
    }

    static func reencode(_ bytes: [UInt8]) -> String {
        "EXC2:" + Data(bytes).base64EncodedString()
    }

    static func flipBit(in envelope: String, atOffset offset: Int) throws -> String {
        var bytes = try decodedBytes(envelope)
        bytes[offset] ^= 0x01
        return reencode(bytes)
    }

    static func flipLastBit(in envelope: String) throws -> String {
        var bytes = try decodedBytes(envelope)
        bytes[bytes.count - 1] ^= 0x01
        return reencode(bytes)
    }

    static func replaceByte(in envelope: String, atOffset offset: Int, with value: UInt8) throws -> String {
        var bytes = try decodedBytes(envelope)
        bytes[offset] = value
        return reencode(bytes)
    }
}
