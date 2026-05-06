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

```
Encrypt messages on your device, share them through any messenger you already use, and decrypt back. No servers, no accounts, no tracking. Your keys stay yours.
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
Exchange has no servers. No backend, no accounts, no telemetry, no analytics, no tracking. Your private keys are generated the first time you open the app and are stored in your iOS Keychain with the strictest "this device only" accessibility flag — they cannot be synced via iCloud Keychain or transferred to another device. The cryptographic operations all run locally using Apple's CryptoKit framework.

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

It isn't a key recovery service. If you lose your device, your identity is gone — that's the design. A new device gets a new identity, and you re-publish your public key to your contacts.

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
https://exchange.nettrash.me/privacy
```

(Update this once the policy is hosted; must serve the markdown rendered as a public webpage.)

## Support URL

```
https://exchange.nettrash.me/support
```

(Can point to a single static page or a GitHub issues URL.)

## Marketing URL (optional)

```
https://exchange.nettrash.me
```

## Encryption / Export Compliance

- Uses cryptography? **Yes**
- Uses cryptography exempt under Category 5, Part 2? Open question that depends on your interpretation.
  - **Conservative path:** Set `ITSAppUsesNonExemptEncryption = true`, file an annual self-classification with US BIS under EAR §740.17(b)(1), receive an Encryption Registration Number (ERN), and reference it in App Store Connect. This is what Signal, Wire, and most secure-messaging apps do.
  - **Simpler path:** Set `ITSAppUsesNonExemptEncryption = false` if you believe the use qualifies as exempt under Note 4 to Category 5 Part 2 ("information security is not the primary function"). Apple accepts this for TestFlight without further paperwork. Risk: a strict reading would push back since Exchange's primary function _is_ encryption.

Recommended: file the ERN. It takes about an hour, is renewed annually, and gives you legal cover.

## Screenshots

See `screenshot-checklist.md` in this folder.
