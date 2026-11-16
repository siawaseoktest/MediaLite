//
//  MediaLiteApp.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  Application entry point with background cache cleanup lifecycle.
//

import SwiftUI

@main
struct MediaLiteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // Feature 6: Background orphaned temporary file purge
                try? TempFileManager.shared.purgeOrphanedTempFiles()
            }
        }
    }
}
