//
//  RecipientsSyncCoordinator.swift
//  Exchange
//
//  Glues `RecipientsSync` (the encrypt/encode of the recipient blob) to
//  the rest of the app:
//
//    - pulls the remote blob on launch and on app-foreground;
//    - listens to SwiftData saves (via the underlying CoreData
//      `NSManagedObjectContextDidSave` notification) and debounces
//      whole-list pushes;
//    - exposes a `setSyncEnabled(_:)` toggle that tags a UserDefaults
//      flag and either resumes or pauses the loop;
//    - knows how to wipe the synchronised blob when the identity is
//      reset, so a fresh identity doesn't inherit stale recipients
//      from another device.
//
//  All state is `@MainActor`-bound; the coordinator is a long-lived
//  observable owned by `ExchangeApp` and surfaced through the SwiftUI
//  Environment so views can flip the toggle directly.
//

import CoreData
import CryptoKit
import Foundation
import Observation
import SwiftData
import UIKit

@Observable
@MainActor
final class RecipientsSyncCoordinator {
    // MARK: - User-facing state

    /// Whether the coordinator should try to push and pull. Reflects
    /// the UserDefaults flag and is the binding the Settings toggle
    /// reads / writes.
    private(set) var syncEnabled: Bool

    /// The most recent error from a push or pull operation, if any.
    /// Settings shows this so the user has a chance to react when iCloud
    /// Keychain isn't reachable or the blob can't be decoded.
    private(set) var lastErrorMessage: String?

    // MARK: - Internals

    private let modelContainer: ModelContainer
    /// Separate `ModelContext` used for the merge step (pulling the
    /// remote blob and applying inserts / deletes). Kept distinct from
    /// the main UI context so saves here don't compete with whatever
    /// the user is doing in `@Query`-bound views; SwiftData propagates
    /// changes to the UI context through the underlying persistent
    /// store coordinator. Both contexts share the same MainActor in
    /// this implementation — recipient lists are tiny so the merge
    /// runs in a couple of milliseconds even on the main thread.
    private let mergeContext: ModelContext

    /// Last identity we observed. Re-derived blob keys depend on this;
    /// when the user resets / imports / scans a new identity, we must
    /// re-pull (the old blob can't be decrypted anymore) and re-push
    /// (so other devices can find the new shape).
    private var currentIdentity: Identity?

    /// Debounce timer for outgoing pushes. SwiftData often emits several
    /// `didSave` notifications in quick succession (e.g. a bulk insert
    /// from Import Identity); we only want the last state to land in
    /// iCloud Keychain.
    private var pushDebounceTask: Task<Void, Never>?

    /// Identifier for the `NSManagedObjectContextDidSave` observer so we
    /// can detach during `deinit`. Marked `nonisolated(unsafe)` because
    /// `deinit` runs in a non-isolated context under Swift 6 strict
    /// concurrency, but we only ever read these tokens there (after
    /// they've been written exactly once during the MainActor-bound
    /// init), and `NotificationCenter.removeObserver(_:)` is itself
    /// thread-safe — so the read is genuinely safe.
    nonisolated(unsafe) private var saveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?

    // MARK: - Persistence keys

    /// UserDefaults key for the on/off toggle. The default is "absent =
    /// ON" so v1.1 starts syncing automatically.
    private static let userDefaultsKey = "RecipientsSync.enabled.v1"

    // MARK: - Lifecycle

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.mergeContext = ModelContext(modelContainer)
        let stored = UserDefaults.standard.object(forKey: Self.userDefaultsKey) as? Bool
        self.syncEnabled = stored ?? true

        // SwiftData hands `NSManagedObjectContextDidSave` for every
        // context save, including the main one driven by SwiftUI views.
        // Listening on `.main` guarantees the closure body runs on the
        // main thread, so we use `MainActor.assumeIsolated` to enter
        // main-actor isolation synchronously instead of spawning a
        // detached `Task` (which would have to capture the non-Sendable
        // `note` across the boundary — disallowed under Swift 6).
        saveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleContextDidSave(note)
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.pullIfPossible(reason: "foreground") }
            }
        }
    }

    deinit {
        if let saveObserver {
            NotificationCenter.default.removeObserver(saveObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    // MARK: - Identity lifecycle

    /// Called by `ExchangeApp` once the identity has loaded, and again
    /// any time the identity changes (Reset / Import / QR Receive).
    /// Triggers an initial pull, then a push so the local state is
    /// reflected in iCloud Keychain even on a brand-new identity.
    func bind(identity: Identity) async {
        currentIdentity = identity
        await pullIfPossible(reason: "identity-bind")
        // Push to make sure the remote reflects whatever the local
        // store has after the merge — important on first run with sync
        // turned on, and on identity replace where the blob may need
        // to be re-encrypted under the new derived key.
        schedulePush()
    }

    /// Called by `ContentView.resetIdentity` immediately after wiping
    /// the local identity + recipients. Removes the synchronised blob
    /// from Keychain so the freshly-generated identity (which has a
    /// different derived key anyway) doesn't see leftover ciphertext
    /// from the previous incarnation.
    func wipeRemoteForReset() {
        try? KeychainStore.delete(account: RecipientsSync.account)
        currentIdentity = nil
        pushDebounceTask?.cancel()
    }

    // MARK: - User-facing toggle

    func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.userDefaultsKey)
        if enabled {
            // Resume: pull whatever's there (possibly written by another
            // device while we were off), then push our own state.
            Task { @MainActor in
                await self.pullIfPossible(reason: "toggle-on")
                self.schedulePush()
            }
        } else {
            // Pause: cancel any pending push, but leave the existing
            // remote blob alone (other devices may still be using it).
            // The user can clear it explicitly with Reset identity.
            pushDebounceTask?.cancel()
        }
    }

    // MARK: - Push

    private func handleContextDidSave(_ notification: Notification) {
        guard syncEnabled else { return }
        // Filter for inserts / updates / deletes on Recipient. SwiftData's
        // `Recipient` is a CoreData `NSManagedObject` under the hood, so
        // the entity name matches the class name.
        guard let userInfo = notification.userInfo else { return }
        let touchedRecipient = ["inserted", "updated", "deleted"].contains { key in
            guard let set = userInfo[key] as? Set<NSManagedObject> else { return false }
            return set.contains { $0.entity.name == "Recipient" }
        }
        guard touchedRecipient else { return }
        schedulePush()
    }

    private func schedulePush() {
        guard syncEnabled else { return }
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { @MainActor [weak self] in
            // 500 ms debounce — bulk inserts from Import Identity
            // commonly arrive as N rapid saves; we only push the final
            // state. Cancel-and-restart on each save means the "last
            // change wins" naturally.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            await self.push()
        }
    }

    private func push() async {
        guard syncEnabled, let identity = currentIdentity else { return }
        do {
            let snapshots = try snapshotLocal()
            let encoded = try RecipientsSync.encode(
                recipients: snapshots,
                lastWriteAt: .now,
                with: identity
            )
            try KeychainStore.set(
                encoded,
                account: RecipientsSync.account,
                mode: .syncing
            )
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn't push recipient sync: \(error.localizedDescription)"
        }
    }

    // MARK: - Pull / merge

    private func pullIfPossible(reason: String) async {
        guard syncEnabled, let identity = currentIdentity else { return }
        do {
            guard let stored = try KeychainStore.get(
                account: RecipientsSync.account,
                mode: .syncing
            ) else {
                // Nothing on the remote yet — first device to sync.
                return
            }
            let decoded = try RecipientsSync.decode(stored, with: identity)
            try mergeLocally(decoded)
            lastErrorMessage = nil
        } catch RecipientsSync.Error.identityMismatchOrTampered {
            // The remote blob can't be decrypted by the current identity.
            // Most common cause: the user reset / replaced their identity
            // and the old blob is stale. The push that follows
            // identity-bind will overwrite it with a fresh one keyed
            // under the new identity.
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn't pull recipient sync (\(reason)): \(error.localizedDescription)"
        }
    }

    /// Apply a decoded remote blob to the local SwiftData store.
    ///
    ///   - Recipients in remote but not in local → insert.
    ///   - Recipients in local but not in remote, whose `createdAt` is
    ///     older than `blob.lastWriteAt` → delete (they were known to
    ///     remote and removed there).
    ///   - Recipients in both → take whichever side was edited more
    ///     recently. Renames and reorders stamp `updatedAt`, so if the
    ///     remote copy's `updatedAt` is newer than ours we adopt its
    ///     display name, notes, and manual position; otherwise we keep
    ///     local (and the subsequent push re-publishes our newer copy).
    private func mergeLocally(_ blob: RecipientsSync.DecodedBlob) throws {
        let descriptor = FetchDescriptor<Recipient>()
        let local = try mergeContext.fetch(descriptor)
        let remoteIds = Set(blob.recipients.map(\.id))
        let localById = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Inserts + updates
        for snapshot in blob.recipients {
            if let existing = localById[snapshot.id] {
                // Same row on both sides: latest edit wins for the mutable
                // fields (label, notes, position). Keys/fingerprint are
                // immutable so we never touch them.
                if snapshot.updatedAt > existing.effectiveUpdatedAt {
                    existing.displayName = snapshot.displayName
                    existing.notes = snapshot.notes
                    existing.orderIndex = snapshot.orderIndex
                    existing.updatedAt = snapshot.updatedAt
                }
            } else {
                guard let bundle = bundleFromSnapshot(snapshot) else { continue }
                let row = Recipient(
                    displayName: snapshot.displayName,
                    publicBundle: bundle,
                    notes: snapshot.notes,
                    createdAt: snapshot.createdAt,
                    orderIndex: snapshot.orderIndex,
                    updatedAt: snapshot.updatedAt
                )
                // Preserve the original UUID so a later round-trip from
                // another device still recognises the same row.
                row.id = snapshot.id
                mergeContext.insert(row)
            }
        }

        // Deletions
        for recipient in local
        where !remoteIds.contains(recipient.id)
                && recipient.createdAt < blob.lastWriteAt {
            mergeContext.delete(recipient)
        }

        try mergeContext.save()
    }

    // MARK: - Helpers

    private func snapshotLocal() throws -> [RecipientsSync.RecipientSnapshot] {
        let descriptor = FetchDescriptor<Recipient>()
        let rows = try mergeContext.fetch(descriptor)
        return rows.map { recipient in
            RecipientsSync.RecipientSnapshot(
                id: recipient.id,
                displayName: recipient.displayName,
                encryptionPublicKey: recipient.encryptionPublicKeyData,
                signingPublicKey: recipient.signingPublicKeyData,
                notes: recipient.notes,
                createdAt: recipient.createdAt,
                orderIndex: recipient.orderIndex,
                updatedAt: recipient.effectiveUpdatedAt
            )
        }
    }

    private func bundleFromSnapshot(
        _ snapshot: RecipientsSync.RecipientSnapshot
    ) -> Identity.PublicBundle? {
        guard let encryption = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: snapshot.encryptionPublicKey
        ),
              let signing = try? Curve25519.Signing.PublicKey(
                rawRepresentation: snapshot.signingPublicKey
              )
        else { return nil }
        return Identity.PublicBundle(
            encryptionPublicKey: encryption,
            signingPublicKey: signing
        )
    }
}

