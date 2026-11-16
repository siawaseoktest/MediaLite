//
//  SettingsViewModelTests.swift
//  MediaLiteTests
//
//  Unit tests for SettingsViewModel covering default configuration loading,
//  mutation and persistence, factory reset, temporary cache inspection and purging,
//  and disk space inspection.
//

import XCTest
@testable import MediaLite

final class SettingsViewModelTests: XCTestCase {

    private var isolatedDefaults: UserDefaults!
    private var testSuiteName: String!
    private var tempDirectoryURL: URL!
    private var tempManager: TempFileManager!

    override func setUp() {
        super.setUp()
        testSuiteName = "com.medialite.tests.settingsvm.\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: testSuiteName)

        let tempID = UUID().uuidString
        let subfolder = "com.medialite.tests.settings.cache.\(tempID)"
        tempManager = TempFileManager(tempSubdirectoryName: subfolder)
        tempDirectoryURL = tempManager.baseDirectory
    }

    override func tearDown() {
        if let isolatedDefaults = isolatedDefaults, let testSuiteName = testSuiteName {
            isolatedDefaults.removePersistentDomain(forName: testSuiteName)
        }
        if let tempManager = tempManager {
            try? tempManager.purgeAllTempFiles()
            try? FileManager.default.removeItem(at: tempManager.baseDirectory)
        }
        isolatedDefaults = nil
        testSuiteName = nil
        tempDirectoryURL = nil
        tempManager = nil
        super.tearDown()
    }

    @MainActor
    func testSettingsViewModelLoadsDefaults() {
        let viewModel = SettingsViewModel(defaults: isolatedDefaults, tempManager: tempManager)

        XCTAssertEqual(viewModel.settings.defaultCompressionStrength, .medium)
        XCTAssertEqual(viewModel.settings.defaultVideoMode, .reduceSize)
        XCTAssertFalse(viewModel.settings.autoSaveToLibrary)
        XCTAssertTrue(viewModel.settings.preserveMetadata)
        XCTAssertFalse(viewModel.settings.deleteOriginalPrompt)
        XCTAssertEqual(viewModel.settings.maxCacheAgeDays, 7)
    }

    @MainActor
    func testSettingsViewModelMutatesAndSaves() {
        let viewModel = SettingsViewModel(defaults: isolatedDefaults, tempManager: tempManager)

        viewModel.settings.defaultCompressionStrength = .high
        viewModel.settings.defaultVideoMode = .compressAndConvert
        viewModel.settings.autoSaveToLibrary = true
        viewModel.updateSettings()

        // Verify reloaded from isolated UserDefaults
        let reloaded = AppSettings.load(from: isolatedDefaults)
        XCTAssertEqual(reloaded.defaultCompressionStrength, .high)
        XCTAssertEqual(reloaded.defaultVideoMode, .compressAndConvert)
        XCTAssertTrue(reloaded.autoSaveToLibrary)
    }

    @MainActor
    func testSettingsViewModelResetToDefaults() {
        let viewModel = SettingsViewModel(defaults: isolatedDefaults, tempManager: tempManager)

        viewModel.settings.defaultCompressionStrength = .low
        viewModel.settings.autoSaveToLibrary = true
        viewModel.updateSettings()

        viewModel.resetToDefaults()

        XCTAssertEqual(viewModel.settings.defaultCompressionStrength, .medium)
        XCTAssertFalse(viewModel.settings.autoSaveToLibrary)
        XCTAssertNotNil(viewModel.statusMessage)
        XCTAssertTrue(viewModel.statusMessage?.contains("defaults") == true)
    }

    @MainActor
    func testSettingsViewModelCacheInspectionAndPurge() throws {
        // Write a test temporary file
        let dummyFile = tempDirectoryURL.appendingPathComponent("temp_cache.bin")
        let dummyData = Data(repeating: 0xCC, count: 50_000)
        try dummyData.write(to: dummyFile)

        let viewModel = SettingsViewModel(defaults: isolatedDefaults, tempManager: tempManager)
        viewModel.inspectCache()

        XCTAssertEqual(viewModel.cacheSizeBytes, 50_000)

        viewModel.clearCache()

        XCTAssertEqual(viewModel.cacheSizeBytes, 0)
        XCTAssertNotNil(viewModel.statusMessage)
        XCTAssertTrue(viewModel.statusMessage?.contains("Cleared") == true)
    }

    @MainActor
    func testSettingsViewModelAvailableDiskSpace() {
        let viewModel = SettingsViewModel(defaults: isolatedDefaults, tempManager: tempManager)

        if let freeBytes = viewModel.availableDiskBytes {
            XCTAssertGreaterThanOrEqual(freeBytes, 0)
        }
    }
}
