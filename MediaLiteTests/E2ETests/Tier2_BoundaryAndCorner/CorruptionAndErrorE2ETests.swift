//
//  CorruptionAndErrorE2ETests.swift
//  MediaLiteTests
//
//  Tier 2: Boundary & Corner Cases E2E Tests
//  Covers corrupted JPEG/PNG/HEIC headers, truncated MP4/MOV containers, non-existent
//  source URLs, unwritable destination directories, and corrupted history JSON handling.
//

import XCTest
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import AVFoundation
@testable import MediaLite

final class CorruptionAndErrorE2ETests: XCTestCase {

    private var tempURLsToCleanup: [URL] = []
    private var tempFileManager: TempFileManager!

    override func setUp() {
        super.setUp()
        tempFileManager = TempFileManager(tempSubdirectoryName: "com.medialite.tests.tier2.corruption.\(UUID().uuidString)")
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

    // MARK: - 1. Corrupted Image Headers

    /// Verifies that passing a corrupted JPEG file (invalid SOI marker followed by garbage bytes)
    /// throws an error and does not produce an orphaned or corrupted output file.
    func testCorruptedJPEGHeaderThrowsError() async throws {
        let corruptURL = trackForCleanup(try SyntheticAssetGenerator.createCorruptedFile(extension: "jpg"))
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "jpg"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()

        do {
            _ = try await compressor.compressPhoto(
                at: corruptURL,
                strength: .medium,
                destinationURL: destinationURL
            )
            XCTFail("Expected compression of corrupted JPEG to throw an error, but it succeeded")
        } catch {
            XCTAssertNotNil(error, "Expected a descriptive compression error for corrupted JPEG")
        }

        // Verify destination file was not created or left in a partial invalid state
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destinationURL.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0) > 0,
            "Destination should not exist as a non-empty file when compression fails"
        )
    }

    /// Verifies that passing a corrupted PNG file (valid PNG signature followed by truncated IHDR)
    /// causes the compressor to reject the file cleanly with an error.
    func testCorruptedPNGHeaderThrowsError() async throws {
        let corruptURL = trackForCleanup(try SyntheticAssetGenerator.createCorruptedFile(extension: "png"))
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "png"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()

        do {
            _ = try await compressor.compressPhoto(
                at: corruptURL,
                strength: .high,
                destinationURL: destinationURL
            )
            XCTFail("Expected compression of corrupted PNG to throw an error, but it succeeded")
        } catch {
            XCTAssertNotNil(error, "Expected a descriptive compression error for corrupted PNG")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destinationURL.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0) > 0
        )
    }

    /// Verifies that passing a corrupted HEIC file (damaged ftyp box followed by garbage)
    /// is safely rejected without crashing Apple ImageIO frameworks.
    func testCorruptedHEICContainerThrowsError() async throws {
        let corruptURL = trackForCleanup(try SyntheticAssetGenerator.createCorruptedFile(extension: "heic"))
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "heic"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()

        do {
            _ = try await compressor.compressPhoto(
                at: corruptURL,
                strength: .low,
                destinationURL: destinationURL
            )
            XCTFail("Expected compression of corrupted HEIC to throw an error, but it succeeded")
        } catch {
            XCTAssertNotNil(error, "Expected a descriptive compression error for corrupted HEIC")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destinationURL.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0) > 0
        )
    }

    // MARK: - 2. Truncated Video Containers

    /// Verifies that a truncated MP4 file (broken ftyp box / missing moov box)
    /// causes the video processor task to fail with an error and terminates the progress stream.
    func testTruncatedMP4ContainerThrowsError() async throws {
        let corruptURL = trackForCleanup(try SyntheticAssetGenerator.createCorruptedFile(extension: "mp4"))
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: corruptURL,
            mode: .improveCompatibility,
            strength: .medium,
            destinationURL: destinationURL
        )

        // Stream must safely terminate without infinite polling
        let streamFinished = expectation(description: "Progress stream finishes")
        Task {
            for await _ in stream {
                // Drain stream
            }
            streamFinished.fulfill()
        }

        do {
            _ = try await task.value
            XCTFail("Expected processing of truncated MP4 to throw an error, but it succeeded")
        } catch {
            XCTAssertNotNil(error, "Video processor task must throw on truncated MP4")
        }

        await fulfillment(of: [streamFinished], timeout: 5.0)

        // Destination must not be left as a valid video
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let asset = AVURLAsset(url: destinationURL)
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            XCTAssertFalse(isPlayable, "Corrupted video output must not be reported as playable")
        }
    }

    /// Verifies that a corrupted QuickTime MOV container is rejected with an error.
    func testTruncatedMOVContainerThrowsError() async throws {
        let corruptURL = trackForCleanup(try SyntheticAssetGenerator.createCorruptedFile(extension: "mov"))
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: corruptURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: destinationURL
        )

        let streamFinished = expectation(description: "Progress stream finishes for MOV")
        Task {
            for await _ in stream {
                // Drain stream
            }
            streamFinished.fulfill()
        }

        do {
            _ = try await task.value
            XCTFail("Expected processing of truncated MOV to throw an error, but it succeeded")
        } catch {
            XCTAssertNotNil(error)
        }

        await fulfillment(of: [streamFinished], timeout: 5.0)
    }

    // MARK: - 3. Non-Existent Source URLs

    /// Verifies that calling compressPhoto with a non-existent file URL fails immediately
    /// with a file read / not found error.
    func testNonExistentSourceURLThrowsErrorForPhoto() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.medialite.missing.\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "jpg"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()

        do {
            _ = try await compressor.compressPhoto(
                at: missingURL,
                strength: .medium,
                destinationURL: destinationURL
            )
            XCTFail("Expected compressPhoto to throw for non-existent source URL")
        } catch {
            XCTAssertNotNil(error)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    /// Verifies that calling processVideo with a non-existent file URL causes the task to fail
    /// with an error and terminates the progress stream.
    func testNonExistentSourceURLThrowsErrorForVideo() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.medialite.missing.\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: missingURL,
            mode: .reduceSize,
            strength: .low,
            destinationURL: destinationURL
        )

        let streamFinished = expectation(description: "Stream terminates on missing video file")
        Task {
            for await _ in stream {}
            streamFinished.fulfill()
        }

        do {
            _ = try await task.value
            XCTFail("Expected processVideo to throw for non-existent source URL")
        } catch {
            XCTAssertNotNil(error)
        }

        await fulfillment(of: [streamFinished], timeout: 5.0)
    }

    // MARK: - 4. Unwritable Destination Directory

    /// Verifies that when destinationURL points to an invalid, unwritable, or permission-denied path,
    /// the compression engine throws a write error rather than crashing.
    func testUnwritableDestinationDirectoryThrowsError() async throws {
        let sourceURL = trackForCleanup(
            try SyntheticAssetGenerator.createJPEG(
                width: 100,
                height: 100,
                hasExif: false
            )
        )

        // Create a regular file and attempt to use it as a directory component in the destination path
        let obstacleFile = trackForCleanup(tempFileManager.createTempFileURL(extension: "bin"))
        try Data("obstacle".utf8).write(to: obstacleFile)

        let unwritableDestination = obstacleFile
            .appendingPathComponent("impossible_subfolder")
            .appendingPathComponent("output.jpg")

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()

        do {
            _ = try await compressor.compressPhoto(
                at: sourceURL,
                strength: .medium,
                destinationURL: unwritableDestination
            )
            XCTFail("Expected compression to throw when destination directory is unwritable/invalid")
        } catch {
            XCTAssertNotNil(error, "Expected file system write failure error")
        }
    }

    // MARK: - 5. Corrupted History JSON Handling & Recovery

    /// Verifies that decoding corrupted, truncated, or malformed JSON data for CompressionHistoryItem
    /// throws a DecodingError and does not produce corrupt model instances or unhandled traps.
    func testCorruptedHistoryJSONDecodingFailsSafely() {
        // Malformed JSON (truncated mid-string)
        let truncatedJSON = Data("{\"id\":\"12345\",\"fileName\":\"photo.jpg\",\"originalByteSize\":".utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CompressionHistoryItem.self, from: truncatedJSON),
            "Decoding truncated JSON must throw DecodingError"
        ) { error in
            XCTAssertTrue(error is DecodingError, "Error must be a DecodingError")
        }

        // Corrupted JSON with invalid type for originalByteSize (string instead of Int64)
        let invalidTypeJSON = Data("""
        {
            "id": "A1B2C3D4-E5F6-7A8B-9C0D-1E2F3A4B5C6D",
            "timestamp": 0,
            "fileName": "photo.jpg",
            "mediaType": "photo",
            "sourceFormat": "JPEG",
            "targetFormat": "JPEG",
            "originalByteSize": "NOT_A_NUMBER",
            "compressedByteSize": 1024,
            "compressionStrength": "MEDIUM",
            "isSavedToLibrary": false
        }
        """.utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(CompressionHistoryItem.self, from: invalidTypeJSON),
            "Decoding JSON with invalid types must throw DecodingError"
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    /// Verifies that HistoryStorageService handles a corrupted backing JSON file safely
    /// (by either returning an empty list or throwing a recoverable error, without fatalError),
    /// and allows subsequent valid operations to succeed and restore consistent state.
    func testHistoryStorageRecoversAfterEncounteringCorruptedData() async throws {
        let corruptHistoryURL = trackForCleanup(
            tempFileManager.baseDirectory.appendingPathComponent("corrupt_history_\(UUID().uuidString).json")
        )
        // Write completely invalid non-JSON garbage bytes to the history file
        let garbageBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0xFE, 0xFD])
        try garbageBytes.write(to: corruptHistoryURL, options: .atomic)

        let historyStore = HistoryStorageService(fileURL: corruptHistoryURL)

        // Loading from corrupted storage must either throw a recoverable error or return [] (safe reset)
        var loadedItems: [CompressionHistoryItem]?
        do {
            loadedItems = try await historyStore.loadHistory()
            // If it returns, it should safely return empty list rather than corrupt garbage
            XCTAssertEqual(loadedItems?.count, 0, "Corrupted store should gracefully fallback to empty history")
        } catch {
            // Alternatively, throwing a clean error is also valid recovery behavior
            XCTAssertNotNil(error)
        }

        // Now verify recovery: adding a new valid item must succeed and re-establish clean persistence
        let newItem = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: "recovered_image.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 2048,
            compressedByteSize: 1024,
            compressionStrength: .high,
            durationSeconds: nil,
            isSavedToLibrary: false
        )

        try await historyStore.addItem(newItem)

        let itemsAfterAdd = try await historyStore.loadHistory()
        XCTAssertEqual(itemsAfterAdd.count, 1, "Store should contain exactly 1 item after adding to recovered store")
        XCTAssertEqual(itemsAfterAdd.first?.id, newItem.id)
        XCTAssertEqual(itemsAfterAdd.first?.fileName, "recovered_image.jpg")
        XCTAssertEqual(itemsAfterAdd.first?.byteDelta, 1024)
        XCTAssertEqual(itemsAfterAdd.first?.reductionPercentage, 50.0, accuracy: 0.001)

        // Cleanup the store
        try await historyStore.clearAllHistory()
        let itemsAfterClear = try await historyStore.loadHistory()
        XCTAssertTrue(itemsAfterClear.isEmpty)
    }
}
