//
//  FilePayload.swift
//  Exchange
//
//  Framing for encrypting a *file* (rather than a typed message) inside a
//  CryptoEnvelope. The original filename travels alongside the bytes so
//  the recipient can restore it on decrypt.
//
//  This lives *inside* the encrypted plaintext — the EXC2 envelope format
//  is unchanged, so it stays byte-compatible across iOS / macOS / Android.
//  The decrypt side detects a file by the leading magic; anything without
//  it is treated as a plain message as before.
//
//  Layout of the framed plaintext:
//      offset  size  field
//      0       8     magic "EXCFILE1" (ASCII)
//      8       2     filename length, big-endian UInt16
//      10      L     filename (UTF-8)
//      10+L    …     file content bytes
//
//  Cross-platform counterpart: crypto/FilePayload.kt on Android.
//

import Foundation

nonisolated enum FilePayload {
    /// 8-byte ASCII marker that distinguishes a file payload from a plain
    /// text message inside the decrypted plaintext.
    static let magic = Data("EXCFILE1".utf8)

    struct DecodedFile: Equatable {
        let filename: String
        let content: Data
    }

    /// Frame a file's name + bytes into the plaintext that goes into
    /// `CryptoEnvelope.seal`.
    nonisolated static func encode(filename: String, content: Data) -> Data {
        // Clamp the (UTF-8) filename to what a UInt16 length can describe.
        var nameBytes = Array(filename.utf8)
        if nameBytes.count > 0xFFFF { nameBytes = Array(nameBytes.prefix(0xFFFF)) }

        var out = Data(capacity: magic.count + 2 + nameBytes.count + content.count)
        out.append(magic)
        let len = UInt16(nameBytes.count)
        out.append(UInt8(len >> 8))
        out.append(UInt8(len & 0xFF))
        out.append(contentsOf: nameBytes)
        out.append(content)
        return out
    }

    /// Reverse of `encode`. Returns nil when `data` is not a file payload
    /// (no magic) or is malformed — callers then treat it as a message.
    nonisolated static func decode(_ data: Data) -> DecodedFile? {
        let bytes = [UInt8](data)
        let magicBytes = [UInt8](magic)
        guard bytes.count >= magicBytes.count + 2,
              Array(bytes[0..<magicBytes.count]) == magicBytes else {
            return nil
        }
        let lenOffset = magicBytes.count
        let nameLen = Int(bytes[lenOffset]) << 8 | Int(bytes[lenOffset + 1])
        let nameStart = lenOffset + 2
        let nameEnd = nameStart + nameLen
        guard bytes.count >= nameEnd else { return nil }

        let nameData = Data(bytes[nameStart..<nameEnd])
        let filename = String(data: nameData, encoding: .utf8) ?? "file"
        let content = Data(bytes[nameEnd...])
        return DecodedFile(filename: filename, content: content)
    }
}
