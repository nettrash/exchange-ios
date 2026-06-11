# Changelog

All notable changes to Exchange (iOS / macOS) are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3] — 2026-06-10

### Added
- **Compose remembers your last recipient.** Picking someone in Compose is
  remembered, so the next time you compose they're pre-selected instead of
  the list resetting to the top. The choice is shared between the main app
  and the iMessage extension — pick in one and it carries to the other.
- **Decrypt a shared message link.** Decrypt now accepts a
  `https://exchange.nettrash.me/msg…` link, not just the raw `EXC2:` envelope:
  paste either form (or pull it from the clipboard) and Exchange extracts the
  envelope before decrypting. Tapping such a link still opens the app and
  decrypts in place.
- **Choose how you share a sealed message.** The Compose result screen has a
  Link / EXC2 toggle: hand off the rich `exchange.nettrash.me/msg` link
  (default — shows a 🔒 preview and opens Exchange to decrypt) or the raw
  `EXC2:` envelope for plain-text channels. Your choice is remembered.
- **App lock.** An optional biometric lock — turn on “Require Face ID /
  Touch ID” in Settings and Exchange asks for Face ID / Touch ID / Optic ID
  (or your device passcode as a fallback) before opening. Two settings make
  it configurable:
  - **Re-lock** — how long the app can be in the background before it locks
    again: Immediately, after 1 / 5 / 15 minutes, or only on launch.
  - **Also lock message links & iMessage** — extends the lock to opening a
    shared message link and to the iMessage app, not just the main app.
  It's a convenience lock; your keys stay protected by the system Keychain
  either way, and if the device has no biometrics or passcode set the lock
  fails open so you can't be shut out of your own identity.
- **Encrypt & decrypt files.** New "Encrypt file" / "Decrypt file" actions
  (the ••• menu on the home screen) seal any file — its name and bytes — to a
  recipient as a shareable `.exc2` file, signed by you. The recipient opens it
  in Exchange (or taps the file → Open in Exchange) and gets the original
  back. Same envelope format as messages, so it interoperates across iOS,
  macOS and Android.

### Changed
- The Compose recipient picker now lists recipients in the **same order as
  the home screen** — your manual drag-order first, then newest-first for the
  rest — instead of alphabetically. The iMessage extension's picker matches.

### Fixed
- The Compose **Encrypt & sign** button is no longer hidden behind the
  keyboard while typing a message — swipe to dismiss the keyboard, or tap
  Done on the keyboard toolbar, to reach it.

## [1.2] — 2026-06-05

### Added
- **Rename recipients.** Tap a recipient (or right-click → Rename on macOS) to
  edit its display label and notes. The underlying key identity and
  fingerprint are immutable and stay visible while editing.
- **Reorder recipients.** Enter Edit mode to drag recipients into a custom
  order. The manual order is persisted per recipient.

### Changed
- The recipient list now sorts by your manual order, falling back to
  newest-first for rows you haven't reordered.
- Renames and reorders now propagate across your devices through the
  end-to-end-encrypted iCloud Keychain recipient sync (latest edit wins),
  and are carried in passphrase-encrypted identity backups. The sync and
  backup formats gained two optional fields and remain compatible with
  older builds in both directions.

## [1.1]

### Added
- Recipient list sync across your devices on the same Apple ID, via an
  end-to-end-encrypted blob in iCloud Keychain (no CloudKit, no servers).

## [1.0]

### Added
- Initial release: compose signed, encrypted messages as a single base64
  line to paste into any messenger; swap public keys by QR or paste;
  identity held in the Keychain with passphrase-encrypted backups.
- No accounts, no servers, no telemetry, no ads.
