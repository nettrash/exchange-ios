//
//  ExchangeApp.swift
//  Exchange
//
//  Created by Ivan Alekseev on 09/10/2025.
//

import SwiftData
import SwiftUI

@main
struct ExchangeApp: App {
    /// Result of the SwiftData container construction. We capture the
    /// outcome at app init time so the SwiftUI scene can choose between
    /// the normal app body and a recoverable error view, instead of
    /// crashing on a `fatalError` if (e.g.) the on-disk store is corrupt.
    private let containerResult: Result<ModelContainer, Error>

    /// Recipient-list sync coordinator. Long-lived for the app's
    /// lifetime; surfaced through the SwiftUI Environment so views can
    /// read its state and flip the Settings toggle. Nil only if the
    /// SwiftData container failed to construct, in which case the app
    /// shows ContainerLoadErrorView and never reaches the bound state.
    private let recipientsSync: RecipientsSyncCoordinator?

    /// Cross-view signal bus. Today it carries the pending envelope from
    /// a Universal Link tap; future global app state can live here too.
    @State private var appState = AppState()

    init() {
        let schema = Schema([Recipient.self])
        // The SwiftData store lives inside the shared App Group container
        // so the iMessage extension can open the same store. CloudKit
        // remains explicitly off on the SwiftData side — recipient sync
        // (added in v1.1) goes through an end-to-end-encrypted blob
        // stored in iCloud Keychain, not through CloudKit's private
        // database. See RecipientsSync.swift for the threat model.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(AppConstants.appGroupIdentifier),
            cloudKitDatabase: .none
        )
        let result = Result {
            try ModelContainer(for: schema, configurations: [modelConfiguration])
        }
        self.containerResult = result
        self.recipientsSync = (try? result.get())
            .map { RecipientsSyncCoordinator(modelContainer: $0) }
    }

    var body: some Scene {
        WindowGroup {
            switch containerResult {
            case .success(let container):
                if let recipientsSync {
                    ContentView()
                        .modelContainer(container)
                        .environment(appState)
                        .environment(recipientsSync)
                        .onOpenURL { url in
                            // A `.exc2` file opened "with Exchange" arrives as
                            // a file URL — route it to DecryptFileView.
                            if url.isFileURL {
                                appState.pendingDecryptFileURL = url
                                return
                            }
                            // Otherwise a Universal Link (e.g. Exchange bubble
                            // tapped in Messages.app on Mac, or any app
                            // surfacing our exchange.nettrash.me/msg URL).
                            // Extract the envelope and stash it for
                            // ContentView to pick up; ContentView auto-
                            // presents DecryptView pre-filled.
                            if let envelope = EnvelopeURL.extract(from: url) {
                                appState.pendingDecryptEnvelope = envelope
                            }
                        }
                }
            case .failure(let error):
                ContainerLoadErrorView(error: error)
            }
        }
    }
}

/// Shown when the SwiftData container can't be opened. Visually matches
/// the launch screen + splash so the user feels they're still inside the
/// app rather than thrown into a crash dialog.
private struct ContainerLoadErrorView: View {
    let error: Error

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                VStack(spacing: 12) {
                    Text("Couldn't open the recipient store.")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                Text("Reinstall Exchange to start fresh.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .preferredColorScheme(.dark)
    }
}
