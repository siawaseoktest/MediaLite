//
//  AppSettingsTests.swift
//  MediaLiteTests
//
//  Created for MediaLite Milestone 1.
//

import XCTest
@testable import MediaLite

final class AppSettingsTests: XCTestCase {
    
    private var testDefaults: UserDefaults!
    private let suiteName = "com.medialite.tests.appsettings"
    
    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults.removePersistentDomain(forName: suiteName)
    }
    
    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }
    
    func testFactoryDefaultValues() {
        let settings = AppSettings.default
        
        XCTAssertEqual(settings.defaultCompressionStrength, .medium)
        XCTAssertEqual(settings.defaultVideoMode, .reduceSize)
        XCTAssertFalse(settings.autoSaveToLibrary)
        XCTAssertTrue(settings.preserveMetadata)
        XCTAssertFalse(settings.deleteOriginalPrompt)
        XCTAssertEqual(settings.maxCacheAgeDays, 7)
    }
    
    func testSaveAndLoadPreferences() {
        var settings = AppSettings()
        settings.defaultCompressionStrength = .high
        settings.defaultVideoMode = .improveCompatibility
        settings.autoSaveToLibrary = true
        settings.preserveMetadata = false
        settings.deleteOriginalPrompt = true
        settings.maxCacheAgeDays = 14
        
        // Save to isolated suite
        settings.save(to: testDefaults)
        
        // Load from isolated suite
        let loaded = AppSettings.load(from: testDefaults)
        
        XCTAssertEqual(loaded.defaultCompressionStrength, .high)
        XCTAssertEqual(loaded.defaultVideoMode, .improveCompatibility)
        XCTAssertTrue(loaded.autoSaveToLibrary)
        XCTAssertFalse(loaded.preserveMetadata)
        XCTAssertTrue(loaded.deleteOriginalPrompt)
        XCTAssertEqual(loaded.maxCacheAgeDays, 14)
    }
    
    func testResetToDefaults() {
        var settings = AppSettings()
        settings.defaultCompressionStrength = .high
        settings.defaultVideoMode = .compressAndConvert
        settings.autoSaveToLibrary = true
        settings.save(to: testDefaults)
        
        // Verify mutated state was persisted
        let mutated = AppSettings.load(from: testDefaults)
        XCTAssertEqual(mutated.defaultCompressionStrength, .high)
        
        // Reset
        let resetSettings = AppSettings.reset(userDefaults: testDefaults)
        XCTAssertEqual(resetSettings, AppSettings.default)
        
        // Verify loading after reset returns defaults
        let loadedAfterReset = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loadedAfterReset.defaultCompressionStrength, .medium)
        XCTAssertEqual(loadedAfterReset.defaultVideoMode, .reduceSize)
        XCTAssertFalse(loadedAfterReset.autoSaveToLibrary)
        XCTAssertTrue(loadedAfterReset.preserveMetadata)
        XCTAssertFalse(loadedAfterReset.deleteOriginalPrompt)
        XCTAssertEqual(loadedAfterReset.maxCacheAgeDays, 7)
    }
    
    func testCorruptedOrUnknownValuesFallbackSafely() {
        // Set invalid raw values directly in defaults
        testDefaults.set("INVALID_STRENGTH", forKey: AppSettings.Keys.defaultCompressionStrength)
        testDefaults.set("NON_EXISTENT_MODE", forKey: AppSettings.Keys.defaultVideoMode)
        
        let loaded = AppSettings.load(from: testDefaults)
        
        // Should fall back safely to defaults for missing / unparsed keys
        XCTAssertEqual(loaded.defaultCompressionStrength, .medium)
        XCTAssertEqual(loaded.defaultVideoMode, .reduceSize)
        XCTAssertEqual(loaded.maxCacheAgeDays, 7)
    }
    
    func testZeroCacheDaysPreservedOnSaveAndLoad() {
        var settings = AppSettings()
        settings.maxCacheAgeDays = 0
        settings.save(to: testDefaults)
        
        let loaded = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loaded.maxCacheAgeDays, 0, "maxCacheAgeDays = 0 must be preserved upon load")
    }
    
    func testMaxCacheAgeDaysClampingAndOverflowPrevention() {
        // Direct assignment exceeding upper bound
        var settings = AppSettings(maxCacheAgeDays: Int.max)
        XCTAssertEqual(settings.maxCacheAgeDays, 365, "Initializer should clamp Int.max to 365")
        
        settings.maxCacheAgeDays = Int.max
        XCTAssertEqual(settings.maxCacheAgeDays, 365, "Property setter should clamp Int.max to 365")
        
        // Negative days clamping to 0
        settings.maxCacheAgeDays = -50
        XCTAssertEqual(settings.maxCacheAgeDays, 0, "Negative cache days should clamp to 0")
        
        // Simulating UserDefaults with Int.max stored by third party or corruption
        testDefaults.set(Int.max, forKey: AppSettings.Keys.maxCacheAgeDays)
        let loaded = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loaded.maxCacheAgeDays, 365, "Loading Int.max from defaults must be safely clamped to 365")
        
        // Simulating UserDefaults with negative value falling back to factory default 7 days
        testDefaults.set(-10, forKey: AppSettings.Keys.maxCacheAgeDays)
        let loadedNegative = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loadedNegative.maxCacheAgeDays, 7, "Negative cache age must fall back to 7 days")
        
        // Simulating severe corruption fallback to 7 days
        testDefaults.set(-99, forKey: AppSettings.Keys.maxCacheAgeDays)
        let loadedSevere = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loadedSevere.maxCacheAgeDays, 7, "Negative cache age must fall back to 7 days")
        
        // Ensure multiplication by seconds in day does not overflow
        let seconds = Int64(loaded.maxCacheAgeDays) * 86400
        XCTAssertEqual(seconds, 365 * 86400)
    }
    
    func testCompressionStrengthProperties() {
        XCTAssertEqual(CompressionStrength.low.lossyQuality, 0.90)
        XCTAssertEqual(CompressionStrength.medium.lossyQuality, 0.75)
        XCTAssertEqual(CompressionStrength.high.lossyQuality, 0.55)
        
        XCTAssertEqual(CompressionStrength.low.dimensionScale, 0.95)
        XCTAssertEqual(CompressionStrength.medium.dimensionScale, 0.87)
        XCTAssertEqual(CompressionStrength.high.dimensionScale, 0.74)
        
        for strength in CompressionStrength.allCases {
            XCTAssertFalse(strength.displayName.isEmpty)
            XCTAssertFalse(strength.localizedDescription.isEmpty)
            XCTAssertFalse(strength.iconName.isEmpty)
        }
    }
    
    func testVideoProcessingModeProperties() {
        for mode in VideoProcessingMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.localizedDescription.isEmpty)
            XCTAssertFalse(mode.iconName.isEmpty)
        }
    }
    
    func testCompatibilityAliases() {
        var settings = AppSettings()
        
        // Initial alias reads
        XCTAssertEqual(settings.defaultPhotoCompressionQuality, .medium)
        XCTAssertEqual(settings.defaultVideoProcessingMode, .reduceSize)
        XCTAssertFalse(settings.autoSaveToPhotosLibrary)
        XCTAssertTrue(settings.keepOriginalMetadata)
        XCTAssertFalse(settings.deleteOriginalAfterExport)
        
        // Mutate via aliases
        settings.defaultPhotoCompressionQuality = .high
        settings.defaultVideoProcessingMode = .improveCompatibility
        settings.autoSaveToPhotosLibrary = true
        settings.keepOriginalMetadata = false
        settings.deleteOriginalAfterExport = true
        
        // Check underlying stored properties
        XCTAssertEqual(settings.defaultCompressionStrength, .high)
        XCTAssertEqual(settings.defaultVideoMode, .improveCompatibility)
        XCTAssertTrue(settings.autoSaveToLibrary)
        XCTAssertFalse(settings.preserveMetadata)
        XCTAssertTrue(settings.deleteOriginalPrompt)
    }
    
    func testAppLanguageSaveAndLoadAndReset() {
        // Default check
        let defaultSettings = AppSettings.default
        XCTAssertEqual(defaultSettings.appLanguage, .system)
        
        // Mutate and save
        var settings = AppSettings()
        settings.appLanguage = .japanese
        settings.save(to: testDefaults)
        
        // Load
        let loaded = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loaded.appLanguage, .japanese)
        
        // Mutate to english
        var settingsEn = AppSettings()
        settingsEn.appLanguage = .english
        settingsEn.save(to: testDefaults)
        let loadedEn = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loadedEn.appLanguage, .english)
        
        // Reset
        let resetSettings = AppSettings.reset(userDefaults: testDefaults)
        XCTAssertEqual(resetSettings.appLanguage, .system)
        let loadedAfterReset = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loadedAfterReset.appLanguage, .system)
    }
}
