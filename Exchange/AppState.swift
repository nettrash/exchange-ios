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
}
