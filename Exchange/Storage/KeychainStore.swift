//
//  KeychainStore.swift
//  Exchange
//
//  Thin wrapper over the iOS Keychain Services API for storing
//  small, sensitive byte blobs (e.g. our identity private key).
//
//  Items can be written in either of two storage modes:
//
//    - .syncing — `kSecAttrAccessibleAfterFirstUnlock` +
//      `kSecAttrSynchronizable: true`. The item is carried across the
//      user's same-Apple-ID devices via iCloud Keychain, which is itself
//      end-to-end encrypted. This is the v1.1 default for the identity
//      private keys, so users who run Exchange on iPhone + Mac (or
//      replace a phone) get a single coherent identity.
//
//    - .deviceOnly — `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
//      and *no* synchronizable bit. The item never leaves the device
//      via any Apple-mediated channel. v1.0 wrote everything in this
//      mode; v1.1 keeps it as an opt-out for users who prefer that
//      forward-secrecy guarantee.
//
//  iOS treats synchronizable and non-synchronizable items as *separate*
//  Keychain entries even when service+account match, so this module
//  exposes explicit per-mode read/write/delete plus a "match either"
//  variant used for normal lookups and reset.
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

    /// How a Keychain item is allowed to leave the local device.
    nonisolated enum StorageMode: Equatable {
        /// Synchronised across the user's Apple ID via iCloud Keychain.
        /// Survives device replacement and is shared between iPhone and
        /// Mac Catalyst on the same Apple ID. iCloud Keychain is itself
        /// end-to-end encrypted with a device-class secret.
        case syncing
        /// Pinned to this device. Skipped by iCloud Keychain sync, by
        /// encrypted iCloud backup-and-restore, and by device-to-device
        /// migration.
        case deviceOnly
    }

    // MARK: - Mode-aware single-item operations

    /// Insert or update a Data blob under `account` in the requested
    /// storage mode. Update is keyed on (service, account, sync flag) —
    /// switching modes for the same account requires a write in the new
    /// mode followed by a delete in the old mode (see `migrate(account:)`).
    nonisolated static func set(
        _ data: Data,
        account: String,
        mode: StorageMode
    ) throws {
        let baseQuery = baseQuery(account: account, mode: mode)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibility(for: mode)
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        default:
            throw KeychainError.unhandled(updateStatus)
        }
    }

    /// Look up a value in the specified mode only.
    nonisolated static func get(
        account: String,
        mode: StorageMode
    ) throws -> Data? {
        var query = baseQuery(account: account, mode: mode)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try fetch(query: query)
    }

    /// Look up a value in either mode. Returns the first one found,
    /// preferring the synchronised entry if both exist (which only
    /// happens transiently during a migration).
    nonisolated static func get(account: String) throws -> Data? {
        if let synced = try get(account: account, mode: .syncing) {
            return synced
        }
        return try get(account: account, mode: .deviceOnly)
    }

    /// Remove the item in the specified mode if present. No-op if absent.
    nonisolated static func delete(
        account: String,
        mode: StorageMode
    ) throws {
        let query = baseQuery(account: account, mode: mode)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandled(status)
        }
    }

    /// Remove every variant of `account` regardless of storage mode. Used
    /// by Reset Identity, where the user wants the keys gone in full.
    nonisolated static func delete(account: String) throws {
        try delete(account: account, mode: .syncing)
        try delete(account: account, mode: .deviceOnly)
    }

    // MARK: - Mode introspection

    /// Returns the mode the item is currently stored in, or nil if the
    /// account isn't present in either mode.
    nonisolated static func currentMode(account: String) throws -> StorageMode? {
        if try get(account: account, mode: .syncing) != nil {
            return .syncing
        }
        if try get(account: account, mode: .deviceOnly) != nil {
            return .deviceOnly
        }
        return nil
    }

    /// Move the item under `account` from one storage mode to another,
    /// preserving the byte blob. No-op if the item is already in the
    /// target mode. Atomic only in the sense that we write the new entry
    /// before deleting the old; if the process is killed between the
    /// two, both entries exist briefly and `get(account:)` resolves to
    /// the synchronised one (preserving the user's intended outcome).
    nonisolated static func migrate(
        account: String,
        to targetMode: StorageMode
    ) throws {
        guard let currentMode = try currentMode(account: account) else { return }
        guard currentMode != targetMode else { return }
        guard let data = try get(account: account, mode: currentMode) else { return }
        try set(data, account: account, mode: targetMode)
        try delete(account: account, mode: currentMode)
    }

    // MARK: - Internals

    private nonisolated static func baseQuery(
        account: String,
        mode: StorageMode
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizableValue(for: mode),
        ]
    }

    private nonisolated static func synchronizableValue(
        for mode: StorageMode
    ) -> CFBoolean {
        switch mode {
        case .syncing:    return kCFBooleanTrue
        case .deviceOnly: return kCFBooleanFalse
        }
    }

    private nonisolated static func accessibility(
        for mode: StorageMode
    ) -> CFString {
        switch mode {
        case .syncing:    return kSecAttrAccessibleAfterFirstUnlock
        case .deviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    private nonisolated static func fetch(query: [String: Any]) throws -> Data? {
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
}
