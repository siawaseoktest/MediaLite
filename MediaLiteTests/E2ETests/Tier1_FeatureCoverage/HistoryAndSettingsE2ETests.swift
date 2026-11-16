//
//  HistoryAndSettingsE2ETests.swift
//  MediaLiteTests
//
//  Tier 1 Feature Coverage E2E Tests: History & Settings Persistence.
//  Covers HistoryStore atomic save/load, single item deletion, clear all,
//  and AppSettings UserDefaults persistence and default quality/mode retrieval.
//

import XCTest
@testable import MediaLite

final class HistoryAndSettingsE2ETests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var testDefaults: UserDefaults!
    private let suiteName = "com.medialite.tests.tier1.settings"
    private var historyStoreURL: URL!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults?.removePersistentDomain(forName: suiteName)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history_tests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        historyStoreURL = tempDir.appendingPathComponent("history.json")
        trackedURLs.append(tempDir)
    }

    override func tearDown() {
        testDefaults?.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        SyntheticAssetGenerator.cleanup(urls: trackedURLs)
        trackedURLs.removeAll()
        try? TempFileManager.shared.purgeAllTempFiles()
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeHistoryItem(
        fileName: String = "photo.jpg",
        mediaType: String = "photo",
        sourceFormat: String = "jpeg",
        targetFormat: String = "jpeg",
        origSize: Int64 = 5_000_000,
        compSize: Int64 = 2_000_000,
        strength: CompressionStrength = .medium,
        duration: Double? = nil
    ) -> CompressionHistoryItem {
        CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: fileName,
            mediaType: mediaType,
            sourceFormat: sourceFormat,
            targetFormat: targetFormat,
            originalByteSize: origSize,
            compressedByteSize: compSize,
            compressionStrength: strength,
            durationSeconds: duration,
            isSavedToLibrary: false
        )
    }

    // MARK: - 1. HistoryStore Atomic Save & Load

    func testHistoryStoreAtomicSaveAndLoad() async throws {
        let store = HistoryStore(fileURL: historyStoreURL)

        let item1 = makeHistoryItem(fileName: "vacation.heic", mediaType: "photo", sourceFormat: "heic", origSize: 8_000_000, compSize: 3_000_000)
        let item2 = makeHistoryItem(fileName: "recording.mov", mediaType: "video", sourceFormat: "mov", targetFormat: "mp4", origSize: 50_000_000, compSize: 15_000_000, strength: .high, duration: 12.5)
        let item3 = makeHistoryItem(fileName: "logo.png", mediaType: "photo", sourceFormat: "png", origSize: 2_000_000, compSize: 800_000, strength: .low)

        try await store.addItem(item1)
        try await store.addItem(item2)
        try await store.addItem(item3)

        let loaded = try await store.loadHistory()
        XCTAssertEqual(loaded.count, 3, "All 3 items must be persisted and loaded")

        // Verify content fidelity
        XCTAssertTrue(loaded.contains(where: { $0.id == item1.id && $0.fileName == "vacation.heic" }))
        XCTAssertTrue(loaded.contains(where: { $0.id == item2.id && $0.durationSeconds == 12.5 }))
        XCTAssertTrue(loaded.contains(where: { $0.id == item3.id && $0.compressionStrength == .low }))

        // Re-instantiate a fresh HistoryStore pointing to the same file URL to verify atomic disk persistence
        let freshStore = HistoryStore(fileURL: historyStoreURL)
        let reloaded = try await freshStore.loadHistory()
        XCTAssertEqual(reloaded.count, 3, "New store instance must load items persisted to disk")
        XCTAssertEqual(reloaded, loaded, "Reloaded items must be identical to initially loaded items")
    }

    // MARK: - 2. HistoryStore Single Item Deletion

    func testHistoryStoreSingleItemDeletion() async throws {
        let store = HistoryStore(fileURL: historyStoreURL)

        let itemA = makeHistoryItem(fileName: "a.jpg")
        let itemB = makeHistoryItem(fileName: "b.jpg")
        let itemC = makeHistoryItem(fileName: "c.jpg")

        try await store.addItem(itemA)
        try await store.addItem(itemB)
        try await store.addItem(itemC)

        var items = try await store.loadHistory()
        XCTAssertEqual(items.count, 3)

        // Delete itemB
        try await store.deleteItem(id: itemB.id)

        items = try await store.loadHistory()
        XCTAssertEqual(items.count, 2, "History count must be 2 after deleting one item")
        XCTAssertFalse(items.contains(where: { $0.id == itemB.id }), "Deleted item must no longer exist")
        XCTAssertTrue(items.contains(where: { $0.id == itemA.id }), "Non-deleted item A must remain")
        XCTAssertTrue(items.contains(where: { $0.id == itemC.id }), "Non-deleted item C must remain")

        // Deleting non-existent ID should be a safe no-op
        let nonExistentID = UUID()
        try await store.deleteItem(id: nonExistentID)
        items = try await store.loadHistory()
        XCTAssertEqual(items.count, 2, "Deleting non-existent item must not alter history count")
    }

    // MARK: - 3. HistoryStore Clear All History

    func testHistoryStoreClearAllHistory() async throws {
        let store = HistoryStore(fileURL: historyStoreURL)

        for index in 0..<5 {
            let item = makeHistoryItem(fileName: "photo_\(index).jpg")
            try await store.addItem(item)
        }

        var items = try await store.loadHistory()
        XCTAssertEqual(items.count, 5)

        // Clear all
        try await store.clearAllHistory()

        items = try await store.loadHistory()
        XCTAssertTrue(items.isEmpty, "History must be completely empty after clearAllHistory")

        // Verify disk state persists the clear operation
        let freshStore = HistoryStore(fileURL: historyStoreURL)
        let reloaded = try await freshStore.loadHistory()
        XCTAssertTrue(reloaded.isEmpty, "Fresh instance must confirm empty history on disk")
    }

    // MARK: - 4. AppSettings UserDefaults Persistence

    func testAppSettingsUserDefaultsPersistence() {
        guard let defaults = testDefaults else {
            XCTFail("UserDefaults suite failed to initialize")
            return
        }

        var customSettings = AppSettings()
        customSettings.defaultCompressionStrength = .high
        customSettings.defaultVideoMode = .improveCompatibility
        customSettings.autoSaveToLibrary = true
        customSettings.preserveMetadata = false
        customSettings.deleteOriginalPrompt = true
        customSettings.maxCacheAgeDays = 14

        // Save to isolated suite
        customSettings.save(to: defaults)

        // Load back from isolated suite
        let loaded = AppSettings.load(from: defaults)

        XCTAssertEqual(loaded.defaultCompressionStrength, .high)
        XCTAssertEqual(loaded.defaultVideoMode, .improveCompatibility)
        XCTAssertTrue(loaded.autoSaveToLibrary)
        XCTAssertFalse(loaded.preserveMetadata)
        XCTAssertTrue(loaded.deleteOriginalPrompt)
        XCTAssertEqual(loaded.maxCacheAgeDays, 14)
        XCTAssertEqual(loaded, customSettings)
    }

    // MARK: - 5. AppSettings Reset to Factory Defaults

    func testAppSettingsResetToDefaults() {
        guard let defaults = testDefaults else {
            XCTFail("UserDefaults suite failed to initialize")
            return
        }

        var mutated = AppSettings()
        mutated.defaultCompressionStrength = .high
        mutated.defaultVideoMode = .compressAndConvert
        mutated.autoSaveToLibrary = true
        mutated.save(to: defaults)

        // Reset
        let resetResult = AppSettings.reset(userDefaults: defaults)
        XCTAssertEqual(resetResult, AppSettings.default, "reset() must return AppSettings.default")

        // Verify subsequent load returns factory defaults
        let loadedAfterReset = AppSettings.load(from: defaults)
        XCTAssertEqual(loadedAfterReset.defaultCompressionStrength, .medium)
        XCTAssertEqual(loadedAfterReset.defaultVideoMode, .reduceSize)
        XCTAssertFalse(loadedAfterReset.autoSaveToLibrary)
        XCTAssertTrue(loadedAfterReset.preserveMetadata)
        XCTAssertFalse(loadedAfterReset.deleteOriginalPrompt)
        XCTAssertEqual(loadedAfterReset.maxCacheAgeDays, 7)
    }

    // MARK: - 6. AppSettings Default Quality and Mode Retrieval

    func testAppSettingsDefaultQualityAndModeRetrieval() {
        let defaults = AppSettings.default

        // Baseline defaults inspection
        XCTAssertEqual(defaults.defaultCompressionStrength, .medium)
        XCTAssertEqual(defaults.defaultVideoMode, .reduceSize)
        XCTAssertFalse(defaults.autoSaveToLibrary)
        XCTAssertTrue(defaults.preserveMetadata)
        XCTAssertFalse(defaults.deleteOriginalPrompt)
        XCTAssertEqual(defaults.maxCacheAgeDays, 7)

        // Verify all enum cases and display titles
        XCTAssertEqual(CompressionStrength.allCases.count, 3)
        XCTAssertEqual(CompressionStrength.low.lossyQuality, 0.90)
        XCTAssertEqual(CompressionStrength.medium.lossyQuality, 0.75)
        XCTAssertEqual(CompressionStrength.high.lossyQuality, 0.55)

        XCTAssertEqual(VideoProcessingMode.allCases.count, 3)
        for mode in VideoProcessingMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.localizedDescription.isEmpty)
            XCTAssertFalse(mode.iconName.isEmpty)
        }
    }
}
