//
//  DeviceStorageCleanupWorkflowE2ETests.swift
//  MediaLiteTests
//
//  Tier 4: Real-World Application Scenarios
//  Scenario 4 & 5: Storage Recovery, History Management & App Settings Lifecycle.
//
//  Simulates realistic device storage cleanup and settings lifecycle workflows:
//  1. Multi-session compression history aggregation across photos and videos, computing
//     lifetime byte savings, category filtering (All vs Photos vs Videos), batch deletion
//     of selected items, and clear-all purge.
//  2. Temporary sandbox cache inspection and complete purge to reclaim device storage.
//  3. AppSettings lifecycle & cold-start simulation: mutated preferences (HIGH quality,
//     compressAndConvert mode, auto-save) persisting across app restarts and respected
//     in compression and conversion workflows without manual override.
//

import XCTest
@testable import MediaLite

final class DeviceStorageCleanupWorkflowE2ETests: XCTestCase {

    private var tempManager: TempFileManager!
    private var testSubdirectory: String!
    private var testDefaults: UserDefaults!
    private let suiteName = "com.medialite.tests.tier4.storage.\(UUID().uuidString)"
    private var historyFileURL: URL!
    private var generatedURLs: [URL] = []

    override func setUp() {
        super.setUp()
        testSubdirectory = "com.medialite.tests.storage.\(UUID().uuidString)"
        tempManager = TempFileManager(tempSubdirectoryName: testSubdirectory)
        generatedURLs = []

        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults.removePersistentDomain(forName: suiteName)

        let historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        historyFileURL = historyDir.appendingPathComponent("compression_history.json")
        generatedURLs.append(historyDir)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        SyntheticAssetGenerator.cleanup(urls: generatedURLs)
        generatedURLs.removeAll()
        try? tempManager.purgeAllTempFiles()
        try? FileManager.default.removeItem(at: tempManager.baseDirectory)
        tempManager = nil
        testSubdirectory = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeHistoryItem(
        id: UUID = UUID(),
        fileName: String,
        mediaType: String,
        sourceFormat: String,
        targetFormat: String,
        origSize: Int64,
        compSize: Int64,
        strength: CompressionStrength = .medium,
        duration: Double? = nil
    ) -> CompressionHistoryItem {
        CompressionHistoryItem(
            id: id,
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

    // MARK: - 1. Multi-Session History Aggregation & Lifetime Savings

    func testStorageRecoveryMultiSessionHistoryAggregation() async throws {
        let store = HistoryStorageService(fileURL: historyFileURL)

        // Session 1 (Morning): 3 photo compressions
        let session1Items = [
            makeHistoryItem(fileName: "beach.jpg", mediaType: "photo", sourceFormat: "jpg", targetFormat: "jpg", origSize: 8_000_000, compSize: 2_500_000),
            makeHistoryItem(fileName: "sunset.heic", mediaType: "photo", sourceFormat: "heic", targetFormat: "heic", origSize: 12_000_000, compSize: 4_200_000),
            makeHistoryItem(fileName: "trail.jpg", mediaType: "photo", sourceFormat: "jpg", targetFormat: "jpg", origSize: 6_000_000, compSize: 1_800_000)
        ]
        for item in session1Items {
            try await store.addItem(item)
        }

        // Session 2 (Afternoon): 2 video conversions
        let session2Items = [
            makeHistoryItem(fileName: "drone_4k.mov", mediaType: "video", sourceFormat: "mov", targetFormat: "mp4", origSize: 85_000_000, compSize: 25_000_000, strength: .high, duration: 30.0),
            makeHistoryItem(fileName: "family_hdr.mov", mediaType: "video", sourceFormat: "mov", targetFormat: "mp4", origSize: 140_000_000, compSize: 42_000_000, strength: .medium, duration: 45.0)
        ]
        for item in session2Items {
            try await store.addItem(item)
        }

        // Session 3 (Evening): 2 screenshots (PNG) and 1 screen recording (MP4)
        let session3Items = [
            makeHistoryItem(fileName: "receipt.png", mediaType: "photo", sourceFormat: "png", targetFormat: "png", origSize: 4_000_000, compSize: 1_200_000, strength: .low),
            makeHistoryItem(fileName: "diagram.png", mediaType: "photo", sourceFormat: "png", targetFormat: "png", origSize: 5_000_000, compSize: 1_500_000, strength: .medium),
            makeHistoryItem(fileName: "demo.mp4", mediaType: "video", sourceFormat: "mp4", targetFormat: "mp4", origSize: 35_000_000, compSize: 12_000_000, strength: .high, duration: 15.0)
        ]
        for item in session3Items {
            try await store.addItem(item)
        }

        // Simulate app restart: re-instantiate store from disk
        let persistentStore = HistoryStorageService(fileURL: historyFileURL)
        let allItems = try await persistentStore.loadHistory()
        XCTAssertEqual(allItems.count, 8, "Store must contain all 8 items across 3 sessions")

        // Calculate lifetime storage recovery stats
        let totalOriginalBytes = allItems.reduce(Int64(0)) { $0 + $1.originalByteSize }
        let totalCompressedBytes = allItems.reduce(Int64(0)) { $0 + $1.compressedByteSize }
        let lifetimeSavings = totalOriginalBytes - totalCompressedBytes
        let expectedSumOfDeltas = allItems.reduce(Int64(0)) { $0 + $1.byteDelta }

        XCTAssertEqual(totalOriginalBytes, 295_000_000, "Total original bytes must equal 295 MB")
        XCTAssertEqual(totalCompressedBytes, 90_200_000, "Total compressed bytes must equal 90.2 MB")
        XCTAssertEqual(lifetimeSavings, 204_800_000, "Lifetime savings must equal 204.8 MB")
        XCTAssertEqual(lifetimeSavings, expectedSumOfDeltas)

        let overallReductionPercentage = (Double(lifetimeSavings) / Double(totalOriginalBytes)) * 100.0
        XCTAssertEqual(overallReductionPercentage, 69.42, accuracy: 0.1, "Overall reduction must be ~69.4%")

        // Verify UI Formatter presentation
        let summaryString = Formatters.formatSavingsSummary(
            originalSize: totalOriginalBytes,
            compressedSize: totalCompressedBytes
        )
        XCTAssertTrue(summaryString.contains("Saved"))
        let formattedSavings = Formatters.formatBytes(lifetimeSavings)
        XCTAssertFalse(formattedSavings.isEmpty)
    }

    // MARK: - 2. Category Filtering (All vs Photos vs Videos)

    func testHistoryCategoryFilteringPhotosVsVideos() async throws {
        let store = HistoryStorageService(fileURL: historyFileURL)

        // Seed 5 photos and 3 videos
        let photoItems = [
            makeHistoryItem(fileName: "p1.jpg", mediaType: "photo", sourceFormat: "jpg", targetFormat: "jpg", origSize: 10_000_000, compSize: 3_000_000),
            makeHistoryItem(fileName: "p2.heic", mediaType: "photo", sourceFormat: "heic", targetFormat: "heic", origSize: 8_000_000, compSize: 2_500_000),
            makeHistoryItem(fileName: "p3.png", mediaType: "photo", sourceFormat: "png", targetFormat: "png", origSize: 5_000_000, compSize: 1_500_000),
            makeHistoryItem(fileName: "p4.jpg", mediaType: "photo", sourceFormat: "jpg", targetFormat: "jpg", origSize: 7_000_000, compSize: 2_200_000),
            makeHistoryItem(fileName: "p5.heic", mediaType: "photo", sourceFormat: "heic", targetFormat: "heic", origSize: 5_000_000, compSize: 2_000_000)
        ]
        let videoItems = [
            makeHistoryItem(fileName: "v1.mov", mediaType: "video", sourceFormat: "mov", targetFormat: "mp4", origSize: 100_000_000, compSize: 30_000_000, duration: 20.0),
            makeHistoryItem(fileName: "v2.mp4", mediaType: "video", sourceFormat: "mp4", targetFormat: "mp4", origSize: 80_000_000, compSize: 24_000_000, duration: 18.0),
            makeHistoryItem(fileName: "v3.mov", mediaType: "video", sourceFormat: "mov", targetFormat: "mp4", origSize: 80_000_000, compSize: 25_000_000, duration: 25.0)
        ]

        for item in photoItems + videoItems {
            try await store.addItem(item)
        }

        let allRecords = try await store.loadHistory()
        XCTAssertEqual(allRecords.count, 8)

        // Filter 1: "All"
        let allCategory = allRecords
        XCTAssertEqual(allCategory.count, 8)

        // Filter 2: "Photos"
        let photosCategory = allRecords.filter { $0.mediaType == "photo" }
        XCTAssertEqual(photosCategory.count, 5, "Photos filter must return exactly 5 items")
        for item in photosCategory {
            XCTAssertEqual(item.mediaType, "photo")
        }
        let photoSavings = photosCategory.reduce(Int64(0)) { $0 + $1.byteDelta }
        XCTAssertEqual(photoSavings, 23_800_000, "Photo savings must equal 23.8 MB")

        // Filter 3: "Videos"
        let videosCategory = allRecords.filter { $0.mediaType == "video" }
        XCTAssertEqual(videosCategory.count, 3, "Videos filter must return exactly 3 items")
        for item in videosCategory {
            XCTAssertEqual(item.mediaType, "video")
            XCTAssertNotNil(item.durationSeconds)
        }
        let videoSavings = videosCategory.reduce(Int64(0)) { $0 + $1.byteDelta }
        XCTAssertEqual(videoSavings, 181_000_000, "Video savings must equal 181 MB")

        // Category Math Invariant
        let totalSavings = allRecords.reduce(Int64(0)) { $0 + $1.byteDelta }
        XCTAssertEqual(photoSavings + videoSavings, totalSavings, "Category savings must exactly sum to total lifetime savings")
    }

    // MARK: - 3. Item Deletion and Clear-All Purge

    func testHistoryBatchItemDeletionAndClearAllPurge() async throws {
        let store = HistoryStorageService(fileURL: historyFileURL)

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let id4 = UUID()
        let id5 = UUID()

        let items = [
            makeHistoryItem(id: id1, fileName: "item1.jpg", mediaType: "photo", sourceFormat: "jpg", targetFormat: "jpg", origSize: 5_000_000, compSize: 2_000_000),
            makeHistoryItem(id: id2, fileName: "item2.mov", mediaType: "video", sourceFormat: "mov", targetFormat: "mp4", origSize: 40_000_000, compSize: 10_000_000),
            makeHistoryItem(id: id3, fileName: "item3.heic", mediaType: "photo", sourceFormat: "heic", targetFormat: "heic", origSize: 8_000_000, compSize: 3_000_000),
            makeHistoryItem(id: id4, fileName: "item4.png", mediaType: "photo", sourceFormat: "png", targetFormat: "png", origSize: 3_000_000, compSize: 1_000_000),
            makeHistoryItem(id: id5, fileName: "item5.mp4", mediaType: "video", sourceFormat: "mp4", targetFormat: "mp4", origSize: 20_000_000, compSize: 6_000_000)
        ]

        for item in items {
            try await store.addItem(item)
        }

        // Phase 1: Individual Item Deletion (delete id1 and id2)
        try await store.deleteItem(id: id1)
        try await store.deleteItem(id: id2)

        // Re-read from a fresh instance to ensure disk file was updated atomically
        let freshStore = HistoryStorageService(fileURL: historyFileURL)
        var remainingItems = try await freshStore.loadHistory()
        XCTAssertEqual(remainingItems.count, 3, "Remaining count must be 3 after deleting 2 items")

        let remainingIDs = Set(remainingItems.map { $0.id })
        XCTAssertFalse(remainingIDs.contains(id1), "Deleted item id1 must be absent")
        XCTAssertFalse(remainingIDs.contains(id2), "Deleted item id2 must be absent")
        XCTAssertTrue(remainingIDs.contains(id3))
        XCTAssertTrue(remainingIDs.contains(id4))
        XCTAssertTrue(remainingIDs.contains(id5))

        // Phase 2: Clear-All History Purge
        try await freshStore.clearAllHistory()

        let clearedStore = HistoryStorageService(fileURL: historyFileURL)
        remainingItems = try await clearedStore.loadHistory()
        XCTAssertTrue(remainingItems.isEmpty, "History must be completely empty after clearAllHistory")

        let totalSavingsAfterClear = remainingItems.reduce(Int64(0)) { $0 + $1.byteDelta }
        XCTAssertEqual(totalSavingsAfterClear, 0)
    }

    // MARK: - 4. Temporary Cache Storage Inspection and Full Purge

    func testTempStorageCacheInspectionAndFullPurge() throws {
        // Create 6 temporary assets simulating scratch and export files
        var testURLs: [URL] = []
        for i in 0..<6 {
            let url = tempManager.createTempFileURL(extension: "tmp")
            let payload = "Temporary file data payload \(i) for storage test".data(using: .utf8)!
            try payload.write(to: url)
            testURLs.append(url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }

        // Verify disk storage query capability
        let availableSpace = tempManager.getAvailableDiskSpace()
        XCTAssertNotNil(availableSpace, "Disk space query must return available bytes")
        if let bytes = availableSpace {
            XCTAssertGreaterThan(bytes, 0, "Available space must be positive")
        }

        // Verify sandbox directory contains files
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: tempManager.baseDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(directoryContents.count, 6)

        // Execute purge of all temp files
        let purgedCount = try tempManager.purgeAllTempFiles()
        XCTAssertEqual(purgedCount, 6, "purgeAllTempFiles must remove all 6 temporary files")

        // Verify base directory is now empty
        let remainingContents = try FileManager.default.contentsOfDirectory(
            at: tempManager.baseDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remainingContents.isEmpty, "Temporary cache must be completely empty after purge")

        // Re-purging empty directory should not throw or fail
        XCTAssertNoThrow(try tempManager.purgeAllTempFiles())
    }

    // MARK: - 5. AppSettings Lifecycle & Cold-Start Simulation

    func testAppSettingsLifecycleAndColdStartSimulation() {
        // Phase 1: Factory Defaults Verification
        let initialSettings = AppSettings.load(from: testDefaults)
        XCTAssertEqual(initialSettings.defaultCompressionStrength, .medium)
        XCTAssertEqual(initialSettings.defaultVideoMode, .reduceSize)
        XCTAssertFalse(initialSettings.autoSaveToLibrary)
        XCTAssertTrue(initialSettings.preserveMetadata)
        XCTAssertFalse(initialSettings.deleteOriginalPrompt)
        XCTAssertEqual(initialSettings.maxCacheAgeDays, 7)

        // Phase 2: User Preferences Mutation in Settings Screen
        var mutatedSettings = AppSettings()
        mutatedSettings.defaultCompressionStrength = .high
        mutatedSettings.defaultVideoMode = .compressAndConvert
        mutatedSettings.autoSaveToLibrary = true
        mutatedSettings.preserveMetadata = false
        mutatedSettings.deleteOriginalPrompt = true
        mutatedSettings.maxCacheAgeDays = 3

        // Save to persistent UserDefaults store
        mutatedSettings.save(to: testDefaults)

        // Phase 3: Cold-Start Simulation (re-initialize clean instance from UserDefaults)
        let coldStartSettings = AppSettings.load(from: testDefaults)
        XCTAssertEqual(coldStartSettings.defaultCompressionStrength, .high, "Mutated HIGH strength must survive cold start")
        XCTAssertEqual(coldStartSettings.defaultVideoMode, .compressAndConvert, "Mutated compressAndConvert mode must survive cold start")
        XCTAssertTrue(coldStartSettings.autoSaveToLibrary, "autoSaveToLibrary must survive cold start")
        XCTAssertFalse(coldStartSettings.preserveMetadata, "preserveMetadata mutation must survive cold start")
        XCTAssertTrue(coldStartSettings.deleteOriginalPrompt, "deleteOriginalPrompt must survive cold start")
        XCTAssertEqual(coldStartSettings.maxCacheAgeDays, 3, "maxCacheAgeDays must survive cold start")

        // Phase 4: Downstream Workflow Honoring Persisted Settings
        // Compression workflow retrieves persisted default quality:
        let activeStrength = coldStartSettings.defaultCompressionStrength
        XCTAssertEqual(activeStrength, .high)
        XCTAssertEqual(activeStrength.lossyQuality, 0.55, "Downstream workflow must apply 0.55 quality factor for HIGH")
        XCTAssertEqual(activeStrength.dimensionScale, 0.74, "Downstream workflow must apply 0.74 scale for HIGH")

        // Video workflow retrieves persisted default mode:
        let activeVideoMode = coldStartSettings.defaultVideoMode
        XCTAssertEqual(activeVideoMode, .compressAndConvert, "Downstream video workflow must default to compressAndConvert")

        // Phase 5: Reset to Factory Defaults
        let resetSettings = AppSettings.reset(userDefaults: testDefaults)
        XCTAssertEqual(resetSettings, AppSettings.default)

        // Verify cold-start after reset returns factory defaults
        let afterResetColdStart = AppSettings.load(from: testDefaults)
        XCTAssertEqual(afterResetColdStart.defaultCompressionStrength, .medium)
        XCTAssertEqual(afterResetColdStart.defaultVideoMode, .reduceSize)
        XCTAssertFalse(afterResetColdStart.autoSaveToLibrary)
        XCTAssertTrue(afterResetColdStart.preserveMetadata)
        XCTAssertFalse(afterResetColdStart.deleteOriginalPrompt)
        XCTAssertEqual(afterResetColdStart.maxCacheAgeDays, 7)
    }

    // MARK: - 6. AppSettings Corrupted Key Recovery

    func testAppSettingsCorruptedStoreResilience() {
        // Inject invalid raw strings and negative cache age
        testDefaults.set("CORRUPTED_VALUE", forKey: AppSettings.Keys.defaultCompressionStrength)
        testDefaults.set("NON_EXISTENT_MODE", forKey: AppSettings.Keys.defaultVideoMode)
        testDefaults.set(-99, forKey: AppSettings.Keys.maxCacheAgeDays)

        let loaded = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loaded.defaultCompressionStrength, .medium, "Must fall back safely to MEDIUM")
        XCTAssertEqual(loaded.defaultVideoMode, .reduceSize, "Must fall back safely to reduceSize")
        XCTAssertEqual(loaded.maxCacheAgeDays, 7, "Negative cache age must fall back to 7 days")
    }
}
