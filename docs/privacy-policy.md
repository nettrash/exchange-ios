# Exchange — Privacy Policy

_Last updated: [DATE]_

Exchange is an iOS app that lets you encrypt and decrypt messages locally on your device using your own cryptographic keys. This page describes what data Exchange handles, where it lives, and what we do — and don't do — with it.

The short version: **everything stays on your device, and nothing is sent to us or anyone else.** There are no servers, no analytics, no telemetry, no tracking, no advertising, no accounts. We have no idea who uses Exchange or how, and we never will.

## What Exchange processes

When you use Exchange, the app processes:

- **Plaintext messages you type into the Compose screen.** These are encrypted on-device and the resulting envelope is what you share. The plaintext itself never leaves your device.
- **Encrypted envelopes you paste into the Decrypt screen.** These are decrypted on-device and the resulting plaintext is shown only on your screen.
- **Public keys of recipients you save.** These are stored locally so you can encrypt to them later.
- **Display names and notes you assign to recipients.** Stored locally to help you remember who's who.

## What Exchange stores on your device

- **Your private cryptographic keys** (one Curve25519 key for encryption agreement, one Ed25519 key for signing). Stored in the iOS Keychain with the strictest "this device only" accessibility flag, so they cannot be migrated, synced via iCloud Keychain, or transferred to another device. They are generated on first launch and never leave your device.
- **The list of recipients** (each entry: display name, two public keys, a fingerprint, optional notes, creation date). Stored in the app's private SwiftData container inside an App Group, accessible only to Exchange and its iMessage extension on the same device. Survives a device-to-device backup-and-restore via standard iOS backup mechanisms; never pushed to iCloud directly.

## What Exchange does NOT do

- **No data collection.** Exchange does not collect any personal information, usage data, device identifiers, IP addresses, or behavioral signals.
- **No analytics or telemetry.** No third-party SDKs, no event tracking, no crash reporting beyond what Apple provides automatically to developers (anonymous crash logs containing no user content).
- **No tracking.** Exchange does not track you across apps or websites. It does not contact tracking domains. It contains no advertising.
- **No servers.** Exchange has no backend. It makes no network calls to any service operated by us. The only network activity in the app is what happens when you choose to share an encrypted envelope through another app (iMessage, Mail, Telegram, etc.) — that other app handles its own data separately.
- **No accounts.** Exchange has no sign-up, no login, no user accounts. Your identity is purely cryptographic and lives only on your device.

## Camera access

Exchange uses your device's camera only when you choose to scan a recipient's QR code from the Add Recipient screen. The camera feed is processed entirely on-device by the iOS QR-code recognition framework. Frames are not stored, not transmitted, and not analyzed for any purpose other than detecting a QR code's text payload.

iOS will ask for camera permission the first time you tap "Scan QR." You can revoke this permission at any time in Settings → Exchange → Camera. Without it, you can still add recipients by pasting their public key as text.

## Encryption and security

Exchange uses standard, well-known cryptographic primitives provided by Apple's CryptoKit framework:

- **Curve25519 (X25519) key agreement** for establishing per-message symmetric keys.
- **Ed25519 signatures** for sender authentication.
- **ChaCha20-Poly1305 authenticated encryption** for the message body and key wrap.
- **HKDF-SHA256** for deriving wrapping keys from ECDH shared secrets.

All cryptographic operations run on your device. We do not have access to any keys, message contents, recipient information, or anything else handled by the app.

## Children

Exchange is suitable for general audiences and does not knowingly process information about children. Because we collect no information at all, it is impossible for us to obtain or process information about anyone — including minors — even unintentionally.

## Changes to this policy

If we make material changes to this policy in the future, the updated version will be published at this URL and the "Last updated" date at the top will be revised. Substantive changes will also be noted in the app's release notes.

## Contact

Questions or concerns? Email **[YOUR-EMAIL]** or open an issue at **[YOUR-REPO]**.

---

_Exchange is independent software not affiliated with or endorsed by Apple Inc. iMessage, iOS, iCloud, and Keychain are trademarks of Apple Inc._
