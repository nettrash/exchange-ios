//
//  KeychainStore.swift
//  Exchange
//
//  Thin wrapper over the iOS Keychain Services API for storing
//  small, sensitive byte blobs (e.g. our identity private key).
//
//  All items are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
//  so they survive lock-screen access by background tasks but never leave
//  the device via iCloud Keychain sync. Identity does not migrate to a new
//  device — restoring from backup gives you the recipient list back, but
//  the new device generates a fresh identity on first launch.
//

import Foundation
import Security

nonisolated enum KeychainError: Error, Equatable {
    case unhandled(OSStatus)
    case unexpectedData
}

nonisolated enum KeychainStore {
    /// Service identifier shared by every Keychain item this app writes.
    /// Match the app bundle identifier so a future App Group can be added
    /// without renaming everything.
    static let service = "me.nettrash.Exchange"

    /// Insert or update a Data blob under `account`.
    nonisolated static func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        default:
            throw KeychainError.unhandled(updateStatus)
        }
    }

    /// Fetch a Data blob, or `nil` if the account isn't present.
    nonisolated static func get(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    /// Remove the item under `account` if present. No-op if absent.
    nonisolated static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandled(status)
        }
    }
}
