//
//  ShareViewController.swift
//  ShareExtension
//
//  Principal class for the iOS share extension.
//
//  Flow:
//    1. iOS hands us NSExtensionItem(s) when the user picks Exchange from
//       the share sheet of any app (Mail, iMessage, Telegram, WhatsApp, …).
//    2. We pull the first text-typed attachment, scan for an "EXC2:"
//       envelope, decrypt it against the local identity (loaded from the
//       shared Keychain access group), and render the plaintext along
//       with the verified sender's fingerprint.
//    3. The user taps Done; we complete the extension request.
//
//  Identity is loaded with `IdentityStore.load()` (not `loadOrCreate`):
//  the share extension never silently provisions a key. If the user opens
//  the share extension before launching the main app once, we surface a
//  helpful error instead of generating a new identity in the background.
//

import CryptoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    private lazy var model = ShareDecryptModel()
    private var hostingController: UIHostingController<ShareDecryptView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        installHostingController()
        Task { await processInput() }
    }

    // MARK: - SwiftUI hosting

    private func installHostingController() {
        let view = ShareDecryptView(model: model) { [weak self] in
            self?.complete()
        }
        let hosting = UIHostingController(rootView: view)
        hostingController = hosting
        addChild(hosting)
        hosting.view.frame = self.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Input handling

    private func processInput() async {
        guard let extensionItems = self.extensionContext?.inputItems as? [NSExtensionItem],
              !extensionItems.isEmpty else {
            model.state = .error(message: "Nothing was shared with Exchange.")
            return
        }

        guard let sharedText = await firstSharedText(in: extensionItems) else {
            model.state = .error(message: "The shared content didn't contain any text.")
            return
        }

        await tryDecrypt(sharedText)
    }

    /// Walk the extension items / attachments and return the first
    /// text-typed payload we can resolve to a Swift String.
    private func firstSharedText(in items: [NSExtensionItem]) async -> String? {
        let candidateTypes: [UTType] = [.plainText, .text, .utf8PlainText]
        for item in items {
            for attachment in item.attachments ?? [] {
                for type in candidateTypes where attachment.hasItemConformingToTypeIdentifier(type.identifier) {
                    if let text = await loadString(from: attachment, type: type) {
                        return text
                    }
                }
            }
        }
        return nil
    }

    private func loadString(from provider: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                if let str = value as? String {
                    continuation.resume(returning: str)
                } else if let data = value as? Data, let str = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: str)
                } else if let url = value as? URL {
                    continuation.resume(returning: url.absoluteString)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Decryption

    private func tryDecrypt(_ rawText: String) async {
        guard let envelope = Self.extractEnvelope(from: rawText) else {
            model.state = .error(message: "This doesn't look like an Exchange envelope. Make sure the shared text contains an EXC2: blob.")
            return
        }

        let identity: Identity?
        do {
            identity = try IdentityStore.load()
        } catch {
            model.state = .error(message: "Couldn't read your Exchange identity: \(error.localizedDescription)")
            return
        }

        guard let identity else {
            model.state = .error(message: "Open the Exchange app once first to set up your identity.")
            return
        }

        do {
            let opened = try CryptoEnvelope.open(envelope: envelope, with: identity)
            let senderFingerprint = Data(SHA256.hash(data: opened.senderSigningPublicKey).prefix(8)).groupedHex

            if let plaintext = String(data: opened.plaintext, encoding: .utf8) {
                model.state = .plaintext(text: plaintext, senderFingerprintHex: senderFingerprint)
            } else {
                model.state = .binary(byteCount: opened.plaintext.count, senderFingerprintHex: senderFingerprint)
            }
        } catch let error as CryptoEnvelope.Error {
            model.state = .error(message: Self.describe(error))
        } catch {
            model.state = .error(message: "Couldn't decrypt: \(error.localizedDescription)")
        }
    }

    /// Locate an EXC2 envelope embedded in arbitrary shared text.
    /// We accept "Hey check this: EXC2:abc... cool huh" and strip away
    /// everything that isn't part of the base64 body.
    static func extractEnvelope(from text: String) -> String? {
        guard let prefixRange = text.range(of: "EXC2:") else { return nil }
        let validBase64: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        var endIndex = prefixRange.upperBound
        while endIndex < text.endIndex, validBase64.contains(text[endIndex]) {
            endIndex = text.index(after: endIndex)
        }
        guard endIndex > prefixRange.upperBound else { return nil }
        return String(text[prefixRange.lowerBound..<endIndex])
    }

    static func describe(_ error: CryptoEnvelope.Error) -> String {
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
