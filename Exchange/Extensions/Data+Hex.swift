//
//  Data+Hex.swift
//  Exchange
//
//  Hex encoding / decoding helpers used by fingerprints and tests.
//

import Foundation

nonisolated extension Data {
    /// Lowercase hex string of every byte, no separators.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Hex grouped into 4-character chunks separated by dashes,
    /// e.g. "a1b2-c3d4-e5f6-0708". Convenient for user-visible fingerprints.
    var groupedHex: String {
        let hex = hexString
        var groups: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[index..<next]))
            index = next
        }
        return groups.joined(separator: "-")
    }

    /// Parse a hex string. Spaces, dashes, and colons are ignored, so
    /// "AB CD-EF:01" is accepted.
    init?(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
