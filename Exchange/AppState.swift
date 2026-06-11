//
//  AppState.swift
//  Exchange
//
//  App-wide observable state. Currently carries one piece of cross-view
//  signal: a pending EXC2 envelope from a Universal Link, so the App
//  scene's `.onOpenURL` handler can hand it off to ContentView, which
//  then auto-presents DecryptView with the envelope pre-filled.
//
//  Lives at the App level rather than inside ContentView so the URL
//  routing path doesn't depend on which sheet happens to be on screen
//  when the link arrives.
//

import Foundation
import Observation

@Observable
final class AppState {
    /// The most recent envelope received via Universal Link, awaiting
    /// presentation in DecryptView. Cleared when DecryptView closes.
    var pendingDecryptEnvelope: String?

    /// A `.exc2` file opened from another app ("Open in Exchange"),
    /// awaiting presentation in DecryptFileView. Cleared when it closes.
    var pendingDecryptFileURL: URL?
}

/// Identifiable wrapper so a file URL can drive a SwiftUI `.sheet(item:)`.
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
