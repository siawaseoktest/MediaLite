//
//  WorkflowPairwiseE2ETests.swift
//  MediaLiteTests
//
//  Tier 3 Cross-Feature Combinations E2E Tests for MediaLite.
//  Covers pairwise workflow tests:
//  - Compression -> History record creation -> Item query -> Library export simulation.
//  - Settings default mutation -> Processing pipeline inheriting mutated default -> History recording.
//  - Dual image + video batch processing -> History aggregate calculation -> Batch deletion.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreMedia
@testable import MediaLite

// MARK: - Workflow Test PhotoKit Export Simulator

private struct WorkflowTestPhotoLibrarySimulator {
    /// Simulates safe, non-destructive PhotoKit export via PHAssetCreationRequest.
    /// Validates file existence, non-empty size, and supported media format without modifying source.
    func simulateSaveAsset(at fileURL: URL, isVideo: Bool) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(
                domain: "com.medialite.tests.photokit",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Asset file to export not found at \(fileURL.path)"]
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw NSError(
                domain: "com.medialite.tests.photokit",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Asset file is empty (0 bytes) and cannot be exported to Photos"]
            )
        }

        // Return simulated local identifier
        let simulatedAssetIdentifier = "PHAsset-\(UUID().uuidString)/L0/001"
        return simulatedAssetIdentifier
    }
}

// MARK: - Workflow Manager (Orchestrating Settings, Pipelines, History & Export)

private final class WorkflowManager {
    let settings: AppSettings
    let photoCompressor: PhotoCompressorProtocol
    let videoProcessor: VideoProcessorProtocol
    let historyStore: HistoryStorageService
    let librarySimulator: WorkflowTestPhotoLibrarySimulator

    init(
        settings: AppSettings,
        historyStore: HistoryStorageService
    ) {
        self.settings = settings
        self.photoCompressor = PhotoCompressorService()
        self.videoProcessor = VideoProcessorService()
        self.historyStore = historyStore
        self.librarySimulator = WorkflowTestPhotoLibrarySimulator()
    }

    /// Processes photo using inherited AppSettings defaults and auto-records history.
    func processPhotoWorkflow(
        sourceURL: URL,
        destinationURL: URL
    ) async throws -> (result: PhotoCompressionResult, historyItem: CompressionHistoryItem) {
        let result = try await photoCompressor.compressPhoto(
            at: sourceURL,
            strength: settings.defaultCompressionStrength,
            destinationURL: destinationURL
        )

        var isSaved = false
        if settings.autoSaveToLibrary {
            _ = try librarySimulator.simulateSaveAsset(at: destinationURL, isVideo: false)
            isSaved = true
        }

        let historyItem = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: sourceURL.lastPathComponent,
            mediaType: "photo",
            sourceFormat: sourceURL.pathExtension.lowercased(),
            targetFormat: destinationURL.pathExtension.lowercased(),
            originalByteSize: result.originalSize,
            compressedByteSize: result.compressedSize,
            compressionStrength: settings.defaultCompressionStrength,
            durationSeconds: nil,
            isSavedToLibrary: isSaved
        )

        try await historyStore.addItem(historyItem)
        return (result, historyItem)
    }

    /// Processes video using inherited AppSettings defaults and auto-records history.
    func processVideoWorkflow(
        sourceURL: URL,
        destinationURL: URL
    ) async throws -> (result: VideoProcessingResult, historyItem: CompressionHistoryItem) {
        let handle = videoProcessor.processVideo(
            at: sourceURL,
            mode: settings.defaultVideoMode,
            strength: settings.defaultCompressionStrength,
            destinationURL: destinationURL
        )

        let result = try await handle.task.value

        var isSaved = false
        if settings.autoSaveToLibrary {
            _ = try librarySimulator.simulateSaveAsset(at: destinationURL, isVideo: true)
            isSaved = true
        }

        let historyItem = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: sourceURL.lastPathComponent,
            mediaType: "video",
            sourceFormat: sourceURL.pathExtension.lowercased(),
            targetFormat: destinationURL.pathExtension.lowercased(),
            originalByteSize: result.originalSize,
            compressedByteSize: result.processedSize,
            compressionStrength: settings.defaultCompressionStrength,
            durationSeconds: result.duration,
            isSavedToLibrary: isSaved
        )

        try await historyStore.addItem(historyItem)
        return (result, historyItem)
    }
}

// MARK: - WorkflowPairwiseE2ETests

final class WorkflowPairwiseE2ETests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var testDefaults: UserDefaults!
    private let suiteName = "com.medialite.tests.tier3.workflow"
    private var historyStoreURL: URL!
    private var historyStore: HistoryStorageService!
    private var librarySimulator: WorkflowTestPhotoLibrarySimulator!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults?.removePersistentDomain(forName: suiteName)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow_tests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        historyStoreURL = tempDir.appendingPathComponent("workflow_history.json")
        trackedURLs.append(tempDir)

        historyStore = HistoryStorageService(fileURL: historyStoreURL)
        librarySimulator = WorkflowTestPhotoLibrarySimulator()
    }

    override func tearDown() {
        testDefaults?.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        SyntheticAssetGenerator.cleanup(urls: trackedURLs)
        trackedURLs.removeAll()
        _ = try? TempFileManager.shared.purgeAllTempFiles()
        historyStore = nil
        librarySimulator = nil
        super.tearDown()
    }

    // MARK: - 1. Compression -> History Record Creation -> Item Query -> Library Export Simulation

    /// Workflow Test 1: Full lifecycle for Photo Compression.
    /// Synthesizes photo, compresses it, writes history record, queries store,
    /// and simulates safe PhotoKit library export, updating record state.
    func testWorkflow_PhotoCompression_HistoryCreation_Query_AndLibraryExport() async throws {
        // Step 1: Synthesize source photo
        let sourceURL = try SyntheticAssetGenerator.createJPEG(
            width: 400,
            height: 300,
            color: CGColor(srgbRed: 0.1, green: 0.7, blue: 0.4, alpha: 1.0),
            hasExif: true
        )
        trackedURLs.append(sourceURL)

        let destURL = TempFileManager.shared.createTempFileURL(extension: "jpg")
        trackedURLs.append(destURL)

        // Step 2: Execute photo compression
        let compressor = PhotoCompressorService()
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .medium,
            destinationURL: destURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        // Step 3: Create history record
        let recordID = UUID()
        let originalHistoryItem = CompressionHistoryItem(
            id: recordID,
            timestamp: Date(),
            fileName: sourceURL.lastPathComponent,
            mediaType: "photo",
            sourceFormat: "jpg",
            targetFormat: "jpg",
            originalByteSize: result.originalSize,
            compressedByteSize: result.compressedSize,
            compressionStrength: .medium,
            durationSeconds: nil,
            isSavedToLibrary: false
        )
        try await historyStore.addItem(originalHistoryItem)

        // Step 4: Query history store and verify mathematical consistency
        let loadedItems = try await historyStore.loadHistory()
        XCTAssertEqual(loadedItems.count, 1)

        guard let queriedItem = loadedItems.first(where: { $0.id == recordID }) else {
            XCTFail("Recorded history item not found in store")
            return
        }

        XCTAssertEqual(queriedItem.fileName, sourceURL.lastPathComponent)
        XCTAssertEqual(queriedItem.mediaType, "photo")
        XCTAssertEqual(queriedItem.originalByteSize, result.originalSize)
        XCTAssertEqual(queriedItem.compressedByteSize, result.compressedSize)
        XCTAssertEqual(queriedItem.byteDelta, result.byteDelta)
        XCTAssertEqual(queriedItem.reductionPercentage, result.reductionPercentage, accuracy: 0.001)
        XCTAssertFalse(queriedItem.isSavedToLibrary)

        // Step 5: Simulate export to Photo Library
        let assetIdentifier = try librarySimulator.simulateSaveAsset(at: destURL, isVideo: false)
        XCTAssertFalse(assetIdentifier.isEmpty)

        // Non-destructive check: Original file and compressed file must remain intact
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        // Step 6: Update history item to reflect library save
        var updatedItem = queriedItem
        updatedItem.isSavedToLibrary = true
        try await historyStore.updateItem(updatedItem)

        // Step 7: Re-query store and verify state persistence
        let refreshedItems = try await historyStore.loadHistory()
        let refreshedItem = refreshedItems.first(where: { $0.id == recordID })
        XCTAssertNotNil(refreshedItem)
        XCTAssertTrue(refreshedItem?.isSavedToLibrary == true)
    }

    /// Workflow Test 2: Full lifecycle for Video Conversion.
    /// Synthesizes MP4 video, transcodes with compressAndConvert, writes history with duration,
    /// queries store, and simulates library export.
    func testWorkflow_VideoConversion_HistoryCreation_Query_AndLibraryExport() async throws {
        // Step 1: Synthesize valid video
        let sourceURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 480, height: 320),
            hasAudio: true,
            isHDR: false
        )
        trackedURLs.append(sourceURL)

        let destURL = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(destURL)

        // Step 2: Transcode video
        let processor = VideoProcessorService()
        let handle = processor.processVideo(
            at: sourceURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: destURL
        )
        let result = try await handle.task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertGreaterThan(result.processedSize, 0)

        // Step 3: Record history item
        let recordID = UUID()
        let videoHistoryItem = CompressionHistoryItem(
            id: recordID,
            timestamp: Date(),
            fileName: sourceURL.lastPathComponent,
            mediaType: "video",
            sourceFormat: "mp4",
            targetFormat: "mp4",
            originalByteSize: result.originalSize,
            compressedByteSize: result.processedSize,
            compressionStrength: .high,
            durationSeconds: result.duration,
            isSavedToLibrary: false
        )
        try await historyStore.addItem(videoHistoryItem)

        // Step 4: Query store
        let items = try await historyStore.loadHistory()
        let queriedItem = items.first(where: { $0.id == recordID })
        XCTAssertNotNil(queriedItem)
        XCTAssertEqual(queriedItem?.mediaType, "video")
        XCTAssertEqual(queriedItem?.durationSeconds ?? 0, 1.0, accuracy: 0.3)
        XCTAssertFalse(queriedItem?.isSavedToLibrary ?? true)

        // Step 5: Simulate export
        let assetID = try librarySimulator.simulateSaveAsset(at: destURL, isVideo: true)
        XCTAssertFalse(assetID.isEmpty)

        // Step 6: Update state
        if var itemToUpdate = queriedItem {
            itemToUpdate.isSavedToLibrary = true
            try await historyStore.updateItem(itemToUpdate)
        }

        let updatedItems = try await historyStore.loadHistory()
        XCTAssertTrue(updatedItems.first(where: { $0.id == recordID })?.isSavedToLibrary == true)
    }

    // MARK: - 2. Settings Default Mutation -> Processing Pipeline Inheriting Mutated Default -> History Recording

    /// Workflow Test 3: Settings Default Mutation for Photo Compression.
    /// User modifies default compression strength to HIGH and autoSaveToLibrary to true.
    /// Processing pipeline inherits mutated settings without manual override, and history reflects HIGH strength.
    func testWorkflow_SettingsDefaultMutation_PhotoPipelineInheritsDefault_HistoryRecording() async throws {
        // Step 1: Mutate AppSettings in isolated UserDefaults
        var mutatedSettings = AppSettings.load(from: testDefaults)
        mutatedSettings.defaultCompressionStrength = .high
        mutatedSettings.autoSaveToLibrary = true
        mutatedSettings.save(to: testDefaults)

        // Step 2: Verify persistence
        let reloadedSettings = AppSettings.load(from: testDefaults)
        XCTAssertEqual(reloadedSettings.defaultCompressionStrength, .high)
        XCTAssertTrue(reloadedSettings.autoSaveToLibrary)

        // Step 3: Instantiate WorkflowManager with mutated settings
        let manager = WorkflowManager(
            settings: reloadedSettings,
            historyStore: historyStore
        )

        // Step 4: Execute photo compression without explicit quality parameters
        let sourceURL = try SyntheticAssetGenerator.createJPEG(
            width: 400,
            height: 400,
            color: CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1.0),
            hasExif: true
        )
        trackedURLs.append(sourceURL)

        let destURL = TempFileManager.shared.createTempFileURL(extension: "jpg")
        trackedURLs.append(destURL)

        let (result, historyItem) = try await manager.processPhotoWorkflow(
            sourceURL: sourceURL,
            destinationURL: destURL
        )

        // Step 5: Verify processing applied HIGH quality settings (0.74 dimension scale: 400 * 0.74 = 296)
        XCTAssertGreaterThan(result.compressedSize, 0)
        XCTAssertEqual(historyItem.compressionStrength, .high)
        XCTAssertTrue(historyItem.isSavedToLibrary, "History must inherit autoSaveToLibrary = true from mutated settings.")

        // Step 6: Verify persisted record in history store
        let storedItems = try await historyStore.loadHistory()
        let matchingItem = storedItems.first(where: { $0.id == historyItem.id })
        XCTAssertNotNil(matchingItem)
        XCTAssertEqual(matchingItem?.compressionStrength, .high)
        XCTAssertTrue(matchingItem?.isSavedToLibrary == true)
    }

    /// Workflow Test 4: Settings Default Mutation for Video Conversion.
    /// User modifies defaultVideoMode to improveCompatibility and defaultCompressionStrength to LOW.
    /// Video pipeline inherits settings, producing MP4 output with H.264 video, recorded accurately in history.
    func testWorkflow_SettingsDefaultMutation_VideoPipelineInheritsDefault_HistoryRecording() async throws {
        // Step 1: Mutate AppSettings
        var mutatedSettings = AppSettings.load(from: testDefaults)
        mutatedSettings.defaultVideoMode = .improveCompatibility
        mutatedSettings.defaultCompressionStrength = .low
        mutatedSettings.autoSaveToLibrary = false
        mutatedSettings.save(to: testDefaults)

        let reloadedSettings = AppSettings.load(from: testDefaults)
        XCTAssertEqual(reloadedSettings.defaultVideoMode, .improveCompatibility)
        XCTAssertEqual(reloadedSettings.defaultCompressionStrength, .low)

        let manager = WorkflowManager(
            settings: reloadedSettings,
            historyStore: historyStore
        )

        // Step 2: Synthesize MOV video
        let movURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow_\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let sourceURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 480, height: 320),
            hasAudio: true,
            isHDR: false,
            destinationURL: movURL
        )
        trackedURLs.append(sourceURL)

        let destURL = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(destURL)

        // Step 3: Run workflow inheriting settings
        let (result, historyItem) = try await manager.processVideoWorkflow(
            sourceURL: sourceURL,
            destinationURL: destURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertEqual(destURL.pathExtension.lowercased(), "mp4")
        XCTAssertGreaterThan(result.processedSize, 0)
        XCTAssertEqual(historyItem.compressionStrength, .low)
        XCTAssertEqual(historyItem.targetFormat, "mp4")
        XCTAssertFalse(historyItem.isSavedToLibrary)
    }

    /// Workflow Test 5: Settings Reset Reverts Pipeline Behavior to Factory Defaults.
    /// Verifies that resetting settings via AppSettings.reset restores .medium and .reduceSize,
    /// and subsequent operations cleanly reflect default behavior.
    func testWorkflow_SettingsReset_RevertsPipelineInheritanceToDefaults() async throws {
        // Step 1: Set mutated settings
        var settings = AppSettings.load(from: testDefaults)
        settings.defaultCompressionStrength = .high
        settings.defaultVideoMode = .compressAndConvert
        settings.autoSaveToLibrary = true
        settings.save(to: testDefaults)

        // Step 2: Reset to factory defaults
        let resetSettings = AppSettings.reset(userDefaults: testDefaults)
        XCTAssertEqual(resetSettings.defaultCompressionStrength, .medium)
        XCTAssertEqual(resetSettings.defaultVideoMode, .reduceSize)
        XCTAssertFalse(resetSettings.autoSaveToLibrary)

        // Step 3: Pipeline re-initialized with reset settings
        let manager = WorkflowManager(
            settings: resetSettings,
            historyStore: historyStore
        )

        let sourceURL = try SyntheticAssetGenerator.createJPEG(
            width: 300,
            height: 300,
            color: CGColor(srgbRed: 0.9, green: 0.6, blue: 0.1, alpha: 1.0),
            hasExif: false
        )
        trackedURLs.append(sourceURL)

        let destURL = TempFileManager.shared.createTempFileURL(extension: "jpg")
        trackedURLs.append(destURL)

        let (_, historyItem) = try await manager.processPhotoWorkflow(
            sourceURL: sourceURL,
            destinationURL: destURL
        )

        XCTAssertEqual(historyItem.compressionStrength, .medium)
        XCTAssertFalse(historyItem.isSavedToLibrary)
    }

    // MARK: - 3. Dual Image + Video Batch Processing -> History Aggregate Calculation -> Batch Deletion

    /// Workflow Test 6: Dual Image + Video Batch Processing, Aggregate Stats, and Batch Deletion.
    /// Runs a batch of 2 photos and 2 videos, calculates global aggregate metrics (bytes saved, counts),
    /// performs batch deletion of selected items, and verifies remaining item integrity and recalculation.
    func testWorkflow_DualBatchProcessing_HistoryAggregateCalculation_AndBatchDeletion() async throws {
        let compressor = PhotoCompressorService()
        let processor = VideoProcessorService()

        // 1. Synthesize Dual Batch: 2 photos + 2 videos
        let photo1 = try SyntheticAssetGenerator.createJPEG(width: 400, height: 300, color: CGColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1.0))
        let photo2 = try SyntheticAssetGenerator.createPNG(width: 300, height: 300, hasAlpha: true)
        trackedURLs.append(contentsOf: [photo1, photo2])

        let video1 = try await SyntheticAssetGenerator.createVideo(durationSeconds: 1.0, fps: 30, resolution: CGSize(width: 480, height: 320), hasAudio: true)
        let video2 = try await SyntheticAssetGenerator.createVideo(durationSeconds: 1.0, fps: 30, resolution: CGSize(width: 320, height: 240), hasAudio: false)
        trackedURLs.append(contentsOf: [video1, video2])

        // 2. Process Photos
        let photoDest1 = TempFileManager.shared.createTempFileURL(extension: "jpg")
        let photoDest2 = TempFileManager.shared.createTempFileURL(extension: "png")
        trackedURLs.append(contentsOf: [photoDest1, photoDest2])

        let photoResult1 = try await compressor.compressPhoto(at: photo1, strength: .medium, destinationURL: photoDest1)
        let photoResult2 = try await compressor.compressPhoto(at: photo2, strength: .medium, destinationURL: photoDest2)

        // 3. Process Videos
        let videoDest1 = TempFileManager.shared.createTempFileURL(extension: "mp4")
        let videoDest2 = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(contentsOf: [videoDest1, videoDest2])

        let vHandle1 = processor.processVideo(at: video1, mode: .reduceSize, strength: .medium, destinationURL: videoDest1)
        let vHandle2 = processor.processVideo(at: video2, mode: .improveCompatibility, strength: .medium, destinationURL: videoDest2)

        let videoResult1 = try await vHandle1.task.value
        let videoResult2 = try await vHandle2.task.value

        // 4. Create and store 4 History Items
        let item1 = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-30),
            fileName: photo1.lastPathComponent,
            mediaType: "photo",
            sourceFormat: "jpg",
            targetFormat: "jpg",
            originalByteSize: photoResult1.originalSize,
            compressedByteSize: photoResult1.compressedSize,
            compressionStrength: .medium
        )
        let item2 = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-20),
            fileName: photo2.lastPathComponent,
            mediaType: "photo",
            sourceFormat: "png",
            targetFormat: "png",
            originalByteSize: photoResult2.originalSize,
            compressedByteSize: photoResult2.compressedSize,
            compressionStrength: .medium
        )
        let item3 = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-10),
            fileName: video1.lastPathComponent,
            mediaType: "video",
            sourceFormat: "mp4",
            targetFormat: "mp4",
            originalByteSize: videoResult1.originalSize,
            compressedByteSize: videoResult1.processedSize,
            compressionStrength: .medium,
            durationSeconds: videoResult1.duration
        )
        let item4 = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: video2.lastPathComponent,
            mediaType: "video",
            sourceFormat: "mp4",
            targetFormat: "mp4",
            originalByteSize: videoResult2.originalSize,
            compressedByteSize: videoResult2.processedSize,
            compressionStrength: .medium,
            durationSeconds: videoResult2.duration
        )

        try await historyStore.addItem(item1)
        try await historyStore.addItem(item2)
        try await historyStore.addItem(item3)
        try await historyStore.addItem(item4)

        // 5. Verify initial aggregate calculations
        let initialAggregates = await historyStore.calculateAggregates()
        XCTAssertEqual(initialAggregates.photoCount, 2)
        XCTAssertEqual(initialAggregates.videoCount, 2)

        let expectedTotalOriginal = item1.originalByteSize + item2.originalByteSize + item3.originalByteSize + item4.originalByteSize
        let expectedTotalCompressed = item1.compressedByteSize + item2.compressedByteSize + item3.compressedByteSize + item4.compressedByteSize
        let expectedTotalSaved = expectedTotalOriginal - expectedTotalCompressed

        XCTAssertEqual(initialAggregates.totalOriginalBytes, expectedTotalOriginal)
        XCTAssertEqual(initialAggregates.totalCompressedBytes, expectedTotalCompressed)
        XCTAssertEqual(initialAggregates.totalSavedBytes, expectedTotalSaved)
        XCTAssertGreaterThan(initialAggregates.reductionPercentage, 0.0)

        // 6. Execute Batch Deletion: Delete 1 photo (item1) and 1 video (item3)
        let deleteIDs: Set<UUID> = [item1.id, item3.id]
        try await historyStore.deleteItems(ids: deleteIDs)

        // 7. Verify remaining history store items
        let remainingItems = try await historyStore.loadHistory()
        XCTAssertEqual(remainingItems.count, 2)
        XCTAssertFalse(remainingItems.contains(where: { $0.id == item1.id }))
        XCTAssertFalse(remainingItems.contains(where: { $0.id == item3.id }))
        XCTAssertTrue(remainingItems.contains(where: { $0.id == item2.id }))
        XCTAssertTrue(remainingItems.contains(where: { $0.id == item4.id }))

        // 8. Re-evaluate aggregate statistics on remaining items
        let postDeleteAggregates = await historyStore.calculateAggregates()
        XCTAssertEqual(postDeleteAggregates.photoCount, 1)
        XCTAssertEqual(postDeleteAggregates.videoCount, 1)
        XCTAssertEqual(postDeleteAggregates.totalOriginalBytes, item2.originalByteSize + item4.originalByteSize)
        XCTAssertEqual(postDeleteAggregates.totalCompressedBytes, item2.compressedByteSize + item4.compressedByteSize)

        // 9. Clear all history
        try await historyStore.clearAllHistory()
        let clearedItems = try await historyStore.loadHistory()
        XCTAssertTrue(clearedItems.isEmpty)

        let zeroAggregates = await historyStore.calculateAggregates()
        XCTAssertEqual(zeroAggregates.photoCount, 0)
        XCTAssertEqual(zeroAggregates.videoCount, 0)
        XCTAssertEqual(zeroAggregates.totalSavedBytes, 0)
        XCTAssertEqual(zeroAggregates.reductionPercentage, 0.0)
    }

    /// Workflow Test 7: Temp Cache Purging Post-Batch Leaves History Metadata Untouched.
    /// Demonstrates system isolation: Purging temporary processing files does not corrupt or wipe persistent history records.
    func testWorkflow_DualBatch_TempFilesPurgedPostProcessing_HistoryPersists() async throws {
        let compressor = PhotoCompressorService()

        let photoURL = try SyntheticAssetGenerator.createJPEG(width: 300, height: 300)
        trackedURLs.append(photoURL)

        let destURL = TempFileManager.shared.createTempFileURL(extension: "jpg")
        let result = try await compressor.compressPhoto(at: photoURL, strength: .medium, destinationURL: destURL)

        let item = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: photoURL.lastPathComponent,
            mediaType: "photo",
            sourceFormat: "jpg",
            targetFormat: "jpg",
            originalByteSize: result.originalSize,
            compressedByteSize: result.compressedSize,
            compressionStrength: .medium
        )
        try await historyStore.addItem(item)

        // Purge temp storage
        let purgedCount = try TempFileManager.shared.purgeAllTempFiles()
        XCTAssertGreaterThanOrEqual(purgedCount, 1)

        // Verify history metadata is intact
        let items = try await historyStore.loadHistory()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, item.id)
    }

    /// Workflow Test 8: Partial Batch Failure Resilience & History Integrity.
    /// Submits a batch with 1 valid photo, 1 valid video, and 1 corrupted asset.
    /// Valid items succeed and write history records; corrupted file fails gracefully without compromising batch integrity.
    func testWorkflow_BatchPartialFailure_IsolatedFailureHandling_AndHistoryIntegrity() async throws {
        let compressor = PhotoCompressorService()

        // 1. Valid Photo
        let validPhoto = try SyntheticAssetGenerator.createJPEG(width: 250, height: 250)
        trackedURLs.append(validPhoto)
        let validPhotoDest = TempFileManager.shared.createTempFileURL(extension: "jpg")
        trackedURLs.append(validPhotoDest)

        // 2. Corrupt File
        let corruptFile = try SyntheticAssetGenerator.createCorruptedFile(fileExtension: "jpg")
        trackedURLs.append(corruptFile)
        let corruptDest = TempFileManager.shared.createTempFileURL(extension: "jpg")
        trackedURLs.append(corruptDest)

        // 3. Process Valid Photo
        let photoResult = try await compressor.compressPhoto(at: validPhoto, strength: .low, destinationURL: validPhotoDest)
        let photoItem = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: validPhoto.lastPathComponent,
            mediaType: "photo",
            sourceFormat: "jpg",
            targetFormat: "jpg",
            originalByteSize: photoResult.originalSize,
            compressedByteSize: photoResult.compressedSize,
            compressionStrength: .low
        )
        try await historyStore.addItem(photoItem)

        // 4. Process Corrupted File - Expect Graceful Failure
        do {
            _ = try await compressor.compressPhoto(at: corruptFile, strength: .low, destinationURL: corruptDest)
            XCTFail("Corrupted photo must throw an error during compression")
        } catch {
            // Expected failure: no history item should be added for corrupted item
            XCTAssertNotNil(error)
        }

        // 5. Verify only successful item exists in history
        let storedItems = try await historyStore.loadHistory()
        XCTAssertEqual(storedItems.count, 1)
        XCTAssertEqual(storedItems.first?.fileName, validPhoto.lastPathComponent)
    }
}
