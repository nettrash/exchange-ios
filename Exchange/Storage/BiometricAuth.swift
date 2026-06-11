//
//  BiometricAuth.swift
//  Exchange
//
//  Thin wrapper over LocalAuthentication for the optional app-lock.
//
//  Uses `.deviceOwnerAuthentication`, which tries Face ID / Touch ID /
//  Optic ID first and falls back to the device passcode. That fallback is
//  deliberate: a user with no enrolled biometrics, or a failed scan, can
//  still get in with their passcode rather than being locked out of their
//  own identity.
//
//  Shared with the iMessage extension via Storage/ (both targets compile
//  it through the synchronized source group).
//

import Foundation
import LocalAuthentication

nonisolated enum BiometricAuth {
    /// Whether the device can authenticate the owner at all (biometry or
    /// passcode). When false there is no mechanism to unlock, so callers
    /// fail *open* rather than lock the user out permanently.
    static func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Human-readable name of the strongest biometric the device offers,
    /// for buttons/labels ("Face ID", "Touch ID", "Optic ID"), or a
    /// generic fallback when only a passcode is available.
    static func biometryLabel() -> String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:       return "device passcode"
        }
    }

    /// Prompt the user to authenticate. Returns true on success. Never
    /// throws — any failure (cancel, lockout, unavailable) returns false
    /// so callers keep the lock screen up and let the user retry.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
