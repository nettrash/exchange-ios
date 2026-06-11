//
//  MessagesViewController.swift
//  MessagesExtension
//
//  Principal class for Exchange's iMessage app. Subclasses
//  MSMessagesAppViewController and hosts a SwiftUI shell that handles
//  both flows:
//
//    - Compose: user picked Exchange from the iMessage app drawer.
//      We read recipients from the shared SwiftData store, render a
//      picker + plaintext field; on Encrypt we seal an EXC2 envelope
//      (signed by the local identity), wrap it in an MSMessage with
//      a template layout, and insert it into the conversation.
//
//    - Decrypt: user tapped one of our existing bubbles. We extract
//      the envelope from the MSMessage's URL, decrypt against the
//      local identity, and show the plaintext + verified sender info.
//
//  The two flows share a single @Observable model so the UI just
//  switches on `model.state`. URL ↔ envelope helpers live at the
//  bottom of this file so the encoding stays in lockstep with the
//  decoding.
//

import CryptoKit
import Messages
import SwiftData
import SwiftUI
import UIKit

class MessagesViewController: MSMessagesAppViewController {
    private let model = MessagesAppModel()
    private var hostingController: UIHostingController<MessagesView>?
    private var modelContainer: ModelContainer?

    /// Envelope awaiting decryption behind the app lock (set when the user
    /// enabled the lock with "cover incoming"). Opened in the main app via
    /// `openInApp`, where the unlock + decryption actually happen.
    private var pendingLockedEnvelope: String?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        modelContainer = makeSharedModelContainer()
        installHostingController()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        Task { await refreshState(for: conversation) }
    }

    override func didStartSending(_ message: MSMessage, conversation: MSConversation) {
        super.didStartSending(message, conversation: conversation)
        // The user tapped the blue Send arrow. Drop back to compact and
        // hide ourselves so iMessage takes over the compose area cleanly.
        dismiss()
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        super.didReceive(message, conversation: conversation)
        // A message we sent (or one of ours that was forwarded back) just
        // arrived. If it's the currently selected one, refresh the
        // decrypt UI so the user sees its plaintext.
        if conversation.selectedMessage == message {
            Task { await refreshState(for: conversation) }
        }
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        if let conversation = activeConversation {
            Task { await refreshState(for: conversation) }
        }
    }

    // MARK: - SwiftUI hosting

    private func installHostingController() {
        let view = MessagesView(
            model: model,
            onSend: { [weak self] envelope, recipientName in
                self?.encryptedEnvelopeReady(envelope: envelope, recipientName: recipientName)
            },
            onRequestExpand: { [weak self] in
                self?.requestPresentationStyle(.expanded)
            },
            onDone: { [weak self] in
                self?.dismiss()
            },
            onOpenInApp: { [weak self] in
                self?.openInApp()
            },
            modelContainer: modelContainer
        )
        let hosting = UIHostingController(rootView: view)
        hostingController = hosting
        addChild(hosting)
        hosting.view.frame = self.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    // MARK: - State refresh

    @MainActor
    private func refreshState(for conversation: MSConversation) async {
        // Load the local identity (must already exist — the iMessage
        // extension does not silently provision a key).
        let identity: Identity?
        do {
            identity = try IdentityStore.load()
        } catch {
            model.state = .error("Couldn't read your Exchange identity: \(error.localizedDescription)")
            return
        }
        guard let identity else {
            model.state = .error("Open the Exchange app once first to set up your identity.")
            return
        }
        model.identity = identity

        // If a message is currently selected, decrypt path. Otherwise compose.
        if let selected = conversation.selectedMessage,
           let url = selected.url,
           let envelope = EnvelopeURL.extract(from: url) {
            // The lock card and the decrypted message are centred views that
            // need room the compact strip doesn't have — that's why tapping a
            // bubble sometimes showed an empty/clipped sheet. Expand first so
            // the content is always visible. (Requesting expanded re-enters
            // refreshState via willTransition; the guard stops a loop.)
            if presentationStyle == .compact {
                requestPresentationStyle(.expanded)
            }
            // Honour the app lock when enabled and scoped to cover incoming
            // messages. Fail open if the device can't authenticate (no
            // biometrics/passcode) so a message is never permanently
            // unreadable here.
            if AppLockSettings.isEnabled,
               AppLockSettings.coversIncoming,
               BiometricAuth.canAuthenticate() {
                pendingLockedEnvelope = envelope
                model.state = .locked
            } else {
                tryDecrypt(envelope: envelope, identity: identity)
            }
        } else {
            await loadComposeRecipients()
            model.state = .compose
        }
    }

    /// Open the locked message in the main Exchange app via its Universal
    /// Link, where the app-lock prompt (Face ID / passcode) and decryption
    /// run. Biometric prompts aren't reliable inside the iMessage compose
    /// strip, so we hand off rather than authenticating here.
    @MainActor
    private func openInApp() {
        guard let envelope = pendingLockedEnvelope,
              let url = EnvelopeURL.url(for: envelope) else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    @MainActor
    private func loadComposeRecipients() async {
        guard let modelContainer else {
            model.recipients = []
            return
        }
        let context = ModelContext(modelContainer)
        // Match the main app's home-screen order: manual drag-order first,
        // then newest-first as the tie-break (rather than alphabetical).
        let descriptor = FetchDescriptor<Recipient>(sortBy: [
            SortDescriptor(\.orderIndex, order: .forward),
            SortDescriptor(\.createdAt, order: .reverse),
        ])
        let recipients = (try? context.fetch(descriptor)) ?? []
        // Snapshot to plain values so the SwiftUI view doesn't depend on
        // the @Model object's lifecycle.
        model.recipients = recipients.compactMap(RecipientSnapshot.init(from:))
    }

    @MainActor
    private func tryDecrypt(envelope: String, identity: Identity) {
        do {
            let opened = try CryptoEnvelope.open(envelope: envelope, with: identity)
            let plaintextString = String(data: opened.plaintext, encoding: .utf8)

            let senderDisplay = senderDisplayName(for: opened.senderSigningPublicKey)
            if let plaintextString {
                model.state = .decryptedPlaintext(text: plaintextString, sender: senderDisplay)
            } else {
                model.state = .decryptedBinary(byteCount: opened.plaintext.count, sender: senderDisplay)
            }
        } catch let error as CryptoEnvelope.Error {
            model.state = .error(describe(error))
        } catch {
            model.state = .error("Couldn't decrypt: \(error.localizedDescription)")
        }
    }

    /// Match an envelope's sender signing key against the saved recipient
    /// list. Returns "Alice" if matched, otherwise a short fingerprint.
    @MainActor
    private func senderDisplayName(for senderSigningPublicKey: Data) -> SenderDisplay {
        guard let modelContainer else {
            return .fingerprint(Data(SHA256.hash(data: senderSigningPublicKey).prefix(8)).groupedHex)
        }
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Recipient>()
        if let recipients = try? context.fetch(descriptor),
           let match = recipients.first(where: { $0.signingPublicKeyData == senderSigningPublicKey }) {
            return .knownRecipient(match.displayName)
        }
        return .fingerprint(Data(SHA256.hash(data: senderSigningPublicKey).prefix(8)).groupedHex)
    }

    // MARK: - Outgoing message

    /// Called from the SwiftUI view when the user has hit Encrypt and we
    /// have a sealed envelope ready. Wraps it in an MSMessage and inserts
    /// it into the active conversation so iMessage can send it.
    private func encryptedEnvelopeReady(envelope: String, recipientName: String) {
        guard let conversation = activeConversation else { return }

        let message = MSMessage()
        let layout = MSMessageTemplateLayout()
        layout.caption = "🔒 Encrypted message"
        layout.subcaption = "to \(recipientName)"
        message.layout = layout
        message.url = EnvelopeURL.url(for: envelope)
        message.summaryText = "🔒 Encrypted Exchange message — install Exchange to read"

        // Capture self into a separate weak reference inside the Task
        // rather than reaching back into the (non-Sendable) outer closure's
        // captured `self?` — Swift 6 strict concurrency rejects the latter.
        conversation.insert(message) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.model.state = .error("Couldn't insert message into the conversation: \(error.localizedDescription)")
                } else {
                    // Collapse the extension so the user sees the encrypted
                    // bubble sitting in iMessage's compose field with the
                    // blue Send arrow ready to tap.
                    self.requestPresentationStyle(.compact)
                    self.dismiss()
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeSharedModelContainer() -> ModelContainer? {
        let schema = Schema([Recipient.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(AppConstants.appGroupIdentifier),
            cloudKitDatabase: .none
        )
        return try? ModelContainer(for: schema, configurations: [config])
    }

    private func describe(_ error: CryptoEnvelope.Error) -> String {
        switch error {
        case .malformedEnvelope:
            return "This Exchange envelope is malformed."
        case .unsupportedVersion(let version):
            return "Unsupported envelope version: 0x\(String(version, radix: 16)). You may need a newer build of Exchange."
        case .fingerprintMismatch:
            return "This message wasn't sent to your identity."
        case .signatureVerificationFailed:
            return "The sender's signature didn't verify. The envelope was tampered with after it was signed."
        case .decryptionFailed:
            return "The message is corrupt or has been tampered with."
        }
    }
}

// URL ↔ envelope encoding lives in shared Crypto/EnvelopeURL.swift so
// both this extension and the main app's DecryptView can use it.
