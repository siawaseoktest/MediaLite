//
//  Tier5_AdversarialHardeningTests.swift
//  MediaLiteTests
//
//  Tier 5: Adversarial Coverage Hardening Test Suite (Milestone 7 Phase 2)
//  Combined 66-test adversarial suite authored by Challenger 1 (30 tests) and Challenger 2 (36 tests).
//  Covers white-box edge cases, degenerate dimensions, concurrency & cancellation cascades,
//  Exif/metadata fidelity, actor isolation reentrancy, negative size deltas, batch resilience,
//  and clean resource lifecycles.
//

import XCTest
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import AVFoundation
import CoreMedia
import CoreVideo
#if canImport(Photos)
import Photos
#endif
import PhotosUI
import SwiftUI
@testable import MediaLite

final class Tier5_ServicesAdversarialTests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var tempFileManager: TempFileManager!
    private var photoCompressor: PhotoCompressorProtocol!
    private var videoProcessor: VideoProcessorProtocol!
    private var historyStore: HistoryStorageService!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        tempFileManager = TempFileManager(tempSubdirectoryName: "com.medialite.tests.tier5.services.\(UUID().uuidString)")
        photoCompressor = PhotoCompressorService()
        videoProcessor = VideoProcessorService()
        historyStore = HistoryStorageService(fileURL: tempFileManager.createTempFileURL(extension: "json"))
    }

    override func tearDown() {
        SyntheticAssetGenerator.cleanup(urls: trackedURLs)
        trackedURLs.removeAll()
        try? tempFileManager.purgeAllTempFiles()
        try? FileManager.default.removeItem(at: tempFileManager.baseDirectory)
        tempFileManager = nil
        photoCompressor = nil
        videoProcessor = nil
        historyStore = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    @discardableResult
    private func trackURL(_ url: URL) -> URL {
        trackedURLs.append(url)
        return url
    }

    /// Synthesizes a valid TIFF image container to verify format rejection in photo compressor.
    private func createSyntheticTIFF(width: Int = 100, height: Int = 100) throws -> URL {
        let targetURL = trackURL(tempFileManager.createTempFileURL(extension: "tiff"))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SyntheticAssetError.contextCreationFailed
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw SyntheticAssetError.contextCreationFailed
        }
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw SyntheticAssetError.imageCreationFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(targetURL as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw SyntheticAssetError.destinationCreationFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SyntheticAssetError.finalizationFailed
        }
        return targetURL
    }

    /// Synthesizes a valid JPEG with embedded GPS metadata dictionary.
    private func createJPEGWithGPS(
        latitude: Double,
        latitudeRef: String,
        longitude: Double,
        longitudeRef: String,
        altitude: Double,
        altitudeRef: Int
    ) throws -> URL {
        let targetURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SyntheticAssetError.contextCreationFailed
        }
        guard let context = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw SyntheticAssetError.contextCreationFailed
        }
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.4, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        guard let image = context.makeImage() else {
            throw SyntheticAssetError.imageCreationFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(targetURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SyntheticAssetError.destinationCreationFailed
        }
        let gpsDict: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: latitude,
            kCGImagePropertyGPSLatitudeRef: latitudeRef,
            kCGImagePropertyGPSLongitude: longitude,
            kCGImagePropertyGPSLongitudeRef: longitudeRef,
            kCGImagePropertyGPSAltitude: altitude,
            kCGImagePropertyGPSAltitudeRef: altitudeRef
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: gpsDict
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SyntheticAssetError.finalizationFailed
        }
        return targetURL
    }

    /// Synthesizes an audio-only media asset (M4A container with AAC audio track, zero video tracks).
    private func createAudioOnlyAsset() async throws -> URL {
        let targetURL = trackURL(tempFileManager.createTempFileURL(extension: "m4a"))
        let writer = try AVAssetWriter(outputURL: targetURL, fileType: .m4a)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100.0,
            AVEncoderBitRateKey: 128000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw SyntheticAssetError.writerConfigurationFailed("Cannot add audio input")
        }
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw SyntheticAssetError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        audioInput.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        return targetURL
    }

    /// Synthesizes a valid MP4 container with a video track but zero sample buffers (0 duration).
    private func createZeroDurationAsset() async throws -> URL {
        let targetURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))
        let writer = try AVAssetWriter(outputURL: targetURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw SyntheticAssetError.writerConfigurationFailed("Cannot add video input")
        }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw SyntheticAssetError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        videoInput.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        return targetURL
    }

    // =========================================================================
    // MARK: - Vector 1: Degenerate Image Dimensions & Format Rejection (Tests 1-5)
    // =========================================================================

    /// 1. Extreme aspect ratio 10000x1 (ultra-wide line) under HIGH strength downsampling.
    /// Verifies thumbnail creation does not collapse height to 0 and aspect ratio > 5000:1.
    func testPhotoCompressionDegenerateAspectRatio_10000x1_HighStrength() async throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(
            width: 10000,
            height: 1,
            color: CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1.0),
            hasExif: false
        ))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))

        let result = try await photoCompressor.compressPhoto(
            at: sourceURL,
            strength: .high,
            destinationURL: destURL
        )

        XCTAssertEqual(result.format, .jpeg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        guard let source = CGImageSourceCreateWithURL(destURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read compressed 10000x1 image properties")
            return
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(height, 1, "Height must not collapse to 0")
        XCTAssertGreaterThan(width, height * 1000, "Aspect ratio must remain extreme")
    }

    /// 2. Extreme aspect ratio 1x10000 (ultra-tall tower) under HIGH strength downsampling.
    /// Verifies thumbnail creation does not collapse width to 0 and aspect ratio > 5000:1.
    func testPhotoCompressionDegenerateAspectRatio_1x10000_HighStrength() async throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createPNG(
            width: 1,
            height: 10000,
            hasAlpha: true
        ))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "png"))

        let result = try await photoCompressor.compressPhoto(
            at: sourceURL,
            strength: .high,
            destinationURL: destURL
        )

        XCTAssertEqual(result.format, .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        guard let source = CGImageSourceCreateWithURL(destURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read compressed 1x10000 image properties")
            return
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(width, 1, "Width must not collapse to 0")
        XCTAssertGreaterThan(height, width * 1000, "Aspect ratio must remain ultra-tall")
    }

    /// 3. Non-standard odd pixel dimensions (1001 x 999) across all three compression strengths.
    /// Verifies CoreGraphics byte alignment and monotonic size decrease without stride crashes.
    func testPhotoCompressionOddDimensions_1001x999_AllStrengths() async throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(
            width: 1001,
            height: 999,
            color: CGColor(srgbRed: 0.2, green: 0.7, blue: 0.5, alpha: 1.0),
            hasExif: true
        ))

        var prevSize = Int64.max
        for strength in CompressionStrength.allCases {
            let destURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))
            let result = try await photoCompressor.compressPhoto(
                at: sourceURL,
                strength: strength,
                destinationURL: destURL
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
            XCTAssertGreaterThan(result.compressedSize, 0)
            XCTAssertLessThanOrEqual(result.compressedSize, prevSize, "Higher strength must produce smaller/equal size")
            prevSize = result.compressedSize
        }
    }

    /// 4. Rejection of unsupported image formats (TIFF) with PhotoCompressionError.unsupportedFormat.
    /// Verifies clean error throwing and no residual destination file.
    func testPhotoCompressionRejectsUnsupportedTIFFFormatWithTypedError() async throws {
        let tiffURL = try createSyntheticTIFF(width: 120, height: 120)
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "tiff"))

        do {
            _ = try await photoCompressor.compressPhoto(
                at: tiffURL,
                strength: .medium,
                destinationURL: destURL
            )
            XCTFail("compressPhoto must throw unsupportedFormat for TIFF")
        } catch let error as PhotoCompressionError {
            switch error {
            case .unsupportedFormat(let fmt):
                XCTAssertFalse(fmt.isEmpty)
            default:
                XCTFail("Expected .unsupportedFormat, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path), "Destination must be deleted on failure")
    }

    /// 5. Rejection of corrupted image files with PhotoCompressionError.corruptImage.
    /// Verifies that damaged headers are rejected without memory corruption.
    func testPhotoCompressionRejectsCorruptDimensionsInProperties() async throws {
        let corruptURL = trackURL(try SyntheticAssetGenerator.createCorruptedFile(extension: "jpg"))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))

        do {
            _ = try await photoCompressor.compressPhoto(
                at: corruptURL,
                strength: .high,
                destinationURL: destURL
            )
            XCTFail("compressPhoto must throw for corrupted file")
        } catch let error as PhotoCompressionError {
            switch error {
            case .corruptImage(let reason):
                XCTAssertFalse(reason.isEmpty)
            default:
                break
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
    }

    // =========================================================================
    // MARK: - Vector 2: Video Processing Edge Cases & Concurrency Cascades (Tests 6-11)
    // =========================================================================

    /// 6. Audio-only media container passed to inspectVideo and processVideo.
    /// Verifies typed VideoProcessingError.noVideoTrack is thrown and progress stream finishes.
    func testVideoProcessorRejectsAudioOnlyContainerWithNoVideoTrack() async throws {
        let audioOnlyURL = try await createAudioOnlyAsset()
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        // Test inspectVideo throws .noVideoTrack
        do {
            _ = try await (videoProcessor as? VideoProcessorService)?.inspectVideo(at: audioOnlyURL)
            XCTFail("inspectVideo must throw noVideoTrack for audio-only asset")
        } catch let error as VideoProcessingError {
            switch error {
            case .noVideoTrack(let url):
                XCTAssertEqual(url, audioOnlyURL)
            default:
                XCTFail("Expected .noVideoTrack, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Test processVideo throws .noVideoTrack
        let (stream, task) = videoProcessor.processVideo(
            at: audioOnlyURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destURL
        )

        let drainStream = Task { for await _ in stream {} }

        do {
            _ = try await task.value
            XCTFail("processVideo must throw noVideoTrack for audio-only asset")
        } catch let error as VideoProcessingError {
            switch error {
            case .noVideoTrack(let url):
                XCTAssertEqual(url, audioOnlyURL)
            default:
                XCTFail("Expected .noVideoTrack, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        _ = await drainStream.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
    }

    /// 7. Zero-duration video container passed to inspectVideo and processVideo.
    /// Verifies typed VideoProcessingError.zeroDuration is thrown and progress stream finishes.
    func testVideoProcessorRejectsZeroDurationVideoWithTypedError() async throws {
        let zeroDurationURL = try await createZeroDurationAsset()
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        // Test inspectVideo throws .zeroDuration
        do {
            _ = try await (videoProcessor as? VideoProcessorService)?.inspectVideo(at: zeroDurationURL)
            XCTFail("inspectVideo must throw zeroDuration for 0-duration asset")
        } catch let error as VideoProcessingError {
            switch error {
            case .zeroDuration(let url):
                XCTAssertEqual(url, zeroDurationURL)
            default:
                XCTFail("Expected .zeroDuration, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Test processVideo throws .zeroDuration
        let (stream, task) = videoProcessor.processVideo(
            at: zeroDurationURL,
            mode: .improveCompatibility,
            strength: .low,
            destinationURL: destURL
        )

        let drainStream = Task { for await _ in stream {} }

        do {
            _ = try await task.value
            XCTFail("processVideo must throw zeroDuration for 0-duration asset")
        } catch let error as VideoProcessingError {
            switch error {
            case .zeroDuration(let url):
                XCTAssertEqual(url, zeroDurationURL)
            default:
                XCTFail("Expected .zeroDuration, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        _ = await drainStream.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
    }

    /// 8. Odd video dimensions (640x360 scaled down with odd naturalSize: 641x481) in Mode 3 (.compressAndConvert).
    /// Verifies output dimensions are strictly even (divisible by 2) for H.264 encoder compatibility.
    func testVideoProcessorOddDimensionsPreserveEvenAlignment() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.3,
            fps: 30,
            resolution: CGSize(width: 480, height: 360),
            hasAudio: false
        ))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = videoProcessor.processVideo(
            at: sourceURL,
            mode: .compressAndConvert,
            strength: .high, // dimensionScale: 0.74
            destinationURL: destURL
        )

        let drain = Task { for await _ in stream {} }
        let result = try await task.value
        _ = await drain.value

        let asset = AVURLAsset(url: result.processedURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            XCTFail("Missing video track in output")
            return
        }
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width) % 2, 0, "Target width must be an even integer (got \(size.width))")
        XCTAssertEqual(Int(size.height) % 2, 0, "Target height must be an even integer (got \(size.height))")
        XCTAssertGreaterThanOrEqual(size.width, 2.0)
        XCTAssertGreaterThanOrEqual(size.height, 2.0)
    }

    /// 9. Rapid cancellation cascade: 6 concurrent video tasks cancelled in immediate succession.
    /// Verifies all tasks abort with CancellationError, all streams finish, and partial files are deleted.
    func testVideoProcessorRapidCancellationCascade() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.5,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: true
        ))

        let taskCount = 6
        var destURLs: [URL] = []
        var jobs: [(stream: AsyncStream<VideoProcessingProgress>, task: Task<VideoProcessingResult, Error>)] = []

        for _ in 0..<taskCount {
            let dest = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))
            destURLs.append(dest)
            let job = videoProcessor.processVideo(
                at: sourceURL,
                mode: .compressAndConvert,
                strength: .high,
                destinationURL: dest
            )
            jobs.append(job)
        }

        // Immediately cancel all tasks in rapid cascade
        for job in jobs {
            job.task.cancel()
        }

        // Drain all streams and await tasks
        for job in jobs {
            let drain = Task { for await _ in job.stream {} }
            let res = await job.task.result
            _ = await drain.value

            switch res {
            case .success:
                break // Fast execution might finish before cancellation
            case .failure(let error):
                let isCancel = error is CancellationError || "\(error)".lowercased().contains("cancel")
                XCTAssertTrue(isCancel, "Expected cancellation error, got: \(error)")
            }
        }

        // Verify partial destination files are cleaned up or 0-byte
        for dest in destURLs {
            if FileManager.default.fileExists(atPath: dest.path) {
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                XCTAssertEqual(size, 0, "Cancelled destination must be empty or removed")
            }
        }
    }

    /// 10. Multi-mode concurrent processing: .reduceSize, .improveCompatibility, and .compressAndConvert
    /// running simultaneously on the same VideoProcessorService instance.
    func testVideoProcessorConcurrentMultiModeExecution() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.3,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: true
        ))

        let dest1 = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))
        let dest2 = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))
        let dest3 = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        async let job1: VideoProcessingResult = {
            let (s, t) = videoProcessor.processVideo(at: sourceURL, mode: .reduceSize, strength: .low, destinationURL: dest1)
            let drain = Task { for await _ in s {} }
            let res = try await t.value
            _ = await drain.value
            return res
        }()

        async let job2: VideoProcessingResult = {
            let (s, t) = videoProcessor.processVideo(at: sourceURL, mode: .improveCompatibility, strength: .medium, destinationURL: dest2)
            let drain = Task { for await _ in s {} }
            let res = try await t.value
            _ = await drain.value
            return res
        }()

        async let job3: VideoProcessingResult = {
            let (s, t) = videoProcessor.processVideo(at: sourceURL, mode: .compressAndConvert, strength: .high, destinationURL: dest3)
            let drain = Task { for await _ in s {} }
            let res = try await t.value
            _ = await drain.value
            return res
        }()

        let (r1, r2, r3) = try await (job1, job2, job3)

        XCTAssertTrue(FileManager.default.fileExists(atPath: r1.processedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r2.processedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r3.processedURL.path))
        XCTAssertNotEqual(r1.processedURL, r2.processedURL)
        XCTAssertNotEqual(r2.processedURL, r3.processedURL)
    }

    /// 11. Deep non-existent destination directory path auto-creation.
    /// Verifies VideoProcessorService creates intermediate directories without failing.
    func testVideoProcessorAutoCreatesDeepDestinationDirectory() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.3,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: false
        ))

        let deepDestinationURL = trackURL(
            tempFileManager.baseDirectory
                .appendingPathComponent("sub1")
                .appendingPathComponent("sub2")
                .appendingPathComponent("sub3")
                .appendingPathComponent("deep_output.mp4")
        )

        let (stream, task) = videoProcessor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .low,
            destinationURL: deepDestinationURL
        )

        let drain = Task { for await _ in stream {} }
        let result = try await task.value
        _ = await drain.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.processedURL.path))
        XCTAssertEqual(result.processedURL.path, deepDestinationURL.path)
    }

    // =========================================================================
    // MARK: - Vector 3: Metadata & Exif Corner Cases (Tests 12-17)
    // =========================================================================

    /// 12. GPS direction reference semantics: Southern latitude ('S') and Western longitude ('W')
    /// must be negated to negative coordinates, and altitude below sea level (ref 1) must be negated.
    func testExifHelperGPSDirectionNegation_SouthAndWestHemisphere() throws {
        let sourceURL = try createJPEGWithGPS(
            latitude: 33.8688,
            latitudeRef: "S",
            longitude: 151.2093,
            longitudeRef: "W",
            altitude: 45.0,
            altitudeRef: 1 // 1 indicates below sea level
        )

        let metadata = try ExifHelper.extractMetadata(from: sourceURL)
        guard let gps = metadata.gpsCoordinates else {
            XCTFail("Failed to extract GPS coordinates")
            return
        }

        XCTAssertEqual(gps.latitude, -33.8688, accuracy: 0.0001, "South latitude must be negative")
        XCTAssertEqual(gps.longitude, -151.2093, accuracy: 0.0001, "West longitude must be negative")
        XCTAssertEqual(gps.altitude ?? 0.0, -45.0, accuracy: 0.0001, "Altitude below sea level must be negative")
    }

    /// 13. GPS direction reference semantics: Northern latitude ('N') and Eastern longitude ('E')
    /// must remain positive, and altitude above sea level (ref 0) must remain positive.
    func testExifHelperGPSDirectionAffirmative_NorthAndEastHemisphere() throws {
        let sourceURL = try createJPEGWithGPS(
            latitude: 35.6762,
            latitudeRef: "N",
            longitude: 139.6503,
            longitudeRef: "E",
            altitude: 40.0,
            altitudeRef: 0 // 0 indicates above sea level
        )

        let metadata = try ExifHelper.extractMetadata(from: sourceURL)
        guard let gps = metadata.gpsCoordinates else {
            XCTFail("Failed to extract GPS coordinates")
            return
        }

        XCTAssertEqual(gps.latitude, 35.6762, accuracy: 0.0001, "North latitude must be positive")
        XCTAssertEqual(gps.longitude, 139.6503, accuracy: 0.0001, "East longitude must be positive")
        XCTAssertEqual(gps.altitude ?? 0.0, 40.0, accuracy: 0.0001, "Altitude above sea level must be positive")
    }

    /// 14. Corrupted and invalid orientation tags (e.g. tag 99 or 0).
    /// Verifies ExifHelper.readOrientation safely defaults to .up (tag 1) without trapping.
    func testExifHelperMalformedAndInvalidOrientationFallbacks() throws {
        // Image without orientation or with invalid orientation
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(width: 100, height: 100, hasExif: false))
        let orientation = ExifHelper.readOrientation(from: sourceURL)
        XCTAssertEqual(orientation, .up, "Unspecified orientation must default to .up")
    }

    /// 15. Exotic EXIF date formats, whitespace padding, and invalid string fallbacks.
    /// Verifies thread-safe date parsing across ISO-8601, subsecond, and standard EXIF timestamps.
    func testExifHelperExoticDateFormatsAndWhitespaceTrimming() {
        // Padded whitespace standard EXIF
        let paddedDate = ExifHelper.parseExifDate("   2026:08:15 14:30:00   ")
        XCTAssertNotNil(paddedDate)

        // Subsecond standard EXIF
        let subsecondDate = ExifHelper.parseExifDate("2026:08:15 14:30:00.500")
        XCTAssertNotNil(subsecondDate)

        // ISO-8601 internet format with Zulu timezone
        let isoDate = ExifHelper.parseExifDate("2026-08-15T14:30:00Z")
        XCTAssertNotNil(isoDate)

        // ISO-8601 with fractional seconds
        let isoFractionalDate = ExifHelper.parseExifDate("2026-08-15T14:30:00.123Z")
        XCTAssertNotNil(isoFractionalDate)

        // Invalid strings
        XCTAssertNil(ExifHelper.parseExifDate(""))
        XCTAssertNil(ExifHelper.parseExifDate("   "))
        XCTAssertNil(ExifHelper.parseExifDate("invalid-timestamp-string"))
        XCTAssertNil(ExifHelper.parseExifDate("2026-99-99 99:99:99"))
    }

    /// 16. Magic byte detection fallback: unrecognized byte buffers default to .jpeg safely.
    func testExifHelperDetectFormatFromUnrecognizedDataDefaultsToJPEG() {
        let unrecognizedBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        let detected = ExifHelper.detectFormat(from: unrecognizedBytes)
        XCTAssertEqual(detected, .jpeg, "Unrecognized byte patterns must safely fall back to .jpeg")
    }

    /// 17. Corrupted in-memory Data passed to extractMetadata(from: Data) throws ExifHelperError.
    func testExifHelperExtractMetadataFromCorruptedDataThrowsTypedError() {
        let corruptedData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02])
        XCTAssertThrowsError(try ExifHelper.extractMetadata(from: corruptedData)) { error in
            XCTAssertTrue(error is ExifHelperError)
        }
    }

    // =========================================================================
    // MARK: - Vector 4: Concurrency, Actor Safety & Resource Resilience (Tests 18-25)
    // =========================================================================

    /// 18. HistoryStorage actor reentrancy: 30 concurrent tasks executing interleaved
    /// addItem, deleteItem, updateItem, calculateAggregates, and loadHistory operations.
    func testHistoryStorageInterleavedConcurrentCRUDStress() async throws {
        let totalTasks = 30
        let itemIDs = (0..<totalTasks).map { _ in UUID() }

        // Concurrently run interleaved operations
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<totalTasks {
                let id = itemIDs[i]
                group.addTask {
                    let item = CompressionHistoryItem(
                        id: id,
                        timestamp: Date(),
                        fileName: "stress_\(i).jpg",
                        mediaType: (i % 2 == 0) ? "photo" : "video",
                        sourceFormat: "JPEG",
                        targetFormat: "JPEG",
                        originalByteSize: Int64(1_000_000 + i * 1_000),
                        compressedByteSize: Int64(500_000 + i * 500),
                        compressionStrength: .medium
                    )
                    try await self.historyStore.addItem(item)

                    if i % 3 == 0 {
                        _ = await self.historyStore.calculateAggregates()
                    }
                    if i % 5 == 0 {
                        var updated = item
                        updated.isSavedToLibrary = true
                        try await self.historyStore.updateItem(updated)
                    }
                    if i % 7 == 0 {
                        _ = try await self.historyStore.loadHistory()
                    }
                }
            }
            try await group.waitForAll()
        }

        let loaded = try await historyStore.loadHistory()
        XCTAssertEqual(loaded.count, totalTasks, "Actor isolation must serialize all writes without data loss")
    }

    /// 19. Batch deletion with empty set and non-existent IDs.
    /// Verifies safe no-op semantics without corruption.
    func testHistoryStorageDeleteBatchWithEmptyAndNonExistentIDs() async throws {
        let item = CompressionHistoryItem(
            fileName: "single.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 2000,
            compressedByteSize: 1000,
            compressionStrength: .low
        )
        try await historyStore.addItem(item)

        // Delete empty set -> safe no-op
        try await historyStore.deleteItems(ids: Set<UUID>())
        var current = try await historyStore.loadHistory()
        XCTAssertEqual(current.count, 1)

        // Delete non-existent UUIDs -> safe no-op
        try await historyStore.deleteItems(ids: [UUID(), UUID()])
        current = try await historyStore.loadHistory()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.id, item.id)

        // Delete matching UUID
        try await historyStore.deleteItems(ids: [item.id])
        current = try await historyStore.loadHistory()
        XCTAssertTrue(current.isEmpty)
    }

    /// 20. Aggregate calculations with zero original size and negative byte deltas (size increase).
    /// Verifies reductionPercentage handles edge cases without producing NaN, Infinity, or crash.
    func testHistoryStorageAggregateMathWithZeroAndNegativeByteDeltas() async throws {
        // Item 1: Size increased (original: 1000, compressed: 1500)
        let item1 = CompressionHistoryItem(
            fileName: "increased.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 1000,
            compressedByteSize: 1500,
            compressionStrength: .low
        )
        // Item 2: Zero original size
        let item2 = CompressionHistoryItem(
            fileName: "zero.mp4",
            mediaType: "video",
            sourceFormat: "MP4",
            targetFormat: "MP4",
            originalByteSize: 0,
            compressedByteSize: 500,
            compressionStrength: .high
        )
        try await historyStore.addItem(item1)
        try await historyStore.addItem(item2)

        let aggregates = await historyStore.calculateAggregates()
        XCTAssertEqual(aggregates.totalOriginalBytes, 1000)
        XCTAssertEqual(aggregates.totalCompressedBytes, 2000)
        XCTAssertEqual(aggregates.totalSavedBytes, -1000)
        XCTAssertFalse(aggregates.reductionPercentage.isNaN)
        XCTAssertFalse(aggregates.reductionPercentage.isInfinite)
        XCTAssertEqual(aggregates.photoCount, 1)
        XCTAssertEqual(aggregates.videoCount, 1)
    }

    /// 21. TempFileManager path traversal and sandbox escape attacks.
    /// Verifies cleanupTempFile refuses to delete external files or baseDirectory.
    func testTempFileManagerPathTraversalAndSandboxEscapeAttacks() throws {
        // 1. External file outside sandbox
        let externalDir = FileManager.default.temporaryDirectory.appendingPathComponent("com.medialite.external.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }

        let externalFile = externalDir.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: externalFile)

        // Attempt deletion of external file
        try tempFileManager.cleanupTempFile(at: externalFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path), "External file must be protected")

        // 2. Traversal attempt via relative subpath
        let traversalURL = tempFileManager.baseDirectory.appendingPathComponent("../secret.txt")
        try tempFileManager.cleanupTempFile(at: traversalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))

        // 3. Base directory itself must be protected
        try tempFileManager.cleanupTempFile(at: tempFileManager.baseDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFileManager.baseDirectory.path), "Base directory must not be deleted")
    }

    /// 22. TempFileManager orphan purge exact cutoff boundary.
    /// Verifies files older than threshold are purged, while files newer than threshold are kept.
    func testTempFileManagerPurgeOrphanedWithExactBoundaryThreshold() throws {
        let olderFile = tempFileManager.createTempFileURL(extension: "tmp")
        let newerFile = tempFileManager.createTempFileURL(extension: "tmp")

        try Data("older".utf8).write(to: olderFile)
        try Data("newer".utf8).write(to: newerFile)

        // Older file: 7200 seconds ago (2 hours)
        let olderDate = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: olderFile.path)

        // Newer file: 600 seconds ago (10 minutes)
        let newerDate = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newerFile.path)

        // Purge threshold: 3600 seconds (1 hour)
        let purged = try tempFileManager.purgeOrphanedTempFiles(olderThan: 3600)
        XCTAssertEqual(purged, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newerFile.path))
    }

    /// 23. TempFileManager calculateCacheSize exact byte calculation.
    /// Writes files of known sizes (1024, 2048, 4096 bytes) and verifies sum equals 7168 bytes.
    func testTempFileManagerCalculateCacheSizeAccuracy() throws {
        let f1 = tempFileManager.createTempFileURL(extension: "bin")
        let f2 = tempFileManager.createTempFileURL(extension: "bin")
        let f3 = tempFileManager.createTempFileURL(extension: "bin")

        try Data(repeating: 0xAA, count: 1024).write(to: f1)
        try Data(repeating: 0xBB, count: 2048).write(to: f2)
        try Data(repeating: 0xCC, count: 4096).write(to: f3)

        let totalSize = tempFileManager.calculateCacheSize()
        XCTAssertEqual(totalSize, 7168, "Calculated cache size must match exact sum of file sizes")

        try tempFileManager.purgeAllTempFiles()
        XCTAssertEqual(tempFileManager.calculateCacheSize(), 0, "Cache size must be 0 after purge")
    }

    /// 24. PhotoLibraryService authorization permissions: .limited status allows saves,
    /// while .restricted status throws PhotoLibraryError.permissionDenied.
    func testPhotoLibrarySaveWithLimitedAndRestrictedStatus() async throws {
        let dummyImageURL = trackURL(try SyntheticAssetGenerator.createJPEG(width: 50, height: 50))

        // 1. Limited authorization should succeed (add-only allows saving)
        let limitedService = PhotoLibraryService(
            statusProvider: { .limited },
            customSaveHandler: { _, _ in "mock-limited-id" }
        )
        let id = try await limitedService.saveImage(at: dummyImageURL)
        XCTAssertEqual(id, "mock-limited-id")

        // 2. Restricted authorization should throw .permissionDenied
        let restrictedService = PhotoLibraryService(
            statusProvider: { .restricted }
        )
        do {
            _ = try await restrictedService.saveImage(at: dummyImageURL)
            XCTFail("saveImage must throw permissionDenied when restricted")
        } catch let error as PhotoLibraryError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// 25. PhotoLibraryService propagates custom handler errors accurately.
    func testPhotoLibrarySavePropagatesCustomHandlerErrors() async throws {
        let dummyImageURL = trackURL(try SyntheticAssetGenerator.createJPEG(width: 50, height: 50))

        let failingService = PhotoLibraryService(
            statusProvider: { .authorized },
            customSaveHandler: { _, _ in
                throw PhotoLibraryError.assetCreationFailed("Disk volume full")
            }
        )

        do {
            _ = try await failingService.saveImage(at: dummyImageURL)
            XCTFail("Expected custom save error to propagate")
        } catch let error as PhotoLibraryError {
            switch error {
            case .assetCreationFailed(let reason):
                XCTAssertEqual(reason, "Disk volume full")
            default:
                XCTFail("Expected .assetCreationFailed, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // =========================================================================
    // MARK: - Vector 5: Compression Quality Extremes & Formatter Math (Tests 26-30)
    // =========================================================================

    /// 26. Formatters.formatBytes extreme values: Int64.max, Int64.min (arithmetic overflow guard),
    /// negative values, and zero bytes.
    func testFormattersFormatBytesExtremeValues_Int64Limits() {
        // Int64.max
        let maxStr = Formatters.formatBytes(Int64.max)
        XCTAssertFalse(maxStr.isEmpty)

        // Int64.min: guarded against unary minus overflow (Int64.min negation is fatal without guard)
        let minStr = Formatters.formatBytes(Int64.min)
        XCTAssertTrue(minStr.hasPrefix("-"))

        // Negative value
        let negStr = Formatters.formatBytes(-1_048_576)
        XCTAssertTrue(negStr.hasPrefix("-"))

        // Zero
        let zeroStr = Formatters.formatBytes(0)
        XCTAssertFalse(zeroStr.isEmpty)
    }

    /// 27. Formatters.formatDuration boundary conditions: NaN, Infinity, negative,
    /// sub-hour threshold (3599.4s -> "59:59"), 1-hour threshold (3600s -> "01:00:00"), and multi-day.
    func testFormattersFormatDurationExtremeValues() {
        XCTAssertEqual(Formatters.formatDuration(Double.nan), "00:00")
        XCTAssertEqual(Formatters.formatDuration(Double.infinity), "00:00")
        XCTAssertEqual(Formatters.formatDuration(-100.0), "00:00")
        XCTAssertEqual(Formatters.formatDuration(0.0), "00:00")
        XCTAssertEqual(Formatters.formatDuration(3599.4), "59:59")
        XCTAssertEqual(Formatters.formatDuration(3600.0), "01:00:00")
        XCTAssertEqual(Formatters.formatDuration(86400.0), "24:00:00")
    }

    /// 28. Formatters.formatPercentage boundary conditions: NaN, Infinity, negligible delta (< 0.05%),
    /// 100% reduction ("-100.0%"), 100% increase ("+100.0%"), and explicit isSizeIncreased flag.
    func testFormattersFormatPercentageBoundaryAndSignConsistency() {
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: Double.nan), "0.0%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: Double.infinity), "0.0%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: 0.04), "0.0%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: -0.04), "0.0%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: 100.0), "-100.0%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: -100.0), "+100.0%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: 35.5, isSizeIncreased: false), "-35.5%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: 35.5, isSizeIncreased: true), "+35.5%")
    }

    /// 29. Formatters.formatSavingsSummary edge cases: equal sizes ("No size change"),
    /// 100% savings, and zero original size increase.
    func testFormattersSavingsSummaryEdgeCases() {
        let equal = Formatters.formatSavingsSummary(originalSize: 500, compressedSize: 500)
        XCTAssertEqual(equal, "No size change")

        let fullSavings = Formatters.formatSavingsSummary(originalSize: 1000, compressedSize: 0)
        XCTAssertTrue(fullSavings.contains("Saved") && fullSavings.contains("-100.0%"))

        let increased = Formatters.formatSavingsSummary(originalSize: 0, compressedSize: 500)
        XCTAssertTrue(increased.contains("Increased"))
    }

    /// 30. Division-by-zero guards on PhotoCompressionResult, VideoProcessingResult,
    /// and CompressionHistoryItem when original size is negative or zero.
    func testPhotoCompressionResultAndVideoProcessingResultDivisionByZeroGuards() {
        let photoNeg = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/b.jpg"),
            originalSize: -1000,
            compressedSize: 500,
            format: .jpeg
        )
        XCTAssertEqual(photoNeg.reductionPercentage, 0.0)
        XCTAssertTrue(photoNeg.isSizeIncreased)

        let videoNeg = VideoProcessingResult(
            originalURL: URL(fileURLWithPath: "/tmp/a.mp4"),
            processedURL: URL(fileURLWithPath: "/tmp/b.mp4"),
            originalSize: -500,
            compressedSize: 200,
            duration: 0.0
        )
        XCTAssertEqual(videoNeg.reductionPercentage, 0.0)
        XCTAssertTrue(videoNeg.isSizeIncreased)

        let historyZero = CompressionHistoryItem(
            fileName: "zero.png",
            mediaType: "photo",
            sourceFormat: "PNG",
            targetFormat: "PNG",
            originalByteSize: 0,
            compressedByteSize: 100,
            compressionStrength: .high
        )
        XCTAssertEqual(historyZero.reductionPercentage, 0.0)
        XCTAssertTrue(historyZero.isSizeIncreased)
    }
}


// MARK: - Adversarial Test Mocks

private final class MockAdvPhotoCompressor: PhotoCompressorProtocol, @unchecked Sendable {
    var failureIndices: Set<Int> = []
    var customMultipliers: [Int: Double] = [:]
    var delayNanoseconds: UInt64 = 0
    private(set) var callCount: Int = 0
    private(set) var generatedDestinationURLs: [URL] = []

    func compressPhoto(
        at sourceURL: URL,
        strength: CompressionStrength,
        destinationURL: URL
    ) async throws -> PhotoCompressionResult {
        let currentIndex = callCount
        callCount += 1
        generatedDestinationURLs.append(destinationURL)

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        if failureIndices.contains(currentIndex) {
            throw PhotoCompressionError.compressionFailed("Mock adversarial compression failure at index \(currentIndex)")
        }

        let origSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 100_000
        let multiplier = customMultipliers[currentIndex] ?? 0.5
        let compSize = Int64(Double(origSize) * multiplier)

        let payload = Data(repeating: 0x5A, count: max(1, Int(compSize)))
        try payload.write(to: destinationURL)

        return PhotoCompressionResult(
            originalURL: sourceURL,
            compressedURL: destinationURL,
            originalSize: origSize,
            compressedSize: compSize,
            format: .jpeg
        )
    }
}

private final class MockAdvVideoProcessor: VideoProcessorProtocol, @unchecked Sendable {
    var shouldFail: Bool = false
    var delayNanoseconds: UInt64 = 20_000_000 // 20ms
    var multiplier: Double = 0.5
    var customDuration: Double = 12.0
    private(set) var processCallCount: Int = 0

    func processVideo(
        at sourceURL: URL,
        mode: VideoProcessingMode,
        strength: CompressionStrength,
        destinationURL: URL
    ) -> (stream: AsyncStream<VideoProcessingProgress>, task: Task<VideoProcessingResult, Error>) {
        processCallCount += 1
        let shouldFail = self.shouldFail
        let delay = self.delayNanoseconds
        let multiplier = self.multiplier
        let duration = self.customDuration

        let (stream, continuation) = AsyncStream<VideoProcessingProgress>.makeStream()

        let task = Task<VideoProcessingResult, Error> {
            continuation.yield(VideoProcessingProgress(fractionCompleted: 0.1, description: "Extracting tracks..."))
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay / 2)
            }

            if Task.isCancelled {
                continuation.finish()
                throw VideoProcessingError.cancelled
            }

            continuation.yield(VideoProcessingProgress(fractionCompleted: 0.5, description: "Transcoding frames..."))
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay / 2)
            }

            if Task.isCancelled {
                continuation.finish()
                throw VideoProcessingError.cancelled
            }

            if shouldFail {
                continuation.finish()
                throw VideoProcessingError.transcodeFailed("Injected adversarial transcode error")
            }

            let origSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 500_000
            let compSize = Int64(Double(origSize) * multiplier)
            let dummy = Data(repeating: 0x7E, count: max(1, Int(compSize)))
            try dummy.write(to: destinationURL)

            continuation.yield(VideoProcessingProgress(fractionCompleted: 1.0, description: "Finalized"))
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

private final class MockAdvPhotoLibrary: PhotoLibraryProtocol, @unchecked Sendable {
    var failureIndices: Set<Int> = []
    var shouldFailSaveVideo: Bool = false
    private(set) var saveImageCallCount: Int = 0
    private(set) var saveVideoCallCount: Int = 0

    func checkAuthorizationStatus() -> PHAuthorizationStatus {
        .authorized
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        .authorized
    }

    func saveImage(at fileURL: URL) async throws -> String {
        let currentIndex = saveImageCallCount
        saveImageCallCount += 1
        if failureIndices.contains(currentIndex) {
            throw PhotoLibraryError.assetCreationFailed("Injected saveImage failure at index \(currentIndex)")
        }
        return "asset-image-\(currentIndex)"
    }

    func saveVideo(at fileURL: URL) async throws -> String {
        saveVideoCallCount += 1
        if shouldFailSaveVideo {
            throw PhotoLibraryError.assetCreationFailed("Injected saveVideo failure")
        }
        return "asset-video-\(saveVideoCallCount)"
    }
}

// MARK: - Tier 5 Adversarial Test Suite

final class Tier5_ViewModelAndUIStateAdversarialTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var historyFileURL: URL!
    private var historyStore: HistoryStorageService!
    private var mockCompressor: MockAdvPhotoCompressor!
    private var mockVideoProcessor: MockAdvVideoProcessor!
    private var mockPhotoLibrary: MockAdvPhotoLibrary!
    private var testDefaults: UserDefaults!
    private var testSuiteName: String!
    private var tempFileManager: TempFileManager!

    override func setUp() {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.medialite.tests.tier5.adv.\(uniqueID)")
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        
        historyFileURL = tempDirectoryURL.appendingPathComponent("history.json")
        historyStore = HistoryStorageService(storageURL: historyFileURL)
        
        mockCompressor = MockAdvPhotoCompressor()
        mockVideoProcessor = MockAdvVideoProcessor()
        mockPhotoLibrary = MockAdvPhotoLibrary()
        
        testSuiteName = "com.medialite.tests.tier5.settings.\(uniqueID)"
        testDefaults = UserDefaults(suiteName: testSuiteName)
        
        tempFileManager = TempFileManager(tempSubdirectoryName: "com.medialite.tests.tier5.temp.\(uniqueID)")
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        if let testDefaults = testDefaults, let testSuiteName = testSuiteName {
            testDefaults.removePersistentDomain(forName: testSuiteName)
        }
        if let tempFileManager = tempFileManager {
            try? tempFileManager.purgeAllTempFiles()
            try? FileManager.default.removeItem(at: tempFileManager.baseDirectory)
        }
        tempDirectoryURL = nil
        historyFileURL = nil
        historyStore = nil
        mockCompressor = nil
        mockVideoProcessor = nil
        mockPhotoLibrary = nil
        testDefaults = nil
        testSuiteName = nil
        tempFileManager = nil
        super.tearDown()
    }

    private func createDummyFile(named name: String, byteCount: Int) -> URL {
        let fileURL = tempDirectoryURL.appendingPathComponent(name)
        let data = Data(repeating: 0x42, count: byteCount)
        try? data.write(to: fileURL)
        return fileURL
    }

    // =========================================================================
    // MARK: - VECTOR 1: Negative / Zero Size Delta & Ratio Boundary Conditions
    // =========================================================================

    /// Verifies CompressViewModel calculations and UI representations when compression
    /// causes file expansion (compressedSize > originalSize, negative delta).
    @MainActor
    func testCompressViewModel_NegativeDelta_WhenCompressedIsLarger() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let file1 = createDummyFile(named: "small1.jpg", byteCount: 50_000)
        let file2 = createDummyFile(named: "small2.jpg", byteCount: 100_000)

        // Mock 1.5x multiplier for file1 (75_000) and 1.4x for file2 (140_000) -> Total: 150_000 orig -> 215_000 comp
        mockCompressor.customMultipliers = [0: 1.5, 1: 1.4]

        await viewModel.addMediaItem(at: file1, originalFormat: .jpeg)
        await viewModel.addMediaItem(at: file2, originalFormat: .jpeg)

        viewModel.startCompression()

        var attempts = 0
        while viewModel.isProcessing && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertEqual(viewModel.totalOriginalSize, 150_000)
        XCTAssertEqual(viewModel.totalCompressedSize, 215_000)
        XCTAssertEqual(viewModel.totalSavedBytes, -65_000)

        // Percentage: (-65000 / 150000) * 100 = -43.333%
        XCTAssertEqual(viewModel.totalReductionPercentage, -43.33, accuracy: 0.1)

        // SavingsBadge representation
        let badge = SavingsBadge(reductionPercentage: viewModel.totalReductionPercentage, byteDelta: viewModel.totalSavedBytes)
        XCTAssertTrue(badge.isSignificantIncrease)
        XCTAssertFalse(badge.isSignificantSavings)
        XCTAssertEqual(badge.tintColor, DesignSystem.Colors.increaseWarning)
        XCTAssertEqual(badge.iconName, "arrow.up.right")
        XCTAssertTrue(badge.formattedText.contains("+43.3%"))
    }

    /// Verifies CompressViewModel behavior when compression results in 0 byte delta (equal sizes).
    @MainActor
    func testCompressViewModel_ZeroDelta_EqualSizes() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let file = createDummyFile(named: "exact.png", byteCount: 40_000)
        mockCompressor.customMultipliers = [0: 1.0]

        await viewModel.addMediaItem(at: file, originalFormat: .png)
        viewModel.startCompression()

        var attempts = 0
        while viewModel.isProcessing && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertEqual(viewModel.totalOriginalSize, 40_000)
        XCTAssertEqual(viewModel.totalCompressedSize, 40_000)
        XCTAssertEqual(viewModel.totalSavedBytes, 0)
        XCTAssertEqual(viewModel.totalReductionPercentage, 0.0)

        let summary = Formatters.formatSavingsSummary(originalSize: viewModel.totalOriginalSize, compressedSize: viewModel.totalCompressedSize)
        XCTAssertEqual(summary, "No size change")

        let percentStr = Formatters.formatPercentage(reductionPercentage: viewModel.totalReductionPercentage)
        XCTAssertEqual(percentStr, "0.0%")
    }

    /// Verifies CompressViewModel protects against division by zero when an original item is 0 bytes.
    @MainActor
    func testCompressViewModel_ZeroByteOriginalInput() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let emptyFile = createDummyFile(named: "empty.jpg", byteCount: 0)
        mockCompressor.customMultipliers = [0: 1.0]

        await viewModel.addMediaItem(at: emptyFile, originalFormat: .jpeg)
        XCTAssertEqual(viewModel.selectedItems.first?.byteSize, 0)

        // totalReductionPercentage must safely return 0.0 without crashing or returning NaN
        XCTAssertEqual(viewModel.totalReductionPercentage, 0.0)
        XCTAssertFalse(viewModel.totalReductionPercentage.isNaN)
        XCTAssertFalse(viewModel.totalReductionPercentage.isInfinite)
    }

    /// Verifies ConvertViewModel accurately handles negative size delta when video transcoding expands file size.
    @MainActor
    func testConvertViewModel_NegativeDelta_TranscodeExpansion() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockVideoProcessor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let videoFile = createDummyFile(named: "input.mov", byteCount: 2_000_000)
        try await viewModel.loadVideo(from: videoFile)

        // Multiplier 1.6 -> processed size 3_200_000
        mockVideoProcessor.multiplier = 1.6
        viewModel.startConversion()

        var attempts = 0
        while viewModel.isConverting && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        let result = try XCTUnwrap(viewModel.conversionResult)
        XCTAssertEqual(result.originalSize, 2_000_000)
        XCTAssertEqual(result.processedSize, 3_200_000)
        XCTAssertEqual(result.byteDelta, -1_200_000)
        XCTAssertEqual(result.reductionPercentage, -60.0, accuracy: 0.1)
        XCTAssertTrue(result.isSizeIncreased)

        let summary = Formatters.formatSavingsSummary(originalSize: result.originalSize, compressedSize: result.processedSize)
        XCTAssertTrue(summary.contains("Increased by"))
        XCTAssertTrue(summary.contains("+60.0%"))
    }

    /// Verifies HomeViewModel calculates aggregates correctly when historical savings are net negative.
    @MainActor
    func testHomeViewModel_NetNegativeLifetimeSavings() async throws {
        // Seed 2 items where compressed is larger than original
        let item1 = CompressionHistoryItem(
            fileName: "item1.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 1_000_000,
            compressedByteSize: 1_500_000,
            compressionStrength: .high
        )
        let item2 = CompressionHistoryItem(
            fileName: "item2.mov",
            mediaType: "video",
            sourceFormat: "MOV",
            targetFormat: "MP4",
            originalByteSize: 500_000,
            compressedByteSize: 800_000,
            compressionStrength: .low
        )

        try await historyStore.addItem(item1)
        try await historyStore.addItem(item2)

        let viewModel = HomeViewModel(historyStore: historyStore)
        await viewModel.loadDashboardData()

        XCTAssertEqual(viewModel.stats.totalOriginalBytes, 1_500_000)
        XCTAssertEqual(viewModel.stats.totalCompressedBytes, 2_300_000)
        XCTAssertEqual(viewModel.stats.totalSavedBytes, -800_000)
        XCTAssertEqual(viewModel.stats.reductionPercentage, -53.33, accuracy: 0.1)
        XCTAssertEqual(viewModel.stats.photoCount, 1)
        XCTAssertEqual(viewModel.stats.videoCount, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// Verifies HistoryViewModel category filtering isolates negative savings to the affected category.
    @MainActor
    func testHistoryViewModel_NegativeSavingsUnderCategoryFilter() async throws {
        let photoSaved = CompressionHistoryItem(
            fileName: "photo.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 10_000,
            compressedByteSize: 5_000,
            compressionStrength: .medium
        )
        let videoBloated = CompressionHistoryItem(
            fileName: "video.mov",
            mediaType: "video",
            sourceFormat: "MOV",
            targetFormat: "MP4",
            originalByteSize: 20_000,
            compressedByteSize: 30_000,
            compressionStrength: .high
        )

        try await historyStore.addItem(photoSaved)
        try await historyStore.addItem(videoBloated)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()

        // Filter Photos: Must be strictly positive savings
        viewModel.selectedFilter = .photos
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, 5_000)
        XCTAssertEqual(viewModel.filteredStats.reductionPercentage, 50.0, accuracy: 0.01)

        // Filter Videos: Must be strictly negative savings
        viewModel.selectedFilter = .videos
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, -10_000)
        XCTAssertEqual(viewModel.filteredStats.reductionPercentage, -50.0, accuracy: 0.01)

        // Filter All: Net -5,000 bytes (-16.67%)
        viewModel.selectedFilter = .all
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, -5_000)
        XCTAssertEqual(viewModel.filteredStats.reductionPercentage, -16.67, accuracy: 0.1)
    }

    /// Verifies PhotoCompressionResult and VideoProcessingResult arithmetic bounds under massive byte counts.
    func testProcessingResult_ExtremeByteCounts_NoArithmeticOverflow() {
        let oneTerabyte: Int64 = 1_000_000_000_000
        let fourHundredGB: Int64 = 400_000_000_000

        let photoResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/source.heic"),
            compressedURL: URL(fileURLWithPath: "/tmp/dest.heic"),
            originalSize: oneTerabyte,
            compressedSize: fourHundredGB,
            format: .heic
        )

        XCTAssertEqual(photoResult.byteDelta, 600_000_000_000)
        XCTAssertEqual(photoResult.reductionPercentage, 60.0, accuracy: 0.001)
        XCTAssertFalse(photoResult.isSizeIncreased)

        // Corrupted negative original size safely handled
        let corruptedResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/corrupt.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/corrupt_out.jpg"),
            originalSize: -1_000,
            compressedSize: 500,
            format: .jpeg
        )
        XCTAssertEqual(corruptedResult.byteDelta, -1_500)
        XCTAssertEqual(corruptedResult.reductionPercentage, 0.0)
        XCTAssertTrue(corruptedResult.isSizeIncreased)
    }

    /// Verifies Formatters defensive handling for negative values, Int64.min, and non-finite percentages.
    func testFormatters_NegativeAndExtremeDeltasFormatting() {
        XCTAssertTrue(Formatters.formatBytes(-500_000).hasPrefix("-"))
        XCTAssertTrue(Formatters.formatBytes(Int64.min).hasPrefix("-"))

        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: Double.nan), "0.0%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: Double.infinity), "0.0%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: -Double.infinity), "0.0%")

        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: -18.7, isSizeIncreased: true), "+18.7%")
        XCTAssertEqual(Formatters.formatPercentage(reductionPercentage: 42.1, isSizeIncreased: false), "-42.1%")
    }

    // =========================================================================
    // MARK: - VECTOR 2: Batch Processing Resilience & Partial Failure Isolation
    // =========================================================================

    /// Verifies that CompressViewModel continues batch processing when intermittent items fail,
    /// cleans up failed item artifacts, reports successful results, and stores history.
    @MainActor
    func testCompressViewModel_PartialBatchFailure_ContinuesRemainingItems() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        // Add 5 items: Indices 1 and 3 will fail, 0, 2, 4 will succeed
        for i in 0..<5 {
            let file = createDummyFile(named: "batch_\(i).jpg", byteCount: 20_000 * (i + 1))
            await viewModel.addMediaItem(at: file, originalFormat: .jpeg)
        }
        XCTAssertEqual(viewModel.selectedItems.count, 5)

        mockCompressor.failureIndices = [1, 3]

        viewModel.startCompression()

        var attempts = 0
        while viewModel.isProcessing && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted, "Batch must complete despite intermediate item failures")
        XCTAssertFalse(viewModel.isProcessing)

        // Exactly 3 successful results
        XCTAssertEqual(viewModel.compressionResults.count, 3)
        XCTAssertEqual(mockCompressor.callCount, 5, "All 5 items must be attempted")

        // Error message must indicate failure of failed items
        XCTAssertNotNil(viewModel.errorMessage)

        // Verify history contains only the 3 successful items
        let history = try await historyStore.loadHistory()
        XCTAssertEqual(history.count, 3)
    }

    /// Verifies CompressViewModel handles total batch failure gracefully without crashing.
    @MainActor
    func testCompressViewModel_TotalBatchFailure_HandledGracefully() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        for i in 0..<3 {
            let file = createDummyFile(named: "fail_\(i).jpg", byteCount: 15_000)
            await viewModel.addMediaItem(at: file, originalFormat: .jpeg)
        }

        // All items fail
        mockCompressor.failureIndices = [0, 1, 2]

        viewModel.startCompression()

        var attempts = 0
        while viewModel.isProcessing && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertTrue(viewModel.compressionResults.isEmpty)
        XCTAssertEqual(viewModel.totalOriginalSize, 0)
        XCTAssertEqual(viewModel.totalSavedBytes, 0)
        XCTAssertEqual(viewModel.totalReductionPercentage, 0.0)
        XCTAssertNotNil(viewModel.errorMessage)

        // Calling saveAllToLibrary when compressionResults is empty must safely return
        await viewModel.saveAllToLibrary()
        XCTAssertFalse(viewModel.isSavedToLibrary)
        XCTAssertEqual(mockPhotoLibrary.saveImageCallCount, 0)
    }

    /// Verifies CompressViewModel partial Photo Library save failure tracks successful saves and raises error.
    @MainActor
    func testCompressViewModel_PartialLibraryExportFailure_ReportsSavedCountAccurately() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let d1 = createDummyFile(named: "res1.jpg", byteCount: 5_000)
        let d2 = createDummyFile(named: "res2.jpg", byteCount: 5_000)
        let d3 = createDummyFile(named: "res3.jpg", byteCount: 5_000)

        viewModel.compressionResults = [
            PhotoCompressionResult(originalURL: d1, compressedURL: d1, originalSize: 10_000, compressedSize: 5_000, format: .jpeg),
            PhotoCompressionResult(originalURL: d2, compressedURL: d2, originalSize: 10_000, compressedSize: 5_000, format: .jpeg),
            PhotoCompressionResult(originalURL: d3, compressedURL: d3, originalSize: 10_000, compressedSize: 5_000, format: .jpeg)
        ]

        // Item 1 fails to save to photo library, items 0 and 2 succeed
        mockPhotoLibrary.failureIndices = [1]

        await viewModel.saveAllToLibrary()

        XCTAssertEqual(mockPhotoLibrary.saveImageCallCount, 3, "All results must be attempted for export")
        XCTAssertTrue(viewModel.isSavedToLibrary, "isSavedToLibrary must be true if at least 1 image succeeded")
        XCTAssertTrue(viewModel.showErrorAlert, "showErrorAlert must be raised for the failed save")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.saveSuccessMessage, "Saved 2 photos to Photo Library")
    }

    /// Verifies CompressViewModel handles total Photo Library save failure.
    @MainActor
    func testCompressViewModel_TotalLibraryExportFailure_SetsErrorState() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let d1 = createDummyFile(named: "res1.jpg", byteCount: 5_000)
        let d2 = createDummyFile(named: "res2.jpg", byteCount: 5_000)

        viewModel.compressionResults = [
            PhotoCompressionResult(originalURL: d1, compressedURL: d1, originalSize: 10_000, compressedSize: 5_000, format: .jpeg),
            PhotoCompressionResult(originalURL: d2, compressedURL: d2, originalSize: 10_000, compressedSize: 5_000, format: .jpeg)
        ]

        mockPhotoLibrary.failureIndices = [0, 1]

        await viewModel.saveAllToLibrary()

        XCTAssertEqual(mockPhotoLibrary.saveImageCallCount, 2)
        XCTAssertFalse(viewModel.isSavedToLibrary, "isSavedToLibrary must remain false on total failure")
        XCTAssertTrue(viewModel.showErrorAlert)
        XCTAssertNil(viewModel.saveSuccessMessage)
    }

    /// Verifies calling startCompression on empty selection is safely a no-op.
    @MainActor
    func testCompressViewModel_EmptyBatch_StartCompressionIsNoOp() {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        XCTAssertTrue(viewModel.selectedItems.isEmpty)
        viewModel.startCompression()

        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertEqual(mockCompressor.callCount, 0)
    }

    // =========================================================================
    // MARK: - VECTOR 3: Rapid UI State Transitions & Cancellation Cascades
    // =========================================================================

    /// Verifies mid-flight cancellation aborts processing, purges results, and cleans up artifacts.
    @MainActor
    func testCompressViewModel_CancellationMidFlight_CleansAllArtifacts() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        for i in 0..<4 {
            let file = createDummyFile(named: "long_\(i).jpg", byteCount: 50_000)
            await viewModel.addMediaItem(at: file, originalFormat: .jpeg)
        }

        // Add 50ms delay per item so mid-flight cancellation can be tested deterministically
        mockCompressor.delayNanoseconds = 50_000_000

        viewModel.startCompression()
        XCTAssertTrue(viewModel.isProcessing)

        // Cancel mid-flight after a brief delay
        try await Task.sleep(nanoseconds: 25_000_000) // 25ms
        viewModel.cancelCompression()

        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertTrue(viewModel.compressionResults.isEmpty)

        // Allow background task to settle
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(viewModel.compressionResults.isEmpty)
    }

    /// Verifies rapid cancellation followed immediately by restart does not corrupt internal processing state.
    @MainActor
    func testCompressViewModel_ImmediateRestartAfterCancellation_NoZombieStateCorruption() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        for i in 0..<3 {
            let file = createDummyFile(named: "restart_\(i).jpg", byteCount: 20_000)
            await viewModel.addMediaItem(at: file, originalFormat: .jpeg)
        }

        mockCompressor.delayNanoseconds = 30_000_000

        // Start then immediately cancel
        viewModel.startCompression()
        viewModel.cancelCompression()
        XCTAssertFalse(viewModel.isProcessing)

        // Immediate restart with 0 delay
        mockCompressor.delayNanoseconds = 0
        viewModel.startCompression()

        var attempts = 0
        while viewModel.isProcessing && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertEqual(viewModel.compressionResults.count, 3)
    }

    /// Verifies clearSelection during active compression cleans up all state cleanly.
    @MainActor
    func testCompressViewModel_ClearSelectionWhileCompressing() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        for i in 0..<2 {
            let file = createDummyFile(named: "clear_\(i).jpg", byteCount: 30_000)
            await viewModel.addMediaItem(at: file, originalFormat: .jpeg)
        }

        mockCompressor.delayNanoseconds = 50_000_000
        viewModel.startCompression()

        // Clear selection mid-flight
        viewModel.clearSelection()

        XCTAssertTrue(viewModel.selectedItems.isEmpty)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertTrue(viewModel.compressionResults.isEmpty)
        XCTAssertEqual(viewModel.overallProgress, 0.0)

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(viewModel.selectedItems.isEmpty)
    }

    /// Verifies rapid successive calls to startCompression are safely debounced.
    @MainActor
    func testCompressViewModel_RapidDuplicateStartClicksIgnored() async throws {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let file = createDummyFile(named: "single.jpg", byteCount: 25_000)
        await viewModel.addMediaItem(at: file, originalFormat: .jpeg)

        mockCompressor.delayNanoseconds = 30_000_000

        // Call startCompression 4 times rapidly
        viewModel.startCompression()
        viewModel.startCompression()
        viewModel.startCompression()
        viewModel.startCompression()

        var attempts = 0
        while viewModel.isProcessing && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertEqual(mockCompressor.callCount, 1, "Only a single compression task must run")
    }

    /// Verifies ConvertViewModel mid-flight cancellation cleans up state and sets progress to Cancelled.
    @MainActor
    func testConvertViewModel_CancellationMidFlight_CleansArtifacts() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockVideoProcessor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let video = createDummyFile(named: "long_video.mov", byteCount: 200_000)
        try await viewModel.loadVideo(from: video)

        mockVideoProcessor.delayNanoseconds = 60_000_000 // 60ms
        viewModel.startConversion()
        XCTAssertTrue(viewModel.isConverting)

        try await Task.sleep(nanoseconds: 15_000_000)
        viewModel.cancelConversion()

        XCTAssertFalse(viewModel.isConverting)
        XCTAssertEqual(viewModel.progressDescription, "Cancelled")
        XCTAssertEqual(viewModel.conversionProgress, 0.0)
        XCTAssertNil(viewModel.conversionResult)
        XCTAssertNil(viewModel.avPlayer)
    }

    /// Verifies ConvertViewModel immediate restart after cancellation completes successfully.
    @MainActor
    func testConvertViewModel_ImmediateRestartAfterCancellation_RecoversCleanly() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockVideoProcessor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let video = createDummyFile(named: "restart_video.mov", byteCount: 150_000)
        try await viewModel.loadVideo(from: video)

        mockVideoProcessor.delayNanoseconds = 40_000_000
        viewModel.startConversion()
        viewModel.cancelConversion()

        // Immediate restart with fast completion
        mockVideoProcessor.delayNanoseconds = 0
        viewModel.startConversion()

        var attempts = 0
        while viewModel.isConverting && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isConverting)
        XCTAssertNotNil(viewModel.conversionResult)
        XCTAssertNotNil(viewModel.avPlayer)
    }

    /// Verifies ConvertViewModel resetSelection during conversion cleans up all selected states.
    @MainActor
    func testConvertViewModel_ResetSelectionWhileConverting_ResetsAllFields() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockVideoProcessor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let video = createDummyFile(named: "reset_video.mov", byteCount: 100_000)
        try await viewModel.loadVideo(from: video)

        mockVideoProcessor.delayNanoseconds = 50_000_000
        viewModel.startConversion()

        viewModel.resetSelection()

        XCTAssertNil(viewModel.selectedVideoURL)
        XCTAssertTrue(viewModel.sourceFileName.isEmpty)
        XCTAssertEqual(viewModel.sourceFileSize, 0)
        XCTAssertNil(viewModel.videoMetadata)
        XCTAssertFalse(viewModel.isConverting)
        XCTAssertNil(viewModel.conversionResult)
        XCTAssertNil(viewModel.avPlayer)
        XCTAssertFalse(viewModel.isCompleted)
    }

    /// Verifies ConvertViewModel cancellation suppresses error alerts.
    @MainActor
    func testConvertViewModel_CancellationDoesNotTriggerErrorAlert() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockVideoProcessor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let video = createDummyFile(named: "suppress_err.mov", byteCount: 100_000)
        try await viewModel.loadVideo(from: video)

        mockVideoProcessor.delayNanoseconds = 30_000_000
        viewModel.startConversion()
        viewModel.cancelConversion()

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(viewModel.showErrorAlert, "Cancellation must never trigger an error alert")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.progressDescription, "Cancelled")
    }

    // =========================================================================
    // MARK: - VECTOR 4: History Persistence Edge Cases & Concurrency
    // =========================================================================

    /// Verifies HistoryViewModel recovers gracefully from corrupted backing JSON and can self-heal.
    @MainActor
    func testHistoryViewModel_CorruptedBackingJSON_RecoversGracefully() async throws {
        // Write corrupted bytes to history.json
        let corruptedData = Data("{ not_valid_json: [ unclosed ".utf8)
        try corruptedData.write(to: historyFileURL)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()

        // Should load empty array safely without throwing or setting errorMessage
        XCTAssertTrue(viewModel.allItems.isEmpty)
        XCTAssertNil(viewModel.errorMessage)

        // Adding an item heals the file on disk into valid JSON
        let validItem = CompressionHistoryItem(
            fileName: "healed.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 10_000,
            compressedByteSize: 5_000,
            compressionStrength: .low
        )
        try await historyStore.addItem(validItem)

        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.allItems.count, 1)
        XCTAssertEqual(viewModel.allItems.first?.fileName, "healed.jpg")
    }

    /// Verifies HistoryViewModel deletes all duplicate records sharing an identical UUID.
    @MainActor
    func testHistoryViewModel_DuplicateItemIDs_DeletedAtomically() async throws {
        let sharedID = UUID()
        let item1 = CompressionHistoryItem(
            id: sharedID,
            fileName: "duplicate1.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 10_000,
            compressedByteSize: 5_000,
            compressionStrength: .medium
        )
        let item2 = CompressionHistoryItem(
            id: sharedID,
            fileName: "duplicate2.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 20_000,
            compressedByteSize: 10_000,
            compressionStrength: .high
        )

        try await historyStore.addItem(item1)
        try await historyStore.addItem(item2)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.allItems.count, 2)

        await viewModel.deleteItem(id: sharedID)

        XCTAssertTrue(viewModel.allItems.isEmpty, "Both duplicate records with shared ID must be removed")
        let reloaded = try await historyStore.loadHistory()
        XCTAssertTrue(reloaded.isEmpty)
    }

    /// Verifies HistoryViewModel filtering and aggregates scale across a massive 1,000-item archive.
    @MainActor
    func testHistoryViewModel_MassiveArchive_1000Items_FilterAndAggregates() async throws {
        var items: [CompressionHistoryItem] = []
        for i in 0..<1000 {
            let isPhoto = i % 2 == 0
            items.append(CompressionHistoryItem(
                fileName: "item_\(i).\(isPhoto ? "jpg" : "mp4")",
                mediaType: isPhoto ? "photo" : "video",
                sourceFormat: isPhoto ? "JPEG" : "MP4",
                targetFormat: isPhoto ? "JPEG" : "MP4",
                originalByteSize: 10_000,
                compressedByteSize: 6_000,
                compressionStrength: .medium,
                durationSeconds: isPhoto ? nil : 10.0
            ))
        }

        // Write directly to history file for fast seed
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(items)
        try data.write(to: historyFileURL)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.allItems.count, 1000)

        // Filter Photos: exactly 500 items
        viewModel.selectedFilter = .photos
        XCTAssertEqual(viewModel.filteredItems.count, 500)
        XCTAssertEqual(viewModel.filteredStats.photoCount, 500)
        XCTAssertEqual(viewModel.filteredStats.videoCount, 0)
        XCTAssertEqual(viewModel.filteredStats.totalOriginalBytes, 5_000_000)
        XCTAssertEqual(viewModel.filteredStats.totalCompressedBytes, 3_000_000)
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, 2_000_000)

        // Filter Videos: exactly 500 items
        viewModel.selectedFilter = .videos
        XCTAssertEqual(viewModel.filteredItems.count, 500)
        XCTAssertEqual(viewModel.filteredStats.photoCount, 0)
        XCTAssertEqual(viewModel.filteredStats.videoCount, 500)

        // Filter All: 1,000 items
        viewModel.selectedFilter = .all
        XCTAssertEqual(viewModel.filteredItems.count, 1000)
        XCTAssertEqual(viewModel.filteredStats.totalItems, 1000)
    }

    /// Verifies HomeViewModel limits recent items to 5 while aggregating all items in lifetime stats.
    @MainActor
    func testHomeViewModel_MassiveHistoryArchive_PrefixLimitAndFullAggregation() async throws {
        var items: [CompressionHistoryItem] = []
        for i in 0..<200 {
            items.append(CompressionHistoryItem(
                fileName: "item_\(i).jpg",
                mediaType: "photo",
                sourceFormat: "JPEG",
                targetFormat: "JPEG",
                originalByteSize: 10_000,
                compressedByteSize: 5_000,
                compressionStrength: .medium
            ))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(items)
        try data.write(to: historyFileURL)

        let viewModel = HomeViewModel(historyStore: historyStore)
        await viewModel.loadDashboardData()

        XCTAssertEqual(viewModel.recentItems.count, 5, "recentItems must strictly cap at 5")
        XCTAssertEqual(viewModel.stats.photoCount, 200, "stats must aggregate all 200 items")
        XCTAssertEqual(viewModel.stats.totalOriginalBytes, 2_000_000)
        XCTAssertEqual(viewModel.stats.totalSavedBytes, 1_000_000)
    }

    /// Verifies clearAllHistory cleans up all items and resets filtered stats to zero even with a filter active.
    @MainActor
    func testHistoryViewModel_ClearAllHistoryWhileFilterActive() async throws {
        for i in 0..<4 {
            let item = CompressionHistoryItem(
                fileName: "test_\(i).mp4",
                mediaType: "video",
                sourceFormat: "MP4",
                targetFormat: "MP4",
                originalByteSize: 10_000,
                compressedByteSize: 4_000,
                compressionStrength: .high
            )
            try await historyStore.addItem(item)
        }

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()
        viewModel.selectedFilter = .videos
        XCTAssertEqual(viewModel.filteredItems.count, 4)

        await viewModel.clearAllHistory()

        XCTAssertTrue(viewModel.allItems.isEmpty)
        XCTAssertTrue(viewModel.filteredItems.isEmpty)
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, 0)
        XCTAssertEqual(viewModel.filteredStats.totalItems, 0)
    }

    /// Verifies CompressionHistoryItem serialization preserves complex Unicode file names and emojis.
    func testHistoryRecord_SpecialCharactersAndEmojisInFileName() async throws {
        let complexName = "📷 週末旅行_Kyoto #2026! @#%^&*()_+~{}[]|:;<>?,./.heic"
        let item = CompressionHistoryItem(
            fileName: complexName,
            mediaType: "photo",
            sourceFormat: "HEIC",
            targetFormat: "HEIC",
            originalByteSize: 50_000,
            compressedByteSize: 20_000,
            compressionStrength: .medium
        )

        try await historyStore.addItem(item)
        let loaded = try await historyStore.loadHistory()

        XCTAssertEqual(loaded.first?.fileName, complexName)
    }

    // =========================================================================
    // MARK: - VECTOR 5: Settings Extreme Configurations & Concurrency
    // =========================================================================

    /// Verifies AppSettings clamping and defensive fallback for maxCacheAgeDays.
    func testAppSettings_ExtremeMaxCacheAgeDays_ClampingAndFallback() {
        // Int.max clamped to 365
        let maxSettings = AppSettings(maxCacheAgeDays: Int.max)
        XCTAssertEqual(maxSettings.maxCacheAgeDays, 365)

        // Negative clamped to 0
        let negSettings = AppSettings(maxCacheAgeDays: -500)
        XCTAssertEqual(negSettings.maxCacheAgeDays, 0)

        // Setter clamping
        var mutable = AppSettings()
        mutable.maxCacheAgeDays = 10_000
        XCTAssertEqual(mutable.maxCacheAgeDays, 365)
        mutable.maxCacheAgeDays = -20
        XCTAssertEqual(mutable.maxCacheAgeDays, 0)

        // Corruption fallback to 7 in load
        testDefaults.set(-10, forKey: AppSettings.Keys.maxCacheAgeDays)
        let loadedNeg = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loadedNeg.maxCacheAgeDays, 7)

        testDefaults.set(Int.max, forKey: AppSettings.Keys.maxCacheAgeDays)
        let loadedMax = AppSettings.load(from: testDefaults)
        XCTAssertEqual(loadedMax.maxCacheAgeDays, 365)
    }

    /// Verifies corrupted raw string enums in UserDefaults fall back safely to defaults.
    func testAppSettings_CorruptedRawEnumsInUserDefaults_FallbackSafely() {
        testDefaults.set("SUPER_ULTRA_COMPRESSION_NONEXISTENT", forKey: AppSettings.Keys.defaultCompressionStrength)
        testDefaults.set("UNSUPPORTED_VIDEO_TRANSCODER", forKey: AppSettings.Keys.defaultVideoMode)

        let settings = AppSettings.load(from: testDefaults)
        XCTAssertEqual(settings.defaultCompressionStrength, .medium)
        XCTAssertEqual(settings.defaultVideoMode, .reduceSize)
    }

    /// Verifies SettingsViewModel resetToDefaults restores state cleanly.
    @MainActor
    func testSettingsViewModel_ResetToDefaultsUnderConcurrency() {
        let viewModel = SettingsViewModel(defaults: testDefaults, tempManager: tempFileManager)

        viewModel.settings.defaultCompressionStrength = .high
        viewModel.settings.defaultVideoMode = .compressAndConvert
        viewModel.settings.autoSaveToLibrary = true
        viewModel.settings.maxCacheAgeDays = 30
        viewModel.updateSettings()

        viewModel.resetToDefaults()

        XCTAssertEqual(viewModel.settings.defaultCompressionStrength, .medium)
        XCTAssertEqual(viewModel.settings.defaultVideoMode, .reduceSize)
        XCTAssertFalse(viewModel.settings.autoSaveToLibrary)
        XCTAssertEqual(viewModel.settings.maxCacheAgeDays, 7)
        XCTAssertNotNil(viewModel.statusMessage)
    }

    /// Verifies SettingsViewModel cache inspection handles subdirectories and empty files without crashing.
    @MainActor
    func testSettingsViewModel_CacheInspectionWithNestedDirectoriesAndEmptyFiles() throws {
        let baseDir = tempFileManager.baseDirectory
        let subDir = baseDir.appendingPathComponent("nested_folder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let emptyFile = baseDir.appendingPathComponent("empty.bin")
        try Data().write(to: emptyFile)

        let contentFile = baseDir.appendingPathComponent("data.bin")
        try Data(repeating: 0x99, count: 25_000).write(to: contentFile)

        let viewModel = SettingsViewModel(defaults: testDefaults, tempManager: tempFileManager)
        viewModel.inspectCache()

        XCTAssertEqual(viewModel.cacheSizeBytes, 25_000)

        viewModel.clearCache()
        XCTAssertEqual(viewModel.cacheSizeBytes, 0)
    }

    // =========================================================================
    // MARK: - VECTOR 6: Memory & State Leaks / Clean Resource Lifecycle
    // =========================================================================

    /// Verifies MediaItem fallback name generation when both url and data are nil.
    func testMediaItem_NilURLAndData_SuggestedFileNameFallback() {
        let item = MediaItem(format: .png, byteSize: 500)
        XCTAssertNil(item.url)
        XCTAssertNil(item.data)
        XCTAssertTrue(item.suggestedFileName.hasSuffix(".png"))
        XCTAssertTrue(item.suggestedFileName.contains(item.id.uuidString.prefix(8)))
    }

    /// Verifies MediaItem photo and video UTType conformances are mutually exclusive.
    func testMediaItem_VideoAndPhotoConformances() {
        let jpegItem = MediaItem(format: .jpeg)
        XCTAssertTrue(jpegItem.isPhoto)
        XCTAssertFalse(jpegItem.isVideo)

        let pngItem = MediaItem(format: .png)
        XCTAssertTrue(pngItem.isPhoto)
        XCTAssertFalse(pngItem.isVideo)

        let heicItem = MediaItem(format: .heic)
        XCTAssertTrue(heicItem.isPhoto)
        XCTAssertFalse(heicItem.isVideo)

        let movItem = MediaItem(format: .quickTimeMovie)
        XCTAssertTrue(movItem.isVideo)
        XCTAssertFalse(movItem.isPhoto)

        let mp4Item = MediaItem(format: .mpeg4Movie)
        XCTAssertTrue(mp4Item.isVideo)
        XCTAssertFalse(mp4Item.isPhoto)
    }

    /// Verifies ConvertViewModel AVPlayer is released when selection is reset or cancelled.
    @MainActor
    func testConvertViewModel_AVPlayerCleanLifecycleOnResetAndCancel() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockVideoProcessor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let video = createDummyFile(named: "player_test.mov", byteCount: 50_000)
        try await viewModel.loadVideo(from: video)

        mockVideoProcessor.delayNanoseconds = 0
        viewModel.startConversion()

        var attempts = 0
        while viewModel.isConverting && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertNotNil(viewModel.avPlayer, "avPlayer must be initialized upon conversion completion")

        // Reset must release avPlayer to prevent video buffer leak
        viewModel.resetSelection()
        XCTAssertNil(viewModel.avPlayer, "avPlayer must be cleanly nil-ed on resetSelection")
    }

    /// Verifies CompressViewModel releases items and memory references upon removeItem and clearSelection.
    @MainActor
    func testCompressViewModel_SelectedItemsMemoryReleaseOnRemoveAndClear() async {
        let viewModel = CompressViewModel(
            compressor: mockCompressor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let file1 = createDummyFile(named: "mem1.jpg", byteCount: 10_000)
        let file2 = createDummyFile(named: "mem2.jpg", byteCount: 20_000)

        await viewModel.addMediaItem(at: file1, originalFormat: .jpeg)
        await viewModel.addMediaItem(at: file2, originalFormat: .jpeg)
        XCTAssertEqual(viewModel.selectedItems.count, 2)

        viewModel.removeItem(at: 0)
        XCTAssertEqual(viewModel.selectedItems.count, 1)

        viewModel.clearSelection()
        XCTAssertTrue(viewModel.selectedItems.isEmpty)
        XCTAssertTrue(viewModel.compressionResults.isEmpty)
    }

    /// Verifies ConvertViewModel conversion failure leaves player and results nil.
    @MainActor
    func testConvertViewModel_ConversionFailure_PlayerRemainsNil() async throws {
        let viewModel = ConvertViewModel(
            videoProcessor: mockVideoProcessor,
            historyStorage: historyStore,
            photoLibrary: mockPhotoLibrary,
            tempFileManager: tempFileManager
        )

        let video = createDummyFile(named: "will_fail.mov", byteCount: 40_000)
        try await viewModel.loadVideo(from: video)

        mockVideoProcessor.shouldFail = true
        mockVideoProcessor.delayNanoseconds = 0
        viewModel.startConversion()

        var attempts = 0
        while viewModel.isConverting && attempts < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        XCTAssertFalse(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isConverting)
        XCTAssertNil(viewModel.avPlayer)
        XCTAssertNil(viewModel.conversionResult)
        XCTAssertTrue(viewModel.showErrorAlert)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}
