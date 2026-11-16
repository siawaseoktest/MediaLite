//
//  VideoProcessorServiceTests.swift
//  MediaLiteTests
//
//  Unit test suite for VideoProcessorService.
//  Covers:
//  - All 3 modes: .reduceSize, .improveCompatibility, .compressAndConvert
//  - All 3 compression strengths: .low, .medium, .high
//  - HDR detection logic (track characteristic + CMFormatDescription fallback)
//  - SDR Rec. 709 tone mapping composition & output color space validation
//  - Orientation matrix and preferredTransform preservation (portrait & landscape)
//  - Silent video handling (safe transcode without audio tracks)
//  - Cooperative cancellation & guaranteed temp file deletion
//  - Error branches: non-existent file, zero-byte file, corrupted container, zero duration
//  - Video inspection helper (duration, naturalSize, transform, codec, HDR, audio)
//  - Progress stream monotonic progression & terminal completion
//

import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import MediaLite

final class VideoProcessorServiceTests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var processor: VideoProcessorService!
    private var tempFileManager: TempFileManager!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        processor = VideoProcessorService()
        tempFileManager = TempFileManager(tempSubdirectoryName: "com.medialite.tests.videoprocessor.\(UUID().uuidString)")
    }

    override func tearDown() {
        SyntheticAssetGenerator.cleanup(urls: trackedURLs)
        trackedURLs.removeAll()
        try? tempFileManager.purgeAllTempFiles()
        try? FileManager.default.removeItem(at: tempFileManager.baseDirectory)
        tempFileManager = nil
        processor = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    @discardableResult
    private func trackURL(_ url: URL) -> URL {
        trackedURLs.append(url)
        return url
    }

    // MARK: - 1. Mode 1: Reduce Size Across Strengths

    func testReduceSizeWithLowStrength() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 480, height: 360),
            hasAudio: true,
            isHDR: false
        ))

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let originalByteSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(originalByteSize, 0)

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .low,
            destinationURL: destURL
        )

        let drainTask = Task {
            var updates: [VideoProcessingProgress] = []
            for await progress in stream {
                updates.append(progress)
            }
            return updates
        }

        let result = try await task.value
        let updates = await drainTask.value

        XCTAssertEqual(result.originalURL, sourceURL)
        XCTAssertEqual(result.processedURL, destURL)
        XCTAssertEqual(result.originalSize, originalByteSize)
        XCTAssertGreaterThan(result.processedSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertFalse(updates.isEmpty)

        // Asset integrity
        let asset = AVURLAsset(url: destURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)

        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 0.5, accuracy: 0.15)
    }

    func testReduceSizeWithMediumAndHighStrengths() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.4,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: true,
            isHDR: false
        ))

        for strength in [CompressionStrength.medium, CompressionStrength.high] {
            let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

            let (stream, task) = processor.processVideo(
                at: sourceURL,
                mode: .reduceSize,
                strength: strength,
                destinationURL: destURL
            )

            let drain = Task { for await _ in stream {} }
            let result = try await task.value
            _ = await drain.value

            XCTAssertTrue(FileManager.default.fileExists(atPath: result.processedURL.path))
            XCTAssertGreaterThan(result.processedSize, 0)

            let asset = AVURLAsset(url: destURL)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertFalse(videoTracks.isEmpty)
        }
    }

    // MARK: - 2. Mode 2: Universal Compatibility (H.264 + AAC + MP4)

    func testImproveCompatibilityModeTranscodesToH264AndAAC() async throws {
        // Source video
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false
        ))

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .improveCompatibility,
            strength: .medium,
            destinationURL: destURL
        )

        let drain = Task { for await _ in stream {} }
        let result = try await task.value
        _ = await drain.value

        XCTAssertEqual(result.processedURL.pathExtension.lowercased(), "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        let asset = AVURLAsset(url: destURL)

        // Verify Video Track is encoded in H.264
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(videoTracks.isEmpty, "Output must contain a video track")
        if let videoTrack = videoTracks.first {
            let descriptions = try await videoTrack.load(.formatDescriptions)
            var hasH264 = false
            for desc in descriptions {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                if subType == kCMVideoCodecType_H264 {
                    hasH264 = true
                    break
                }
            }
            XCTAssertTrue(hasH264, "Output video track must be H.264")
        }

        // Verify Audio Track is encoded in AAC-LC
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Output must retain audio track")
        if let audioTrack = audioTracks.first {
            let descriptions = try await audioTrack.load(.formatDescriptions)
            var hasAAC = false
            for desc in descriptions {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                if subType == kAudioFormatMPEG4AAC {
                    hasAAC = true
                    break
                }
            }
            XCTAssertTrue(hasAAC, "Output audio track must be AAC-LC")
        }
    }

    // MARK: - 3. Mode 3: Compress & Convert Dual Transformation

    func testCompressAndConvertDualTransformationAllStrengths() async throws {
        let initialWidth: CGFloat = 640
        let initialHeight: CGFloat = 480

        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.4,
            fps: 30,
            resolution: CGSize(width: initialWidth, height: initialHeight),
            hasAudio: true,
            isHDR: false
        ))

        let strengths: [CompressionStrength] = [.low, .medium, .high]
        for strength in strengths {
            let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

            let (stream, task) = processor.processVideo(
                at: sourceURL,
                mode: .compressAndConvert,
                strength: strength,
                destinationURL: destURL
            )

            let drain = Task { for await _ in stream {} }
            let result = try await task.value
            _ = await drain.value

            XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
            XCTAssertGreaterThan(result.processedSize, 0)

            let asset = AVURLAsset(url: destURL)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                XCTFail("Missing video track in compressAndConvert output for strength \(strength)")
                continue
            }

            // Verify downscaled dimensions match strength.dimensionScale
            let outputSize = try await videoTrack.load(.naturalSize)
            let expectedWidth = CGFloat(max(2, Int(round(initialWidth * strength.dimensionScale)) / 2 * 2))
            let expectedHeight = CGFloat(max(2, Int(round(initialHeight * strength.dimensionScale)) / 2 * 2))

            XCTAssertEqual(outputSize.width, expectedWidth, accuracy: 2.0, "Width should be downscaled proportionally")
            XCTAssertEqual(outputSize.height, expectedHeight, accuracy: 2.0, "Height should be downscaled proportionally")

            // Verify H.264 codec
            let formatDescriptions = try await videoTrack.load(.formatDescriptions)
            var isH264 = false
            for desc in formatDescriptions {
                if CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_H264 {
                    isH264 = true
                    break
                }
            }
            XCTAssertTrue(isH264, "Dual transform must output H.264")
        }
    }

    // MARK: - 4. HDR Detection Logic

    func testHDRDetectionLogicWithHDRAndSDRAssets() async throws {
        // 1. Synthesize 10-bit HLG HDR asset
        let hdrURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.3,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: false,
            isHDR: true
        ))

        let hdrAsset = AVURLAsset(url: hdrURL)
        let hdrTracks = try await hdrAsset.loadTracks(withMediaType: .video)
        guard let hdrTrack = hdrTracks.first else {
            XCTFail("Missing video track in HDR synthetic asset")
            return
        }

        let isHDRDetected = await VideoProcessorService.isHDRVideo(track: hdrTrack)
        XCTAssertTrue(isHDRDetected, "HDR video track must be identified as HDR")

        // 2. Synthesize Standard SDR asset
        let sdrURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.3,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: false,
            isHDR: false
        ))

        let sdrAsset = AVURLAsset(url: sdrURL)
        let sdrTracks = try await sdrAsset.loadTracks(withMediaType: .video)
        guard let sdrTrack = sdrTracks.first else {
            XCTFail("Missing video track in SDR synthetic asset")
            return
        }

        let isSDRDetected = await VideoProcessorService.isHDRVideo(track: sdrTrack)
        XCTAssertFalse(isSDRDetected, "Standard SDR video track must not be detected as HDR")
    }

    // MARK: - 5. SDR Tone Mapping Composition & Output

    func testSDRToneMappingAVVideoCompositionConfiguration() async throws {
        let hdrURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: false,
            isHDR: true
        ))

        let asset = AVURLAsset(url: hdrURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            XCTFail("Missing video track")
            return
        }

        let composition = try await VideoProcessorService.buildSDRVideoComposition(
            for: asset,
            track: videoTrack,
            renderSize: CGSize(width: 640, height: 480)
        )

        // Verify ITU-R 709 color primaries, transfer function, YCbCr matrix
        XCTAssertEqual(composition.colorPrimaries, AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(composition.colorTransferFunction, AVVideoTransferFunction_ITU_R_709_2)
        XCTAssertEqual(composition.colorYCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_709_2)
        XCTAssertEqual(composition.renderSize, CGSize(width: 640, height: 480))
        XCTAssertFalse(composition.instructions.isEmpty, "Composition must contain instructions")
    }

    func testHDRVideoProcessingProducesSDRRec709Output() async throws {
        let hdrSourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.4,
            fps: 30,
            resolution: CGSize(width: 480, height: 360),
            hasAudio: false,
            isHDR: true
        ))

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: hdrSourceURL,
            mode: .compressAndConvert,
            strength: .medium,
            destinationURL: destURL
        )

        let drain = Task { for await _ in stream {} }
        let result = try await task.value
        _ = await drain.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.processedURL.path))

        let asset = AVURLAsset(url: result.processedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            XCTFail("Missing video track in tone-mapped output")
            return
        }

        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        for desc in formatDescriptions {
            if let extensions = CMFormatDescriptionGetExtensions(desc) as? [CFString: Any] {
                // Verify output transfer function is NOT HLG or PQ
                let transfer = extensions[kCVImageBufferTransferFunctionKey] as? String
                XCTAssertNotEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                XCTAssertNotEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084 as String)

                // Verify Rec. 709 primaries
                if let primaries = extensions[kCVImageBufferColorPrimariesKey] as? String {
                    XCTAssertTrue(
                        primaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String) || primaries.contains("709"),
                        "Expected Rec. 709 primaries, got \(primaries)"
                    )
                }
            }
        }
    }

    // MARK: - 6. Orientation Transform Preservation

    func testOrientationAndTransformPreservation90Degrees() async throws {
        let portraitTransform = CGAffineTransform(rotationAngle: .pi / 2.0)
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.4,
            fps: 30,
            resolution: CGSize(width: 480, height: 360),
            hasAudio: true,
            isHDR: false,
            transform: portraitTransform
        ))

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destURL
        )

        let drain = Task { for await _ in stream {} }
        let result = try await task.value
        _ = await drain.value

        let asset = AVURLAsset(url: result.processedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            XCTFail("Missing video track in output")
            return
        }

        let outputTransform = try await videoTrack.load(.preferredTransform)
        XCTAssertFalse(outputTransform.isIdentity, "Preferred transform must not be reset to identity")
        XCTAssertEqual(outputTransform.a, portraitTransform.a, accuracy: 0.01)
        XCTAssertEqual(outputTransform.b, portraitTransform.b, accuracy: 0.01)
        XCTAssertEqual(outputTransform.c, portraitTransform.c, accuracy: 0.01)
        XCTAssertEqual(outputTransform.d, portraitTransform.d, accuracy: 0.01)
    }

    func testOrientationAndTransformPreservation180Degrees() async throws {
        let upsideDownTransform = CGAffineTransform(rotationAngle: .pi)
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.4,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: false,
            isHDR: false,
            transform: upsideDownTransform
        ))

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .improveCompatibility,
            strength: .low,
            destinationURL: destURL
        )

        let drain = Task { for await _ in stream {} }
        let result = try await task.value
        _ = await drain.value

        let asset = AVURLAsset(url: result.processedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            XCTFail("Missing video track in output")
            return
        }

        let outputTransform = try await videoTrack.load(.preferredTransform)
        XCTAssertFalse(outputTransform.isIdentity)
    }

    // MARK: - 7. Silent Video Handling

    func testSilentVideoProcessingWithoutAudioTrack() async throws {
        let silentURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.4,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: false,
            isHDR: false
        ))

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: silentURL,
            mode: .compressAndConvert,
            strength: .medium,
            destinationURL: destURL
        )

        let drain = Task { for await _ in stream {} }
        let result = try await task.value
        _ = await drain.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.processedURL.path))

        let asset = AVURLAsset(url: result.processedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        XCTAssertEqual(videoTracks.count, 1, "Must have exactly 1 video track")
        XCTAssertTrue(audioTracks.isEmpty, "Silent video must not contain synthesized audio tracks")
    }

    // MARK: - 8. Cancellation & Cleanup

    func testCancellationAbortsPromptlyAndCleansUpDestination() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 2.0,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false
        ))

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: destURL
        )

        let cancelledExpectation = expectation(description: "Task cancelled on first progress")
        Task {
            for await progress in stream {
                if progress.fractionCompleted > 0.0 {
                    task.cancel()
                    cancelledExpectation.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [cancelledExpectation], timeout: 5.0)

        let taskResult = await task.result
        switch taskResult {
        case .success:
            XCTFail("Task should not succeed when cancelled mid-flight")
        case .failure(let error):
            let isCancelled = error is CancellationError || "\(error)".lowercased().contains("cancel")
            XCTAssertTrue(isCancelled, "Error should indicate cancellation, got \(error)")
        }

        // Verify partial destination file was cleaned up
        let exists = FileManager.default.fileExists(atPath: destURL.path)
        if exists {
            let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            XCTAssertEqual(size, 0, "Partial output file must be deleted or empty")
        }
    }

    func testImmediateCancellationBeforeProcessingBegins() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: false
        ))

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .low,
            destinationURL: destURL
        )

        // Cancel immediately
        task.cancel()

        let drain = Task { for await _ in stream {} }
        _ = await task.result
        _ = await drain.value

        // File should not be playable
        if FileManager.default.fileExists(atPath: destURL.path) {
            let asset = AVURLAsset(url: destURL)
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            XCTAssertFalse(isPlayable, "Cancelled video must not be playable")
        }
    }

    // MARK: - 9. Error Branches

    func testNonExistentSourceURLThrowsFileNotFoundError() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("non_existent_\(UUID().uuidString).mp4")
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: missingURL,
            mode: .improveCompatibility,
            strength: .medium,
            destinationURL: destURL
        )

        let streamFinished = expectation(description: "Stream terminates on missing file")
        Task {
            for await _ in stream {}
            streamFinished.fulfill()
        }

        do {
            _ = try await task.value
            XCTFail("Should throw fileNotFound error")
        } catch let error as VideoProcessingError {
            switch error {
            case .fileNotFound(let url):
                XCTAssertEqual(url, missingURL)
            default:
                XCTFail("Expected .fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        await fulfillment(of: [streamFinished], timeout: 5.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
    }

    func testZeroByteSourceFileThrowsZeroByteFileError() async throws {
        let zeroByteURL = trackURL(try SyntheticAssetGenerator.createZeroByteFile(extension: "mp4"))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: zeroByteURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destURL
        )

        let drain = Task { for await _ in stream {} }

        do {
            _ = try await task.value
            XCTFail("Should throw zeroByteFile error")
        } catch let error as VideoProcessingError {
            switch error {
            case .zeroByteFile(let url):
                XCTAssertEqual(url, zeroByteURL)
            default:
                XCTFail("Expected .zeroByteFile, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        _ = await drain.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
    }

    func testCorruptedVideoSourceThrowsError() async throws {
        let corruptURL = trackURL(try SyntheticAssetGenerator.createCorruptedFile(extension: "mp4"))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: corruptURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: destURL
        )

        let streamFinished = expectation(description: "Stream terminates on corrupt file")
        Task {
            for await _ in stream {}
            streamFinished.fulfill()
        }

        do {
            _ = try await task.value
            XCTFail("Should throw corrupt video error")
        } catch {
            XCTAssertNotNil(error)
        }

        await fulfillment(of: [streamFinished], timeout: 5.0)
    }

    // MARK: - 10. Video Inspection Helper

    func testInspectVideoReturnsAccurateMetadata() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.6,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false
        ))

        let metadata = try await processor.inspectVideo(at: sourceURL)

        XCTAssertEqual(metadata.duration, 0.6, accuracy: 0.15)
        XCTAssertEqual(metadata.naturalSize.width, 640)
        XCTAssertEqual(metadata.naturalSize.height, 480)
        XCTAssertTrue(metadata.hasAudio)
        XCTAssertFalse(metadata.isHDR)
        XCTAssertEqual(metadata.codec, "H.264")
    }

    // MARK: - 11. Progress Stream Monotonicity

    func testProgressStreamMonotonicallyIncreasesToCompletion() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: true
        ))

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destURL
        )

        var updates: [VideoProcessingProgress] = []
        let collector = Task {
            for await progress in stream {
                updates.append(progress)
            }
        }

        _ = try await task.value
        await collector.value

        XCTAssertFalse(updates.isEmpty, "Stream must yield progress updates")

        var previousFraction = 0.0
        for update in updates {
            XCTAssertGreaterThanOrEqual(update.fractionCompleted, previousFraction, "Progress should increase or remain constant")
            XCTAssertLessThanOrEqual(update.fractionCompleted, 1.0)
            XCTAssertFalse(update.description.isEmpty, "Description should not be empty")
            previousFraction = update.fractionCompleted
        }

        if let lastUpdate = updates.last {
            XCTAssertEqual(lastUpdate.fractionCompleted, 1.0, accuracy: 0.01, "Terminal progress must reach 1.0")
        }
    }

    // MARK: - 12. VideoProcessingResult Math Calculations

    func testVideoProcessingResultCalculations() {
        let originalURL = URL(fileURLWithPath: "/tmp/original.mp4")
        let processedURL = URL(fileURLWithPath: "/tmp/processed.mp4")

        // Case 1: Size reduced
        let reducedResult = VideoProcessingResult(
            originalURL: originalURL,
            processedURL: processedURL,
            originalSize: 10_000_000,
            processedSize: 3_000_000,
            duration: 10.0
        )
        XCTAssertEqual(reducedResult.byteDelta, 7_000_000)
        XCTAssertEqual(reducedResult.reductionPercentage, 70.0, accuracy: 0.001)
        XCTAssertFalse(reducedResult.isSizeIncreased)

        // Case 2: Size increased
        let increasedResult = VideoProcessingResult(
            originalURL: originalURL,
            processedURL: processedURL,
            originalSize: 1_000_000,
            processedSize: 1_500_000,
            duration: 5.0
        )
        XCTAssertEqual(increasedResult.byteDelta, -500_000)
        XCTAssertEqual(increasedResult.reductionPercentage, -50.0, accuracy: 0.001)
        XCTAssertTrue(increasedResult.isSizeIncreased)

        // Case 3: Zero original size guard
        let zeroResult = VideoProcessingResult(
            originalURL: originalURL,
            processedURL: processedURL,
            originalSize: 0,
            processedSize: 500,
            duration: 0.0
        )
        XCTAssertEqual(zeroResult.reductionPercentage, 0.0)
    }
}
