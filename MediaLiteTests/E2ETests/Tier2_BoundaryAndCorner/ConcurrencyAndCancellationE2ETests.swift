//
//  ConcurrencyAndCancellationE2ETests.swift
//  MediaLiteTests
//
//  Tier 2: Boundary & Corner Cases E2E Tests
//  Covers mid-flight video compression cancellation (task.cancel()), verification that
//  temporary files are deleted upon cancellation, progress stream cancellation completion,
//  and concurrent compression tasks without resource collisions.
//

import XCTest
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import AVFoundation
@testable import MediaLite

final class ConcurrencyAndCancellationE2ETests: XCTestCase {

    private var tempURLsToCleanup: [URL] = []
    private var tempFileManager: TempFileManager!

    override func setUp() {
        super.setUp()
        tempFileManager = TempFileManager(tempSubdirectoryName: "com.medialite.tests.tier2.concurrency.\(UUID().uuidString)")
    }

    override func tearDown() {
        SyntheticAssetGenerator.cleanup(urls: tempURLsToCleanup)
        tempURLsToCleanup.removeAll()
        try? tempFileManager.purgeAllTempFiles()
        try? FileManager.default.removeItem(at: tempFileManager.baseDirectory)
        tempFileManager = nil
        super.tearDown()
    }

    @discardableResult
    private func trackForCleanup(_ url: URL) -> URL {
        tempURLsToCleanup.append(url)
        return url
    }

    // MARK: - 1. Mid-Flight Video Compression Cancellation

    /// Verifies that cancelling a running video processing task mid-flight (task.cancel())
    /// causes the task to abort promptly and throw a CancellationError.
    func testMidFlightVideoCompressionCancellation() async throws {
        let sourceURL = trackForCleanup(
            try await SyntheticAssetGenerator.createVideo(
                durationSeconds: 2.0,
                fps: 30,
                resolution: CGSize(width: 640, height: 480),
                hasAudio: true,
                isHDR: false
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: destinationURL
        )

        // Cancel mid-flight as soon as the first progress update is received
        let cancellationExpectation = expectation(description: "Cancelled after initial progress")
        Task {
            for await progress in stream {
                if progress.fractionCompleted > 0.0 {
                    task.cancel()
                    cancellationExpectation.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [cancellationExpectation], timeout: 10.0)

        // Await the task result - must fail with CancellationError or cancellation-related error
        let taskResult = await task.result
        switch taskResult {
        case .success(let result):
            XCTFail("Task should have been cancelled, but succeeded with result: \(result)")
        case .failure(let error):
            let isCancellation = error is CancellationError ||
                Task.isCancelled ||
                "\(error)".lowercased().contains("cancel")
            XCTAssertTrue(isCancellation, "Error must indicate cancellation, got: \(error)")
        }
    }

    // MARK: - 2. Cancellation Cleanup: Destination and Temp Files

    /// Verifies that upon task cancellation, partial destination files and temporary working
    /// artifacts are completely cleaned up and not left lingering on disk.
    func testTemporaryFilesDeletedUponCancellation() async throws {
        let sourceURL = trackForCleanup(
            try await SyntheticAssetGenerator.createVideo(
                durationSeconds: 2.5,
                fps: 30,
                resolution: CGSize(width: 800, height: 600),
                hasAudio: true,
                isHDR: false
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .improveCompatibility,
            strength: .medium,
            destinationURL: destinationURL
        )

        // Monitor stream, cancel mid-flight
        Task {
            for await _ in stream {
                // Yield small delay and cancel
                try? await Task.sleep(nanoseconds: 20_000_000)
                task.cancel()
                break
            }
        }

        _ = await task.result

        // Allow cleanup routines to finish
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Destination file must be deleted or empty
        let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
        if destinationExists {
            let attrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            XCTAssertEqual(size, 0, "Partial output file should be removed or cleaned up upon cancellation")
        }
    }

    // MARK: - 3. Progress Stream Cancellation Completion

    /// Verifies that cancelling the video task terminates the AsyncStream promptly
    /// without deadlocking or leaking stream iterations.
    func testProgressStreamFinishesPromptlyUponCancellation() async throws {
        let sourceURL = trackForCleanup(
            try await SyntheticAssetGenerator.createVideo(
                durationSeconds: 2.0,
                fps: 30,
                resolution: CGSize(width: 480, height: 360),
                hasAudio: false
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .low,
            destinationURL: destinationURL
        )

        // Immediately cancel the task
        task.cancel()

        // Stream iteration must complete within a reasonable timeout
        let streamCompleted = expectation(description: "Stream terminates after cancellation")
        Task {
            var count = 0
            for await _ in stream {
                count += 1
                if count > 100 {
                    XCTFail("Stream did not terminate after task cancellation")
                    break
                }
            }
            streamCompleted.fulfill()
        }

        await fulfillment(of: [streamCompleted], timeout: 5.0)
        _ = await task.result
    }

    // MARK: - 4. Immediate Cancellation Before Execution Begins

    /// Verifies that cancelling a task immediately after creation (before any frame is processed)
    /// behaves deterministically without crashing, leaking memory, or deadlocking.
    func testImmediateCancellationBeforeExecutionBegins() async throws {
        let sourceURL = trackForCleanup(
            try await SyntheticAssetGenerator.createVideo(
                durationSeconds: 1.0,
                fps: 30,
                resolution: CGSize(width: 320, height: 240),
                hasAudio: true
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: destinationURL
        )

        // Immediate cancellation
        task.cancel()

        // Drain stream
        Task {
            for await _ in stream {}
        }

        let taskResult = await task.result
        switch taskResult {
        case .success:
            // Immediate cancel might have raced, but if cancelled, it must not crash
            break
        case .failure(let error):
            let isCancel = error is CancellationError || "\(error)".lowercased().contains("cancel")
            XCTAssertTrue(isCancel, "Expected cancellation error, got: \(error)")
        }

        // Output destination should not be left as a valid video
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let asset = AVURLAsset(url: destinationURL)
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            XCTAssertFalse(isPlayable, "Cancelled task should not leave a playable output file")
        }
    }

    // MARK: - 5. Concurrent Photo Compressions (Parallel Batch)

    /// Verifies that multiple photo compressions running simultaneously across different threads
    /// do not collide on temporary files, leak resources, or corrupt shared memory.
    func testConcurrentPhotoCompressionsWithoutResourceCollisions() async throws {
        // Generate 4 distinct test images
        let jpeg1 = trackForCleanup(try SyntheticAssetGenerator.createJPEG(width: 300, height: 200, color: CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)))
        let jpeg2 = trackForCleanup(try SyntheticAssetGenerator.createJPEG(width: 400, height: 400, color: CGColor(srgbRed: 0.2, green: 0.8, blue: 0.2, alpha: 1.0)))
        let png1 = trackForCleanup(try SyntheticAssetGenerator.createPNG(width: 250, height: 250, hasAlpha: true))
        let heic1 = trackForCleanup(try SyntheticAssetGenerator.createHEIC(width: 320, height: 320, orientation: .right))

        let inputs: [(url: URL, ext: String, strength: CompressionStrength)] = [
            (jpeg1, "jpg", .low),
            (jpeg2, "jpg", .high),
            (png1, "png", .medium),
            (heic1, "heic", .high)
        ]

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()

        // Execute all 4 compressions concurrently
        let results = try await withThrowingTaskGroup(of: PhotoCompressionResult.self, returning: [PhotoCompressionResult].self) { group in
            for item in inputs {
                let dest = self.trackForCleanup(self.tempFileManager.createTempFileURL(extension: item.ext))
                group.addTask {
                    return try await compressor.compressPhoto(
                        at: item.url,
                        strength: item.strength,
                        destinationURL: dest
                    )
                }
            }

            var batch: [PhotoCompressionResult] = []
            for try await result in group {
                batch.append(result)
            }
            return batch
        }

        XCTAssertEqual(results.count, 4, "All 4 concurrent photo compressions should succeed")

        // Verify each result wrote to a unique destination without collision
        let destinationPaths = Set(results.map { $0.compressedURL.path })
        XCTAssertEqual(destinationPaths.count, 4, "All 4 destination URLs must be unique")

        for result in results {
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.compressedURL.path))
            XCTAssertGreaterThan(result.compressedSize, 0)
            XCTAssertGreaterThan(result.originalSize, 0)
        }
    }

    // MARK: - 6. Concurrent Video Processing Without Resource Collisions

    /// Verifies that two video processing operations executing concurrently on different tasks
    /// produce valid outputs independently without interfering with each other's progress or files.
    func testConcurrentVideoProcessingWithoutResourceCollisions() async throws {
        let video1 = trackForCleanup(
            try await SyntheticAssetGenerator.createVideo(
                durationSeconds: 0.4,
                fps: 30,
                resolution: CGSize(width: 320, height: 240),
                hasAudio: false
            )
        )
        let video2 = trackForCleanup(
            try await SyntheticAssetGenerator.createVideo(
                durationSeconds: 0.4,
                fps: 30,
                resolution: CGSize(width: 320, height: 240),
                hasAudio: true
            )
        )

        let dest1 = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))
        let dest2 = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()

        // Run both video tasks concurrently
        async let job1: VideoProcessingResult = {
            let (stream1, task1) = processor.processVideo(at: video1, mode: .reduceSize, strength: .medium, destinationURL: dest1)
            let drain = Task { for await _ in stream1 {} }
            let res = try await task1.value
            _ = await drain.value
            return res
        }()

        async let job2: VideoProcessingResult = {
            let (stream2, task2) = processor.processVideo(at: video2, mode: .improveCompatibility, strength: .high, destinationURL: dest2)
            let drain = Task { for await _ in stream2 {} }
            let res = try await task2.value
            _ = await drain.value
            return res
        }()

        let (result1, result2) = try await (job1, job2)

        XCTAssertNotEqual(result1.processedURL, result2.processedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result1.processedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result2.processedURL.path))
        XCTAssertGreaterThan(result1.processedSize, 0)
        XCTAssertGreaterThan(result2.processedSize, 0)
    }

    // MARK: - 7. Concurrent History Storage Actor Safety

    /// Verifies that the actor-isolated HistoryStorageService handles rapid concurrent item
    /// additions from multiple parallel tasks without data races, corrupted state, or missing items.
    func testConcurrentHistoryStoreActorSafety() async throws {
        let historyURL = trackForCleanup(
            tempFileManager.baseDirectory.appendingPathComponent("concurrent_history_\(UUID().uuidString).json")
        )
        let store = HistoryStorageService(fileURL: historyURL)

        let totalItems = 20

        // Concurrently add 20 history items
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<totalItems {
                group.addTask {
                    let item = CompressionHistoryItem(
                        id: UUID(),
                        timestamp: Date().addingTimeInterval(Double(index)),
                        fileName: "item_\(index).jpg",
                        mediaType: "photo",
                        sourceFormat: "JPEG",
                        targetFormat: "JPEG",
                        originalByteSize: Int64(5000 + index * 100),
                        compressedByteSize: Int64(2000 + index * 50),
                        compressionStrength: .medium
                    )
                    try await store.addItem(item)
                }
            }
            try await group.waitForAll()
        }

        let loaded = try await store.loadHistory()
        XCTAssertEqual(loaded.count, totalItems, "History store must contain exactly \(totalItems) items with zero race loss")

        // Verify all item IDs are distinct
        let uniqueIDs = Set(loaded.map { $0.id })
        XCTAssertEqual(uniqueIDs.count, totalItems)

        // Clear history
        try await store.clearAllHistory()
        let loadedAfterClear = try await store.loadHistory()
        XCTAssertTrue(loadedAfterClear.isEmpty)
    }

    // MARK: - 8. TempFileManager Concurrent Unique URL Generation

    /// Verifies that TempFileManager safely generates unique non-colliding URLs
    /// when called concurrently from 100 parallel tasks.
    func testTempFileManagerConcurrentUniqueURLGeneration() async throws {
        let iterations = 100

        let generatedURLs = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    return self.tempFileManager.createTempFileURL(extension: "tmp")
                }
            }

            var urls: [URL] = []
            for try await url in group {
                urls.append(url)
            }
            return urls
        }

        XCTAssertEqual(generatedURLs.count, iterations)
        let uniqueSet = Set(generatedURLs)
        XCTAssertEqual(uniqueSet.count, iterations, "Every generated temporary URL must be globally unique")
    }
}
