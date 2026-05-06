# Exchange

End-to-end encrypted messaging for any messenger. iOS 26+. Native Swift / SwiftUI / CryptoKit. No servers, no accounts, no telemetry.

The user types a plaintext message inside Exchange, picks a recipient whose public key has been exchanged out of band (in person via QR, or pasted through any trusted channel), and gets back a single base64 line — the **EXC2 envelope**. They send that envelope through whatever transport they already use: iMessage, Mail, Telegram, WhatsApp, Slack, anything that carries text. The recipient pastes it back into Exchange and reads the original plaintext. Nobody else can.

For iMessage specifically, the bundled iMessage extension performs the encrypt-and-send loop entirely inside Messages — pick a recipient, type, tap Encrypt, hit Send, and the receiving device tap-to-decrypts inline.

## Status

Pre-submission. Built and being smoke-tested before TestFlight. The cryptographic core is unit-tested; the UI flows have been built but not yet verified on real devices.

The repository tree corresponds to the Xcode 26-managed project layout. `Exchange/` is the main app target, `MessagesExtension/` is the iMessage extension target, `ExchangeTests/` is the test target. `docs/` carries content drafts (privacy policy, App Store listing, screenshot capture plan) used during the App Store submission.

## Cryptographic protocol

Each outgoing message becomes a self-contained envelope, framed as `EXC2:<base64>`.

The binary blob inside the base64 is laid out as:

```
offset  size  field
0       1     version byte (0x02)
1       8     recipient encryption-key fingerprint (SHA-256 prefix)
9       32    sender Ed25519 signing public key
41      32    ephemeral X25519 public key
73      12    wrap nonce
85      32    wrapped K (ciphertext)
117     16    wrapped K (Poly1305 tag)
133     12    message nonce
145     N     message ciphertext
145+N   16    message Poly1305 tag
161+N   64    Ed25519 signature over bytes [0 .. 161+N-1]
```

Sealing a message:

1. Generate a fresh ephemeral Curve25519 keypair.
2. ECDH between the ephemeral private key and the recipient's static encryption public key produces a shared secret.
3. HKDF-SHA256 over the shared secret (with the ephemeral public key as salt and a domain-separation tag as info) derives a 32-byte wrapping key.
4. Generate a fresh random 32-byte message key K.
5. Wrap K with ChaCha20-Poly1305 under the wrapping key.
6. Encrypt the plaintext with ChaCha20-Poly1305 under K.
7. Concatenate everything (version, fingerprint, sender signing key, ephemeral key, wrap nonce + wrapped K + tag, message nonce + ciphertext + tag).
8. Sign the concatenation with the sender's Ed25519 private key. Append the signature.
9. Base64-armor and prefix with `EXC2:`.

Opening proceeds in reverse, in this strict order, so the recipient's static private key never touches a forged or tampered envelope:

1. Cheap "for me" reject: the 8-byte recipient fingerprint must match the opener's identity.
2. Ed25519 signature verification against the sender public key embedded in the envelope.
3. ECDH + HKDF to derive the wrapping key from the ephemeral public key.
4. ChaCha20-Poly1305 unwrap of K, then decryption of the body.

Implementation lives in `Exchange/Crypto/CryptoEnvelope.swift`. The complete property-based round-trip / forgery / tamper test suite is in `ExchangeTests/CryptoEnvelopeTests.swift`.

Sender authentication note: the signature proves the envelope was produced by *some* signing key. Whether that key actually belongs to a trusted contact is a UI-layer decision — Exchange's `DecryptView` and the iMessage extension look the recovered signing public key up against the saved `Recipient` rows and either show "Signature verified — from Alice" (matched) or a fingerprint warning (unknown sender). The user decides whether to add an unknown sender as a contact.

## Architecture

```
Exchange/                 main app target (iOS 26+)
├── ExchangeApp.swift     @main; constructs the SwiftData container
├── ContentView.swift     home screen, splash, toolbar, sheets
├── AppConstants.swift    App Group identifier, keychain group, URLs
├── Crypto/
│   ├── Identity.swift    Curve25519 ECDH + Ed25519 signing keypair
│   └── CryptoEnvelope.swift   seal / open / EXC2 binary layout
├── Models/
│   └── Recipient.swift   @Model: display name, public bundle, fingerprint
├── Storage/
│   └── KeychainStore.swift   Keychain Services wrapper, this-device-only
├── Extensions/
│   └── Data+Hex.swift    hex / grouped-hex helpers for fingerprints
├── Views/
│   ├── ComposeView.swift     pick recipient, type, encrypt, share
│   ├── DecryptView.swift     paste, verify signature, show plaintext
│   ├── AddRecipientView.swift   paste or QR-scan a public-key bundle
│   ├── MyIdentityQRView.swift   render local public bundle as QR
│   ├── QRCodeView.swift / QRScannerView.swift   CIFilter + AVCaptureSession
│   └── SettingsView.swift    version, links, Reset identity
├── Assets.xcassets/      AppIcon (light/dark/tinted), LaunchIcon, LaunchBackground
├── Info.plist            UILaunchScreen, NSCameraUsageDescription
├── Exchange.entitlements App Group, keychain-access-groups
└── PrivacyInfo.xcprivacy declares no tracking, no data collection

MessagesExtension/        iMessage extension target (iOS 26+)
├── MessagesViewController.swift   MSMessagesAppViewController + URL codec
├── MessagesView.swift    @Observable model + compose / decrypt SwiftUI shell
├── Assets.xcassets/iMessage App Icon.stickersiconset/   9 4:3 sizes
├── Info.plist            com.apple.message-payload-provider
├── MessagesExtension.entitlements   matching App Group + keychain group
└── PrivacyInfo.xcprivacy

ExchangeTests/
└── CryptoEnvelopeTests.swift   round trips, tamper, forgery, malformed input

docs/
├── privacy-policy.md
├── app-store-listing.md
└── screenshot-checklist.md
```

The `Exchange/` synchronized root group is also a member of the `MessagesExtension` target via an exception set that excludes the SwiftUI views, app entry point, asset catalog, Info.plist, and entitlements. The crypto / model / storage / extensions sources compile into both targets so the iMessage extension can use the same `Identity`, `Recipient`, `CryptoEnvelope`, `KeychainStore` types without duplicating them.

## Building

Open `Exchange.xcodeproj` in **Xcode 26.0.1 or later**. The project requires:

- iOS 26.0 deployment target
- Swift 5 language mode with `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (already set)
- Apple Developer team `V4WM2SJ8Q9` (replace with your own in **Signing & Capabilities** if cloning)

### Run on simulator

Pick the **Exchange** scheme and an iPhone running iOS 26 (e.g. iPhone 16 Pro Max). Build and run (`⌘R`). The app generates a fresh Curve25519 + Ed25519 identity in the simulator's Keychain on first launch.

The QR scanner won't work in the simulator (no camera). Use the paste path instead — copy a public-key bundle from another simulator instance or from the My identity row of a different Apple ID.

### Run on device

Plug in an iPhone running iOS 26, set **Signing & Capabilities** to your team and a valid bundle identifier prefix, and run.

The first time the iMessage extension is installed, it does not appear in iMessage's app list automatically. In Messages, open any conversation, tap the `+` button, scroll the apps list to the bottom, tap **More**, and toggle Exchange on. Once visible, it stays visible.

### Test

The crypto core has property-based tests:

```bash
xcodebuild test \
    -project Exchange.xcodeproj \
    -scheme Exchange \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max'
```

Or run from inside Xcode (`⌘U`). Approximately 16 tests cover round-trip on short / long / empty payloads, signature failure on byte-flips inside the signed region, fingerprint mismatch, unsupported version handling, malformed-input rejection, and the re-sign-with-attacker-key forgery scenario.

## Privacy

No data leaves the device unless the user explicitly Shares an encrypted envelope to another app. The app makes zero outbound network requests on its own. Identity private keys live in the iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which the OS itself blocks from iCloud Keychain sync and device-to-device migration. The recipient list lives in a SwiftData container inside an App Group local to the device. CloudKit is explicitly disabled on the `ModelConfiguration`.

`PrivacyInfo.xcprivacy` in both the main app and the iMessage extension declares `NSPrivacyTracking = false`, no tracking domains, no collected data types, and no `NSPrivacyAccessedAPITypes`.

The full statement is in [`docs/privacy-policy.md`](docs/privacy-policy.md).

## License

See [`LICENSE`](LICENSE).

## Author

Ivan Alekseev — `nettrash@nettrash.me` — [nettrash.me](https://nettrash.me)
