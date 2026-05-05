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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Recipient.self,
        ])
        // The SwiftData store lives inside the shared App Group container
        // so the iMessage extension can open the same store and pick from
        // the same recipient list. CloudKit stays explicitly off — we
        // manage cross-device identity via passphrase-encrypted backup,
        // not iCloud.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(AppConstants.appGroupIdentifier),
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
