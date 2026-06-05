//
//  EnvelopeURL.swift
//  Exchange
//
//  Bidirectional codec between Exchange's `EXC2:` envelope strings and
//  the URL form used inside iMessage `MSMessage` payloads (and copyable
//  from `Messages.app` on Mac via right-click → Copy Link). Both forms
//  carry the same bytes; the URL just wraps the envelope body in
//  base64url so it survives URL parsing without percent-encoding.
//
//  The URL host is `exchange.nettrash.me`, a real subdomain that serves
//  an AASA file at `https://exchange.nettrash.me/.well-known/apple-app-site-association`.
//  That authorises Exchange to handle these as Universal Links — tap an
//  Exchange URL anywhere on iOS or Mac Catalyst and the app opens with
//  the envelope already loaded.
//
//  Used by:
//    - the iMessage extension, to construct the URL we attach to each
//      outgoing MSMessage and to extract the envelope from received
//      MSMessages
//    - the main app's DecryptView, to recognise and auto-paste the
//      URL form on the clipboard. On Mac specifically, this is what
//      makes "right-click an iMessage bubble in Messages.app, copy
//      link, switch to Exchange, decrypt" a near-zero-friction flow.
//
//  Lives next to CryptoEnvelope.swift in Crypto/ so both targets that
//  need it (Exchange + MessagesExtension) get it via the synchronized
//  source group without an explicit per-file membership decision.
//

import Foundation

nonisolated enum EnvelopeURL {
    static let scheme = "https"
    static let host = "exchange.nettrash.me"
    static let path = "/msg"

    // MARK: - Build a URL around an envelope

    /// Wrap an `EXC2:<base64>` envelope into a URL we can drop into an
    /// MSMessage. The envelope body is base64url-encoded as the `p`
    /// query parameter. Returns nil only for malformed input (missing
    /// `EXC2:` prefix).
    nonisolated static func url(for envelope: String) -> URL? {
        let prefix = CryptoEnvelope.prefix
        guard envelope.hasPrefix(prefix) else { return nil }
        let body = String(envelope.dropFirst(prefix.count))
        let urlSafe = body
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "p", value: urlSafe),
        ]
        return components.url
    }

    // MARK: - Recover the envelope from a URL

    /// Reverse of `url(for:)`. Returns the canonical `EXC2:<base64>`
    /// envelope, or nil for any URL whose host/path/payload doesn't
    /// match what we'd produce.
    nonisolated static func extract(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == host,
              components.path == path,
              let urlSafe = components.queryItems?.first(where: { $0.name == "p" })?.value,
              !urlSafe.isEmpty else {
            return nil
        }
        let standardBase64 = urlSafe
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - standardBase64.count % 4) % 4
        let padded = standardBase64 + String(repeating: "=", count: padding)
        return CryptoEnvelope.prefix + padded
    }

    // MARK: - Find an envelope inside arbitrary text

    /// Scan arbitrary text for the first thing that looks like an
    /// Exchange envelope and return it in canonical `EXC2:<base64>` form.
    /// Recognises both the raw envelope string and our URL form.
    /// Returns nil if neither shows up.
    nonisolated static func envelopeIfPresent(in text: String) -> String? {
        if let raw = extractRawEnvelope(from: text) {
            return raw
        }
        if let urlString = firstURLString(matchingHost: host, in: text),
           let url = URL(string: urlString),
           let envelope = extract(from: url) {
            return envelope
        }
        return nil
    }

    // MARK: - Helpers

    /// Locate a raw `EXC2:` envelope inside arbitrary text. Walks from
    /// the prefix until it hits a non-base64 character.
    private nonisolated static func extractRawEnvelope(from text: String) -> String? {
        let prefix = CryptoEnvelope.prefix
        guard let prefixRange = text.range(of: prefix) else { return nil }
        let validBase64: Set<Character> = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        )
        var endIndex = prefixRange.upperBound
        while endIndex < text.endIndex, validBase64.contains(text[endIndex]) {
            endIndex = text.index(after: endIndex)
        }
        guard endIndex > prefixRange.upperBound else { return nil }
        return String(text[prefixRange.lowerBound..<endIndex])
    }

    /// Locate the first URL string in `text` whose host equals
    /// `targetHost`. Walks from the `https://<host>` prefix forward
    /// until whitespace or end-of-string. Robust enough for clipboard
    /// payloads we'd actually see; not a full URL parser.
    private nonisolated static func firstURLString(
        matchingHost targetHost: String,
        in text: String
    ) -> String? {
        let needle = "\(scheme)://\(targetHost)"
        guard let prefixRange = text.range(of: needle) else { return nil }
        var endIndex = prefixRange.upperBound
        while endIndex < text.endIndex {
            let c = text[endIndex]
            if c.isWhitespace || c.isNewline { break }
            endIndex = text.index(after: endIndex)
        }
        return String(text[prefixRange.lowerBound..<endIndex])
    }
}
