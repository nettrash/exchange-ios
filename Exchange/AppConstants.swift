//
//  AppConstants.swift
//  Exchange
//
//  Single source of truth for identifiers shared across targets:
//  - the main Exchange app
//  - the iMessage extension (shared SwiftData store + same identity)
//  - any other extension we add later
//
//  This file is added to the iMessage extension's target membership in
//  Xcode so both targets resolve the same string at compile time. If
//  Apple's App Group dashboard ever shows you a different identifier,
//  change it here and rebuild — it's the only place to update.
//

import Foundation

nonisolated enum AppConstants {
    /// App Group used for the SwiftData container. Both the main app and
    /// the iMessage extension need this identifier in their entitlements
    /// and need to pass it to `ModelConfiguration(groupContainer:)`.
    static let appGroupIdentifier = "group.me.nettrash.Exchange"

    /// Keychain access group (the suffix; the team prefix is added at
    /// build time via `$(AppIdentifierPrefix)`). Both targets list this
    /// in their `keychain-access-groups` entitlement so they read the
    /// same identity item.
    static let keychainAccessGroupSuffix = "me.nettrash.Exchange"
}
