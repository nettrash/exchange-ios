# App Store Listing — Exchange

Copy-paste targets for App Store Connect. Adjust before submission.

---

## App Name (max 30 chars)

```
Exchange
```

## Subtitle (max 30 chars)

Pick one — three options at different framings:

```
Your messages, your keys
```

```
Encrypt anything, send anywhere
```

```
End-to-end. On your device.
```

## Promotional Text (max 170 chars, editable post-release)

Evergreen (default):

```
Encrypt messages on your device, share them through any messenger you already use, and decrypt back. No servers, no accounts, no tracking. Your keys stay yours.
```

For the 1.2 submission (leads with the new recipient management):

```
New in 1.2: rename and reorder your saved recipients. Encrypt on your device, send through any messenger, decrypt back. No servers, no accounts, no tracking.
```

## Keywords (max 100 chars, comma-separated, no spaces)

```
encryption,privacy,secure,message,e2ee,key,private,signal,curve25519,crypto,vault,lock
```

## Description (max ~3000 chars)

```
Exchange is a cryptographic messenger that puts you in charge of your own keys.

Type your message in Exchange, encrypt it to a recipient whose public key you've saved, and you get an EXC2 envelope — a single line of base64 text. Send that envelope through any app you already use: iMessage, Mail, Telegram, WhatsApp, anything that can carry plain text. The recipient pastes it back into Exchange and reads the original message. Nobody else can.

Or use the built-in iMessage extension and the encrypt-and-send flow happens inside iMessage itself. Tap Exchange in the iMessage app drawer, pick a contact, type, hit Encrypt, hit Send. The recipient taps the encrypted bubble in their thread, your extension decrypts it inline, and the plaintext appears with your name above it. No copy-paste, no app switching, no leaving the conversation.

EVERYTHING ON YOUR DEVICE
Exchange has no servers. No backend, no accounts, no telemetry, no analytics, no tracking. Your private keys are generated the first time you open the app and are stored in your iOS Keychain. By default the identity is synced via Apple's end-to-end-encrypted iCloud Keychain so the same keys flow between your iPhone and Mac on the same Apple ID — toggle that off in Settings to pin them to one device. You can also export the identity as a passphrase-encrypted blob, or transfer it in person via QR. The cryptographic operations all run locally using Apple's CryptoKit framework.

PROVEN ALGORITHMS
Exchange uses standard, publicly-vetted cryptography:
• Curve25519 (X25519) key agreement
• Ed25519 signatures for sender authentication
• ChaCha20-Poly1305 authenticated encryption
• HKDF-SHA256 for key derivation

Every message is signed by your identity and verified by the recipient before the plaintext is shown. Tampered envelopes are rejected, not silently corrupted.

KEY EXCHANGE THAT MAKES SENSE
Two people meet in person — at the office, at a cafe, at a conference. One taps "Show QR code" in Exchange, the other taps "Scan QR" from Add Recipient. A few seconds and they've exchanged the public-key bundle, including a fingerprint they can verify out loud. From then on, no matter what messenger they use to talk, only they can read what they send.

WHAT EXCHANGE IS NOT
Exchange isn't a chat app. It doesn't have group chats, voice calls, or read receipts. It's a tool you use with whatever transport you prefer.

It isn't a key recovery service. If you lose all your devices and don't have iCloud Keychain sync turned on (or you turned it off), your identity is gone. With iCloud Keychain sync enabled (the default in 1.1), your other devices on the same Apple ID still hold the same identity. There is no developer-side recovery, no master key, no back door.

It isn't a server-trust system. There's no central directory of users. You decide who your contacts are, in person or through whatever channel you trust.

REQUIREMENTS
• iOS 26 or later
• Camera (for QR-code scanning, optional)
• An iMessage-installed iPhone if you want to use the iMessage extension

FREE AND OPEN
Exchange is independent software that respects your time and your data. No ads, no subscriptions, no upsells.
```

## What's New in This Version (release notes)

For the first submission:

```
Hello, world.

This is the first release of Exchange. Generate an identity, save recipients via QR scan or pasted public key, and encrypt or decrypt messages anywhere.

Includes the iMessage extension for seamless in-conversation encryption.
```

For v1.1:

```
Mac Catalyst, multi-device identity and recipients, smoother taps.

• Mac Catalyst: Exchange now runs as a native Mac app. The recipient list and the decrypt flow are shared with the iPhone version.
• Universal Links: tap a 🔒 Encrypted message bubble in iMessage on Mac or iPhone and Exchange opens directly to the decrypted plaintext — no more copy-paste round trip.
• Encrypted-message links sent from the Compose flow now appear as rich preview bubbles (icon + "🔒 Encrypted message" caption) in iMessage and other messengers, instead of plain base64.
• Identity sync: by default your identity is now carried across your iPhone and Mac via end-to-end-encrypted iCloud Keychain. Toggle off in Settings → Identity sync if you prefer the v1.0 device-only behaviour.
• Recipients sync: the saved recipient list also syncs between your devices, encrypted on-device with a key derived from your identity. Apple sees only opaque ciphertext.
• Backup & transfer: Settings → Backup & transfer adds passphrase-encrypted Export / Import (paste-friendly) and one-shot Send / Receive via QR (in-person between two of your own devices).
• Smoother launch from a tapped link — the splash transitions straight to the decrypted message, with no home-screen flash in between.
• Auto-detects encrypted envelopes already on your clipboard when you open Decrypt.
```

For v1.2:

```
Manage your recipient list.

• Rename: tap a recipient (or right-click on Mac) to edit its display name and notes. The key identity behind it never changes.
• Reorder: tap Edit and drag recipients into the order you want.
• Your names and order sync across iPhone and Mac and are included in encrypted backups.
```

For future updates, keep these short and concrete: "Fixed [bug]. Added [small thing]. Improved [thing]."

## App Information

- **Bundle ID:** `me.nettrash.Exchange`
- **iMessage Extension Bundle ID:** `me.nettrash.Exchange.MessagesExtension`
- **Primary Category:** Utilities
- **Secondary Category:** (optional — Productivity is a reasonable second pick)
- **Age Rating:** 4+ (no objectionable content)
- **Languages:** English (initial); add others later via String Catalogs

## Privacy Policy URL

```
https://nettrash.me/appstore/exchange/privacy.html
```

(Update this once the policy is hosted; must serve the markdown rendered as a public webpage.)

## Support URL

```
https://nettrash.me/appstore/exchange/support.html
```

(Can point to a single static page or a GitHub issues URL.)

## Marketing URL (optional)

```
https://nettrash.me
```

## Encryption / Export Compliance

- Uses cryptography? **Yes**
- Uses cryptography exempt under Category 5, Part 2? Open question that depends on your interpretation.
  - **Conservative path:** Set `ITSAppUsesNonExemptEncryption = true`, file an annual self-classification with US BIS under EAR §740.17(b)(1), receive an Encryption Registration Number (ERN), and reference it in App Store Connect. This is what Signal, Wire, and most secure-messaging apps do.
  - **Simpler path:** Set `ITSAppUsesNonExemptEncryption = false` if you believe the use qualifies as exempt under Note 4 to Category 5 Part 2 ("information security is not the primary function"). Apple accepts this for TestFlight without further paperwork. Risk: a strict reading would push back since Exchange's primary function _is_ encryption.

Recommended: file the ERN. It takes about an hour, is renewed annually, and gives you legal cover.

## Screenshots

See `screenshot-checklist.md` in this folder.
