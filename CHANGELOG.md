# Changelog

All notable changes to Exchange (iOS / macOS) are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
