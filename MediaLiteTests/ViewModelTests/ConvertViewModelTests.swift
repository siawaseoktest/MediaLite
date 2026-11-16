//
//  ConvertViewModelTests.swift
//  MediaLiteTests
//
//  Unit tests for ConvertViewModel covering video loading & inspection,
//  conversion progress streaming, cancellation, result evaluation,
//  history logging, and photo library video export.
//

import XCTest
import AVFoundation
@testable import MediaLite

// MARK: - Test Mocks

private final class MockVideoProcessor: VideoProcessorProtocol, @unchecked Sendable {
    var shouldFail: Bool = false
    var resultDuration: Double = 10.0
    var compressedSizeMultiplier: Double = 0.4
    private(set) var processCallCount: Int = 0

    func processVideo(
        at sourceURL: URL,
        mode: VideoProcessingMode,
        strength: CompressionStrength,
        destinationURL: URL
    ) -> (stream: AsyncStream<VideoProcessingProgress>, task: Task<VideoProcessingResult, Error>) {
        processCallCount += 1

        let shouldFail = self.shouldFail
        let duration = self.resultDuration
        let multiplier = self.compressedSizeMultiplier

        let (stream, continuation) = AsyncStream<VideoProcessingProgress>.makeStream()

        let task = Task<VideoProcessingResult, Error> {
            continuation.yield(VideoProcessingProgress(fractionCompleted: 0.25, description: "Demuxing tracks..."))
            try await Task.sleep(nanoseconds: 10_000_000)

            if Task.isCancelled {
                continuation.finish()
                throw VideoProcessingError.cancelled
            }

            continuation.yield(VideoProcessingProgress(fractionCompleted: 0.75, description: "Encoding video stream..."))
            try await Task.sleep(nanoseconds: 10_000_000)

            if Task.isCancelled {
                continuation.finish()
                throw VideoProcessingError.cancelled
            }

            if shouldFail {
                continuation.finish()
                throw VideoProcessingError.transcodeFailed("Mock transcode error triggered")
            }

            let origSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 5_000_000
            let compSize = Int64(Double(origSize) * multiplier)

            // Write dummy payload to destinationURL
            let dummy = Data(repeating: 0xEE, count: max(1, Int(compSize)))
            try dummy.write(to: destinationURL)

            continuation.yield(VideoProcessingProgress(fractionCompleted: 1.0, description: "Finalizing MP4 container..."))
            continuation.finish()

            return VideoProcessingResult(
                originalURL: sourceURL,
                processedURL: destinationURL,
                originalSize: origSize,
                processedSize: compSize,
                duration: duration
            )
        }

        return (stream: stream, task: task)
    }
}

private final class MockPhotoLibraryForConvert: PhotoLibraryProtocol, @unchecked Sendable {
    var authorizationStatus: PHAuthorizationStatus = .authorized
    var saveVideoCallCount: Int = 0
    var shouldFail: Bool = false

    func checkAuthorizationStatus() -> PHAuthorizationStatus {
        authorizationStatus
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        authorizationStatus
    }

    func saveImage(at fileURL: URL) async throws -> String {
        return "asset-image"
    }

    func saveVideo(at fileURL: URL) async throws -> String {
        if shouldFail {
            throw PhotoLibraryError.saveFailed("Mock video library error")
        }
        saveVideoCallCount += 1
        return "asset-video-\(saveVideoCallCount)"
    }
}

// MARK: - ConvertViewModelTests

final class ConvertViewModelTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var historyFileURL: URL!
    private var historyStore: HistoryStorageService!
    private var mockProcessor: MockVideoProcessor!
    private var mockLibrary: MockPhotoLibraryForConvert!

    override func setUp() {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.medialite.tests.convertvm.\(uniqueID)")
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        historyFileURL = tempDirectoryURL.appendingPathComponent("history.json")
        historyStore = HistoryStorageService(storageURL: historyFileURL)
        mockProcessor = MockVideoProcessor()
        mockLibrary = MockPhotoLibraryForConvert()
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        historyFileURL = nil
        historyStore = nil
        mockProcessor = nil
        mockLibrary = nil
        super.tearDown()
    }

    private func createTestVideoFile(named name: String = "sample.mov", byteCount: Int = 50_000) -> URL {
        let fileURL = tempDirectoryURL.appendingPathComponent(name)
        let data = Data(repeating: 0x33, count: byteCount)
        try? data.write(to: fileURL)
        return fileURL
    }

    @MainActor
    func testConvertViewModelInitialState() {
        let viewModel = ConvertViewModel(
            videoProcessor: mockProcessor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        XCTAssertNil(viewModel.selectedPickerItem)
        XCTAssertNil(viewModel.selectedVideoURL)
        XCTAssertTrue(viewModel.sourceFileName.isEmpty)
        XCTAssertEqual(viewModel.sourceFileSize, 0)
        XCTAssertNil(viewModel.videoMetadata)
        XCTAssertFalse(viewModel.isConverting)
        XCTAssertFalse(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isSavedToLibrary)
        XCTAssertNil(viewModel.avPlayer)
        XCTAssertNil(viewModel.conversionResult)
        XCTAssertEqual(viewModel.conversionProgress, 0.0)
    }

    @MainActor
    func testConvertViewModelLoadVideo() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockProcessor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let file = createTestVideoFile(named: "vacation.mov", byteCount: 80_000)
        try await viewModel.loadVideo(from: file)

        XCTAssertEqual(viewModel.selectedVideoURL, file)
        XCTAssertEqual(viewModel.sourceFileName, "vacation.mov")
        XCTAssertEqual(viewModel.sourceFileSize, 80_000)
        XCTAssertNotNil(viewModel.videoMetadata)
    }

    @MainActor
    func testConvertViewModelStartConversionSuccess() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockProcessor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let file = createTestVideoFile(named: "video.mov", byteCount: 100_000)
        try await viewModel.loadVideo(from: file)

        viewModel.startConversion()

        var attempts = 0
        while !viewModel.isCompleted && attempts < 50 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isConverting)
        XCTAssertNotNil(viewModel.conversionResult)
        XCTAssertNotNil(viewModel.avPlayer)

        let result = viewModel.conversionResult!
        XCTAssertEqual(result.originalSize, 100_000)
        XCTAssertEqual(result.processedSize, 40_000) // 0.4 multiplier
        XCTAssertEqual(result.byteDelta, 60_000)
        XCTAssertEqual(result.reductionPercentage, 60.0, accuracy: 0.1)

        // Verify history persistence
        let history = try await historyStore.loadHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.fileName, "video.mov")
        XCTAssertEqual(history.first?.mediaType, "video")
    }

    @MainActor
    func testConvertViewModelCancellation() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockProcessor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let file = createTestVideoFile(named: "cancel.mov", byteCount: 200_000)
        try await viewModel.loadVideo(from: file)

        viewModel.startConversion()
        viewModel.cancelConversion()

        XCTAssertFalse(viewModel.isConverting)
        XCTAssertEqual(viewModel.progressDescription, "Cancelled")
    }

    @MainActor
    func testConvertViewModelCancellationSuppressesErrorAlert() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockProcessor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )
        let file = createTestVideoFile(named: "cancel_race.mov", byteCount: 100_000)
        try await viewModel.loadVideo(from: file)
        viewModel.startConversion()
        viewModel.cancelConversion()
        
        // Allow completion task to settle
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        XCTAssertFalse(viewModel.showErrorAlert, "Error alert must NOT be shown on cancellation")
        XCTAssertNil(viewModel.errorMessage, "errorMessage must be nil on cancellation")
        XCTAssertFalse(viewModel.isConverting)
    }

    @MainActor
    func testConvertViewModelSaveToPhotoLibrary() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockProcessor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let dest = createTestVideoFile(named: "processed.mp4", byteCount: 10_000)
        viewModel.conversionResult = VideoProcessingResult(
            originalURL: dest,
            processedURL: dest,
            originalSize: 20_000,
            processedSize: 10_000,
            duration: 5.0
        )

        await viewModel.saveToPhotoLibrary()

        XCTAssertTrue(viewModel.isSavedToLibrary)
        XCTAssertEqual(mockLibrary.saveVideoCallCount, 1)
        XCTAssertNotNil(viewModel.saveSuccessMessage)
    }

    @MainActor
    func testConvertViewModelResetSelection() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockProcessor,
            historyStorage: historyStore,
            photoLibrary: mockLibrary
        )

        let file = createTestVideoFile(named: "test.mov", byteCount: 20_000)
        try await viewModel.loadVideo(from: file)
        XCTAssertNotNil(viewModel.selectedVideoURL)

        viewModel.resetSelection()

        XCTAssertNil(viewModel.selectedVideoURL)
        XCTAssertTrue(viewModel.sourceFileName.isEmpty)
        XCTAssertEqual(viewModel.sourceFileSize, 0)
        XCTAssertNil(viewModel.videoMetadata)
        XCTAssertFalse(viewModel.isCompleted)
    }
}
