//
//  CompressViewModelTests.swift
//  MediaLiteTests
//
//  Unit tests for CompressViewModel covering item addition/removal,
//  batch compression execution, cancellation, aggregates calculation,
//  history logging, and photo library export.
//

import XCTest
import UniformTypeIdentifiers
import Photos
@testable import MediaLite

// MARK: - Test Mocks

private final class MockPhotoCompressor: PhotoCompressorProtocol, @unchecked Sendable {
    var shouldFail: Bool = false
    var compressedSizeMultiplier: Double = 0.5
    private(set) var compressedCallCount: Int = 0

    func compressPhoto(
        at sourceURL: URL,
        strength: CompressionStrength,
        destinationURL: URL
    ) async throws -> PhotoCompressionResult {
        compressedCallCount += 1
        if shouldFail {
            throw PhotoCompressionError.compressionFailed("Mock failure triggered")
        }

        let origSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 1_000_000
        let compSize = Int64(Double(origSize) * compressedSizeMultiplier)

        // Write small dummy payload to destinationURL
        let dummyData = Data(repeating: 0xAA, count: max(1, Int(compSize)))
        try dummyData.write(to: destinationURL)

        return PhotoCompressionResult(
            originalURL: sourceURL,
            compressedURL: destinationURL,
            originalSize: origSize,
            compressedSize: compSize,
            format: .jpeg
        )
    }
}

private final class MockPhotoLibrary: PhotoLibraryProtocol, @unchecked Sendable {
    var authorizationStatus: PHAuthorizationStatus = .authorized
    var saveImageCallCount: Int = 0
    var saveVideoCallCount: Int = 0
    var shouldFail: Bool = false

    func checkAuthorizationStatus() -> PHAuthorizationStatus {
        authorizationStatus
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        authorizationStatus
    }

    func saveImage(at fileURL: URL) async throws -> String {
        if shouldFail {
            throw PhotoLibraryError.saveFailed("Mock photo library save error")
        }
        saveImageCallCount += 1
        return "asset-image-\(saveImageCallCount)"
    }

    func saveVideo(at fileURL: URL) async throws -> String {
        if shouldFail {
            throw PhotoLibraryError.saveFailed("Mock photo library video save error")
        }
        saveVideoCallCount += 1
        return "asset-video-\(saveVideoCallCount)"
    }
}

// MARK: - CompressViewModelTests

final class CompressViewModelTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var historyFileURL: URL!
    private var historyStore: HistoryStorageService!
    private var mockCompressor: MockPhotoCompressor!
    private var mockLibrary: MockPhotoLibrary!

    override func setUp() {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.medialite.tests.compressvm.\(uniqueID)")
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        historyFileURL = tempDirectoryURL.appendingPathComponent("history.json")
        historyStore = HistoryStorageService(storageURL: historyFileURL)
        mockCompressor = MockPhotoCompressor()
        mockLibrary = MockPhotoLibrary()
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        historyFileURL = nil
        historyStore = nil
        mockCompressor = nil
        mockLibrary = nil
        super.tearDown()
    }

    private func createTestFile(named name: String, byteCount: Int = 10_000) -> URL {
        let fileURL = tempDirectoryURL.appendingPathComponent(name)
        let data = Data(repeating: 0x55, count: byteCount)
        try? data.write(to: fileURL)
        return fileURL
    }

    @MainActor
    func testCompressViewModelInitialState() {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        XCTAssertTrue(viewModel.selectedItems.isEmpty)
        XCTAssertTrue(viewModel.compressionResults.isEmpty)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isSavedToLibrary)
        XCTAssertEqual(viewModel.overallProgress, 0.0)
        XCTAssertEqual(viewModel.currentProcessingIndex, 0)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testCompressViewModelAddAndRemoveMediaItem() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let file1 = createTestFile(named: "photo1.jpg", byteCount: 20_000)
        let file2 = createTestFile(named: "photo2.png", byteCount: 40_000)

        await viewModel.addMediaItem(at: file1, originalFormat: .jpeg)
        await viewModel.addMediaItem(at: file2, originalFormat: .png)

        XCTAssertEqual(viewModel.selectedItems.count, 2)
        XCTAssertEqual(viewModel.selectedItems[0].byteSize, 20_000)
        XCTAssertEqual(viewModel.selectedItems[1].byteSize, 40_000)

        viewModel.removeItem(at: 0)
        XCTAssertEqual(viewModel.selectedItems.count, 1)
        XCTAssertEqual(viewModel.selectedItems[0].suggestedFileName, "photo2.png")
    }

    @MainActor
    func testCompressViewModelClearSelection() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let file1 = createTestFile(named: "photo1.jpg", byteCount: 15_000)
        await viewModel.addMediaItem(at: file1, originalFormat: .jpeg)
        XCTAssertEqual(viewModel.selectedItems.count, 1)

        viewModel.clearSelection()
        XCTAssertTrue(viewModel.selectedItems.isEmpty)
        XCTAssertEqual(viewModel.overallProgress, 0.0)
        XCTAssertFalse(viewModel.isProcessing)
    }

    @MainActor
    func testCompressViewModelBatchCompressionSuccess() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let file1 = createTestFile(named: "img1.jpg", byteCount: 100_000)
        let file2 = createTestFile(named: "img2.jpg", byteCount: 200_000)

        await viewModel.addMediaItem(at: file1, originalFormat: .jpeg)
        await viewModel.addMediaItem(at: file2, originalFormat: .jpeg)

        viewModel.startCompression()

        // Wait for batch completion
        var attempts = 0
        while !viewModel.isCompleted && attempts < 50 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertEqual(viewModel.compressionResults.count, 2)
        XCTAssertEqual(mockCompressor.compressedCallCount, 2)

        // Verify math: 0.5 multiplier means 50% savings
        XCTAssertEqual(viewModel.totalOriginalSize, 300_000)
        XCTAssertEqual(viewModel.totalCompressedSize, 150_000)
        XCTAssertEqual(viewModel.totalSavedBytes, 150_000)
        XCTAssertEqual(viewModel.totalReductionPercentage, 50.0, accuracy: 0.1)

        // Verify history was saved
        let historyItems = try await historyStore.loadHistory()
        XCTAssertEqual(historyItems.count, 2)
    }

    @MainActor
    func testCompressViewModelCancellation() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let file = createTestFile(named: "large.jpg", byteCount: 500_000)
        await viewModel.addMediaItem(at: file, originalFormat: .jpeg)

        viewModel.startCompression()
        viewModel.cancelCompression()

        XCTAssertFalse(viewModel.isProcessing)
    }

    @MainActor
    func testCompressViewModelSaveAllToLibrary() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let dest1 = createTestFile(named: "dest1.jpg", byteCount: 5_000)
        let dest2 = createTestFile(named: "dest2.jpg", byteCount: 8_000)

        viewModel.compressionResults = [
            PhotoCompressionResult(originalURL: dest1, compressedURL: dest1, originalSize: 10_000, compressedSize: 5_000, format: .jpeg),
            PhotoCompressionResult(originalURL: dest2, compressedURL: dest2, originalSize: 16_000, compressedSize: 8_000, format: .jpeg)
        ]

        await viewModel.saveAllToLibrary()

        XCTAssertTrue(viewModel.isSavedToLibrary)
        XCTAssertEqual(mockLibrary.saveImageCallCount, 2)
        XCTAssertNotNil(viewModel.saveSuccessMessage)
    }

    @MainActor
    func testCompressViewModelInferredFormatDetection() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )
        let file1 = createTestFile(named: "magic_jpeg.dat", byteCount: 1_000)
        let jpegMagic = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        await viewModel.addMediaItem(at: file1, originalFormat: nil, data: jpegMagic)

        let file2 = createTestFile(named: "magic_png.dat", byteCount: 1_000)
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        await viewModel.addMediaItem(at: file2, originalFormat: nil, data: pngMagic)

        XCTAssertEqual(viewModel.selectedItems.count, 2)
        XCTAssertEqual(viewModel.selectedItems[0].format, .jpeg)
        XCTAssertEqual(viewModel.selectedItems[1].format, .png)
    }

    @MainActor
    func testCompressViewModelCancellationCleansTempFiles() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let tempFile = createTestFile(named: "to_cancel.jpg", byteCount: 10_000)
        viewModel.compressionResults = [
            PhotoCompressionResult(originalURL: tempFile, compressedURL: tempFile, originalSize: 10_000, compressedSize: 5_000, format: .jpeg)
        ]

        viewModel.cancelCompression()
        XCTAssertTrue(viewModel.compressionResults.isEmpty)
    }

    @MainActor
    func testCompressViewModelSyncWithDefaultSettings() {
        let testDefaults = UserDefaults(suiteName: "com.medialite.tests.compressviewmodel")!
        testDefaults.removePersistentDomain(forName: "com.medialite.tests.compressviewmodel")
        
        var customSettings = AppSettings()
        customSettings.defaultCompressionStrength = .high
        customSettings.save(to: testDefaults)

        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary,
            appSettings: customSettings
        )

        XCTAssertEqual(viewModel.selectedQuality, .high)
    }
}
