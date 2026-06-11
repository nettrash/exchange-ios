//
//  AppLockSettings.swift
//  Exchange
//
//  Configurable biometric / passcode app-lock settings, shared between
//  the main app and the iMessage extension via App-Group UserDefaults so
//  the extension can honour the same lock + scope choices the user made
//  in the app's Settings.
//
//  This is a *UI gate*, not a cryptographic boundary: the identity
//  private keys are protected by the Keychain regardless. The lock keeps
//  someone holding an already-unlocked phone from reading your recipients
//  and decrypting messages inside Exchange.
//
//  Lives in Storage/ (not in the iMessage extension's exclusion set) so
//  both targets resolve it through the synchronized source group.
//

import Foundation

/// How long Exchange may sit in the background before it re-locks on
/// return to the foreground.
nonisolated enum AppLockTimeout: String, CaseIterable, Identifiable {
    case immediately
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case onlyOnLaunch

    nonisolated var id: String { rawValue }

    /// Background interval after which a foreground transition re-locks.
    /// `nil` means "never re-lock on foreground" — the app only locks on a
    /// cold launch.
    nonisolated var interval: TimeInterval? {
        switch self {
        case .immediately:    return 0
        case .oneMinute:      return 60
        case .fiveMinutes:    return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .onlyOnLaunch:   return nil
        }
    }

    nonisolated var label: String {
        switch self {
        case .immediately:    return "Immediately"
        case .oneMinute:      return "After 1 minute"
        case .fiveMinutes:    return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .onlyOnLaunch:   return "Only on launch"
        }
    }
}

nonisolated enum AppLockSettings {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
    private static let enabledKey = "appLock.enabled"
    private static let timeoutKey = "appLock.relockTimeout"
    private static let coversIncomingKey = "appLock.coversIncoming"

    /// Master switch. Off by default.
    static var isEnabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    /// Re-lock grace period. Defaults to immediate.
    static var relockTimeout: AppLockTimeout {
        get {
            guard let raw = defaults?.string(forKey: timeoutKey),
                  let value = AppLockTimeout(rawValue: raw) else { return .immediately }
            return value
        }
        set { defaults?.set(newValue.rawValue, forKey: timeoutKey) }
    }

    /// Whether the lock also gates incoming message links / shared
    /// envelopes and the iMessage extension — not just opening the main
    /// app. Defaults to true so "lock the app" means the obvious thing.
    static var coversIncoming: Bool {
        get { defaults?.object(forKey: coversIncomingKey) as? Bool ?? true }
        set { defaults?.set(newValue, forKey: coversIncomingKey) }
    }
}
