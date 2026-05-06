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

    init() {
        let schema = Schema([Recipient.self])
        // The SwiftData store lives inside the shared App Group container
        // so the iMessage extension can open the same store and pick from
        // the same recipient list. CloudKit stays explicitly off — the
        // recipient list survives a device-to-device restore via standard
        // iOS backup; nothing is ever pushed to iCloud directly.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(AppConstants.appGroupIdentifier),
            cloudKitDatabase: .none
        )
        containerResult = Result {
            try ModelContainer(for: schema, configurations: [modelConfiguration])
        }
    }

    var body: some Scene {
        WindowGroup {
            switch containerResult {
            case .success(let container):
                ContentView()
                    .modelContainer(container)
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
