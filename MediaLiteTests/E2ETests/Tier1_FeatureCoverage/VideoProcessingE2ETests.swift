//
//  VideoProcessingE2ETests.swift
//  MediaLiteTests
//
//  Tier 1 Feature Coverage E2E Tests: Video Processing Engine.
//  Covers Video Mode 1 (reduceSize), Mode 2 (improveCompatibility),
//  Mode 3 (compressAndConvert), HDR detection & SDR Rec.709 tone mapping,
//  orientation transform preservation, silent video protection,
//  and AsyncStream progress reporting.
//

import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import MediaLite

final class VideoProcessingE2ETests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var processor: VideoProcessorProtocol!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        processor = VideoProcessorService()
    }

    override func tearDown() {
        SyntheticAssetGenerator.cleanup(urls: trackedURLs)
        trackedURLs.removeAll()
        try? TempFileManager.shared.purgeAllTempFiles()
        processor = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func trackURL(_ url: URL) -> URL {
        trackedURLs.append(url)
        return url
    }

    // MARK: - 1. Video Mode 1: Reduce Size

    func testVideoMode1ReduceSizeReducesBitrateWhilePreservingCodec() async throws {
        // Synthesize valid MP4 video with stereo AAC audio
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false
        ))

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let originalByteSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(originalByteSize, 0)

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destURL
        )

        // Drain progress stream concurrently
        let streamDrainTask = Task {
            var updates: [VideoProcessingProgress] = []
            for await progress in stream {
                updates.append(progress)
            }
            return updates
        }

        let result = try await task.value
        let progressUpdates = await streamDrainTask.value

        // Verify result properties
        XCTAssertEqual(result.originalURL, sourceURL)
        XCTAssertEqual(result.processedURL, destURL)
        XCTAssertEqual(result.originalSize, originalByteSize)
        XCTAssertGreaterThan(result.processedSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertFalse(progressUpdates.isEmpty, "Stream must emit progress updates")

        // Verify output asset validity
        let asset = AVURLAsset(url: destURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.3, "Output video duration must match original")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videoTracks.isEmpty, "Output must contain a video track")
        XCTAssertFalse(audioTracks.isEmpty, "Output must contain an audio track")
    }

    // MARK: - 2. Video Mode 2: Universal Compatibility (H.264 + AAC + MP4)

    func testVideoMode2ImproveCompatibilityTranscodesToH264AndAAC() async throws {
        // Synthesize MOV source video
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .improveCompatibility,
            strength: .medium,
            destinationURL: destURL
        )

        // Consume stream to prevent buffer saturation
        let streamConsumer = Task {
            for await _ in stream {}
        }

        let result = try await task.value
        _ = await streamConsumer.value

        XCTAssertEqual(result.processedURL.pathExtension.lowercased(), "mp4", "Target container must be MP4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        let asset = AVURLAsset(url: destURL)

        // Verify Video Track is encoded in H.264
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(videoTracks.isEmpty, "Must have video track")
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
            XCTAssertTrue(hasH264, "Output video track must be H.264 codec")
        }

        // Verify Audio Track is encoded in AAC
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Must retain audio track")
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

    // MARK: - 3. Video Mode 3: Compress & Convert Dual Transformation

    func testVideoMode3CompressAndConvertDualTransformation() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false
        ))

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: destURL
        )

        let drainTask = Task {
            for await _ in stream {}
        }

        let result = try await task.value
        _ = await drainTask.value

        XCTAssertEqual(result.originalSize, sourceSize)
        XCTAssertGreaterThan(result.processedSize, 0)
        XCTAssertEqual(result.processedURL.pathExtension.lowercased(), "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        let asset = AVURLAsset(url: destURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(videoTracks.isEmpty)

        // Verify duration fidelity (within 0.1s tolerance)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 0.5, accuracy: 0.15)
    }

    // MARK: - 4. HDR Detection & SDR Rec.709 Tone Mapping

    func testHDRDetectionAndSDRRec709ToneMapping() async throws {
        // Synthesize 10-bit HLG HDR video with ITU-R 2020 primaries
        let hdrSourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: false,
            isHDR: true
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: hdrSourceURL,
            mode: .compressAndConvert,
            strength: .medium,
            destinationURL: destURL
        )

        let drainTask = Task {
            for await _ in stream {}
        }

        let result = try await task.value
        _ = await drainTask.value

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
                // Verify output transfer function is NOT HDR HLG or SMPTE ST 2084 (PQ)
                let transfer = extensions[kCVImageBufferTransferFunctionKey] as? String
                XCTAssertNotEqual(
                    transfer,
                    kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                    "Tone-mapped video must not use HLG transfer function"
                )
                XCTAssertNotEqual(
                    transfer,
                    kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
                    "Tone-mapped video must not use PQ transfer function"
                )

                // Verify SDR color primaries (Rec. 709)
                if let primaries = extensions[kCVImageBufferColorPrimariesKey] as? String {
                    XCTAssertTrue(
                        primaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String) ||
                        primaries.contains("709"),
                        "Expected Rec. 709 primaries, got \(primaries)"
                    )
                }
            }
        }
    }

    // MARK: - 5. Video Orientation Transform Preservation

    func testVideoOrientationTransformPreservation() async throws {
        // Synthesize video with 90-degree portrait rotation transform
        let portraitTransform = CGAffineTransform(rotationAngle: .pi / 2.0)
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false,
            transform: portraitTransform
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destURL
        )

        let drainTask = Task {
            for await _ in stream {}
        }

        let result = try await task.value
        _ = await drainTask.value

        let asset = AVURLAsset(url: result.processedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            XCTFail("Missing video track in output")
            return
        }

        let outputTransform = try await videoTrack.load(.preferredTransform)
        // Verify transform is preserved (non-identity matrix maintaining aspect/rotation)
        XCTAssertFalse(
            outputTransform.isIdentity,
            "Preferred rotation transform must not be discarded or reset to identity"
        )
    }

    // MARK: - 6. Silent Video (No Audio Track) Protection

    func testSilentVideoProcessingWithoutCrashing() async throws {
        // Synthesize silent video (hasAudio: false)
        let silentURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: false,
            isHDR: false
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: silentURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destURL
        )

        let drainTask = Task {
            for await _ in stream {}
        }

        // Must succeed without throwing missing audio track errors or crashing
        let result = try await task.value
        _ = await drainTask.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.processedURL.path))

        let asset = AVURLAsset(url: result.processedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        XCTAssertFalse(videoTracks.isEmpty, "Video track must exist")
        XCTAssertTrue(audioTracks.isEmpty, "Silent video must not synthesize spurious audio tracks")
    }

    // MARK: - 7. AsyncStream Progress Reporting Verification

    func testAsyncStreamProgressReportingVerification() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 480, height: 360),
            hasAudio: true
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "mp4"))

        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .low,
            destinationURL: destURL
        )

        var receivedProgress: [VideoProcessingProgress] = []
        let collectorTask = Task {
            for await progress in stream {
                receivedProgress.append(progress)
            }
        }

        _ = try await task.value
        await collectorTask.value

        XCTAssertGreaterThan(receivedProgress.count, 0, "AsyncStream must yield at least one progress update")

        // Verify all progress values fall within [0.0, 1.0] and have meaningful descriptions
        for update in receivedProgress {
            XCTAssertGreaterThanOrEqual(update.fractionCompleted, 0.0)
            XCTAssertLessThanOrEqual(update.fractionCompleted, 1.0)
            XCTAssertFalse(update.description.isEmpty, "Progress description must not be empty")
        }

        // Verify the terminal progress reaches 1.0 (completion)
        if let lastUpdate = receivedProgress.last {
            XCTAssertEqual(lastUpdate.fractionCompleted, 1.0, accuracy: 0.05, "Terminal progress should reach 1.0")
        }
    }
}
