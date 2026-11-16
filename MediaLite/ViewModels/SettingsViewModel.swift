//
//  SettingsViewModel.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  ViewModel managing application settings, compression defaults,
//  temporary storage inspection, cache purging, and privacy information.
//

import Foundation
import SwiftUI

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var settings: AppSettings
    @Published public private(set) var cacheSizeBytes: Int64 = 0
    @Published public private(set) var availableDiskBytes: Int64? = nil
    @Published public var showResetConfirmation: Bool = false
    @Published public var showClearCacheConfirmation: Bool = false
    @Published public var statusMessage: String? = nil
    
    private let defaults: UserDefaults
    private let tempManager: TempFileManager
    
    public init(
        defaults: UserDefaults = .standard,
        tempManager: TempFileManager = .shared
    ) {
        self.defaults = defaults
        self.tempManager = tempManager
        self.settings = AppSettings.load(from: defaults)
        inspectCache()
    }
    
    public func updateSettings() {
        settings.save(to: defaults)
    }
    
    public func resetToDefaults() {
        self.settings = AppSettings.reset(userDefaults: defaults)
        self.statusMessage = "Settings restored to defaults"
    }
    
    public func inspectCache() {
        let baseDir = tempManager.baseDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            self.cacheSizeBytes = 0
            self.availableDiskBytes = tempManager.getAvailableDiskSpace()
            return
        }
        
        var total: Int64 = 0
        for file in files {
            if let vals = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = vals.fileSize {
                total += Int64(size)
            }
        }
        self.cacheSizeBytes = total
        self.availableDiskBytes = tempManager.getAvailableDiskSpace()
    }
    
    public func clearCache() {
        do {
            let count = try tempManager.purgeAllTempFiles()
            inspectCache()
            self.statusMessage = "Cleared \(count) temporary file\(count == 1 ? "" : "s")"
        } catch {
            self.statusMessage = "Failed to clear cache: \(error.localizedDescription)"
        }
    }
}
