//
//  AppSettings.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import Foundation

/// User preferences model with UserDefaults persistence backing.
public struct AppSettings: Codable, Equatable, Sendable {
    
    // MARK: - Preference Keys
    public enum Keys {
        public static let defaultCompressionStrength = "com.medialite.settings.defaultCompressionStrength"
        public static let defaultVideoMode = "com.medialite.settings.defaultVideoMode"
        public static let autoSaveToLibrary = "com.medialite.settings.autoSaveToLibrary"
        public static let preserveMetadata = "com.medialite.settings.preserveMetadata"
        public static let deleteOriginalPrompt = "com.medialite.settings.deleteOriginalPrompt"
        public static let maxCacheAgeDays = "com.medialite.settings.maxCacheAgeDays"
    }
    
    // MARK: - Properties
    public var defaultCompressionStrength: CompressionStrength
    public var defaultVideoMode: VideoProcessingMode
    public var autoSaveToLibrary: Bool
    public var preserveMetadata: Bool
    public var deleteOriginalPrompt: Bool
    public var maxCacheAgeDays: Int {
        didSet {
            maxCacheAgeDays = max(0, min(maxCacheAgeDays, 365))
        }
    }
    
    // MARK: - Compatibility Computed Properties
    public var defaultPhotoCompressionQuality: CompressionStrength {
        get { defaultCompressionStrength }
        set { defaultCompressionStrength = newValue }
    }
    
    public var defaultVideoProcessingMode: VideoProcessingMode {
        get { defaultVideoMode }
        set { defaultVideoMode = newValue }
    }
    
    public var autoSaveToPhotosLibrary: Bool {
        get { autoSaveToLibrary }
        set { autoSaveToLibrary = newValue }
    }
    
    public var keepOriginalMetadata: Bool {
        get { preserveMetadata }
        set { preserveMetadata = newValue }
    }
    
    public var deleteOriginalAfterExport: Bool {
        get { deleteOriginalPrompt }
        set { deleteOriginalPrompt = newValue }
    }
    
    // MARK: - Initialization
    public init(
        defaultCompressionStrength: CompressionStrength = .medium,
        defaultVideoMode: VideoProcessingMode = .reduceSize,
        autoSaveToLibrary: Bool = false,
        preserveMetadata: Bool = true,
        deleteOriginalPrompt: Bool = false,
        maxCacheAgeDays: Int = 7
    ) {
        self.defaultCompressionStrength = defaultCompressionStrength
        self.defaultVideoMode = defaultVideoMode
        self.autoSaveToLibrary = autoSaveToLibrary
        self.preserveMetadata = preserveMetadata
        self.deleteOriginalPrompt = deleteOriginalPrompt
        self.maxCacheAgeDays = max(0, min(maxCacheAgeDays, 365))
    }
    
    /// Default factory values.
    public static let `default` = AppSettings()
    
    // MARK: - Persistence
    
    /// Loads user settings from the provided `UserDefaults` store, falling back to defaults for missing keys.
    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        var settings = AppSettings.default
        
        if let strengthRaw = defaults.string(forKey: Keys.defaultCompressionStrength),
           let strength = CompressionStrength(rawValue: strengthRaw) {
            settings.defaultCompressionStrength = strength
        }
        
        if let modeRaw = defaults.string(forKey: Keys.defaultVideoMode),
           let mode = VideoProcessingMode(rawValue: modeRaw) {
            settings.defaultVideoMode = mode
        }
        
        if defaults.object(forKey: Keys.autoSaveToLibrary) != nil {
            settings.autoSaveToLibrary = defaults.bool(forKey: Keys.autoSaveToLibrary)
        }
        
        if defaults.object(forKey: Keys.preserveMetadata) != nil {
            settings.preserveMetadata = defaults.bool(forKey: Keys.preserveMetadata)
        }
        
        if defaults.object(forKey: Keys.deleteOriginalPrompt) != nil {
            settings.deleteOriginalPrompt = defaults.bool(forKey: Keys.deleteOriginalPrompt)
        }
        
        if defaults.object(forKey: Keys.maxCacheAgeDays) != nil {
            let cacheDays = defaults.integer(forKey: Keys.maxCacheAgeDays)
            if cacheDays < 0 {
                // Invalid negative preference from disk corruption -> restore factory default 7 days
                settings.maxCacheAgeDays = 7
            } else {
                // Out-of-bounds upper limit clamping -> clamp to 365
                settings.maxCacheAgeDays = min(cacheDays, 365)
            }
        }
        
        return settings
    }
    
    /// Persists the current settings to the provided `UserDefaults` store.
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(defaultCompressionStrength.rawValue, forKey: Keys.defaultCompressionStrength)
        defaults.set(defaultVideoMode.rawValue, forKey: Keys.defaultVideoMode)
        defaults.set(autoSaveToLibrary, forKey: Keys.autoSaveToLibrary)
        defaults.set(preserveMetadata, forKey: Keys.preserveMetadata)
        defaults.set(deleteOriginalPrompt, forKey: Keys.deleteOriginalPrompt)
        defaults.set(maxCacheAgeDays, forKey: Keys.maxCacheAgeDays)
    }
    
    /// Resets persisted user settings back to factory defaults.
    @discardableResult
    public static func reset(userDefaults defaults: UserDefaults = .standard) -> AppSettings {
        defaults.removeObject(forKey: Keys.defaultCompressionStrength)
        defaults.removeObject(forKey: Keys.defaultVideoMode)
        defaults.removeObject(forKey: Keys.autoSaveToLibrary)
        defaults.removeObject(forKey: Keys.preserveMetadata)
        defaults.removeObject(forKey: Keys.deleteOriginalPrompt)
        defaults.removeObject(forKey: Keys.maxCacheAgeDays)
        
        let defaultSettings = AppSettings.default
        defaultSettings.save(to: defaults)
        return defaultSettings
    }
}

// MARK: - PresetManagerProtocol

public protocol PresetManagerProtocol: Sendable {
    func loadSettings() -> AppSettings
    func saveSettings(_ settings: AppSettings)
    func resetSettings() -> AppSettings
}

public struct PresetManager: PresetManagerProtocol {
    private let defaults: UserDefaults
    
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    public func loadSettings() -> AppSettings {
        AppSettings.load(from: defaults)
    }
    
    public func saveSettings(_ settings: AppSettings) {
        settings.save(to: defaults)
    }
    
    public func resetSettings() -> AppSettings {
        AppSettings.reset(userDefaults: defaults)
    }
}
