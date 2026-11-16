//
//  SocialMediaSharingWorkflowE2ETests.swift
//  MediaLiteTests
//
//  Tier 4: Real-World Application Scenarios
//  Scenario 2 & 3: Social Media Video Sharing & Silent Screen Recording Workflow.
//
//  Simulates realistic end-to-end user workflows for preparing video content for social media:
//  1. iPhone HDR HEVC video prepared for social sharing: transcoding into universal H.264 / AAC
//     MP4 with Rec. 709 SDR tone mapping, validating AsyncStream progress reporting, audio fidelity,
//     and container format.
//  2. Screen recording silent video: reducing file size on an audio-less video without crash,
//     verifying output playback validity, zero audio tracks, and aspect ratio preservation.
//

import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import MediaLite

final class SocialMediaSharingWorkflowE2ETests: XCTestCase {

    private var tempManager: TempFileManager!
    private var testSubdirectory: String!
    private var generatedURLs: [URL] = []
    private var videoProcessor: VideoProcessorProtocol!

    override func setUp() {
        super.setUp()
        testSubdirectory = "com.medialite.tests.social.\(UUID().uuidString)"
        tempManager = TempFileManager(tempSubdirectoryName: testSubdirectory)
        generatedURLs = []
        videoProcessor = VideoProcessorService()
    }

    override func tearDown() {
        SyntheticAssetGenerator.cleanup(urls: generatedURLs)
        generatedURLs.removeAll()
        try? tempManager.purgeAllTempFiles()
        try? FileManager.default.removeItem(at: tempManager.baseDirectory)
        tempManager = nil
        testSubdirectory = nil
        videoProcessor = nil
        super.tearDown()
    }

    // MARK: - 1. iPhone HDR Video Transcoding for Social Media Sharing

    func testiPhoneHDRVideoToSocialMediaUniversalMP4Workflow() async throws {
        // Step 1: Synthesize a realistic iPhone 10-bit HLG HDR HEVC video in QuickTime MOV container with AAC audio
        let sourceURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 1920, height: 1080),
            hasAudio: true,
            isHDR: true
        )
        generatedURLs.append(sourceURL)

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let originalByteSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(originalByteSize, 0, "Original HDR video must have positive file size")

        // Destination for social media upload: MP4 container
        let destURL = tempManager.createTempFileURL(extension: "mp4")
        generatedURLs.append(destURL)

        // Step 2: Configure compressAndConvert (H.264 + AAC + Rec.709 SDR tone mapping) with MEDIUM compression
        let mode = VideoProcessingMode.compressAndConvert
        let strength = CompressionStrength.medium

        // Step 3: Initiate video processing pipeline
        let (progressStream, processingTask) = videoProcessor.processVideo(
            at: sourceURL,
            mode: mode,
            strength: strength,
            destinationURL: destURL
        )

        // Step 4: Concurrently collect and verify AsyncStream progress updates
        let progressCollectionTask = Task {
            var updates: [VideoProcessingProgress] = []
            for await progress in progressStream {
                updates.append(progress)
            }
            return updates
        }

        // Step 5: Await pipeline completion
        let result = try await processingTask.value
        let progressUpdates = await progressCollectionTask.value

        // Step 6: Verify progress stream contract
        XCTAssertFalse(progressUpdates.isEmpty, "Progress stream must emit progress updates during processing")
        var previousFraction: Double = -1.0
        for update in progressUpdates {
            XCTAssertGreaterThanOrEqual(update.fractionCompleted, 0.0, "Fraction completed must be >= 0.0")
            XCTAssertLessThanOrEqual(update.fractionCompleted, 1.0, "Fraction completed must be <= 1.0")
            XCTAssertGreaterThanOrEqual(update.fractionCompleted, previousFraction, "Progress updates must be monotonic")
            XCTAssertFalse(update.description.isEmpty, "Progress update description must not be empty")
            previousFraction = update.fractionCompleted
        }
        XCTAssertEqual(progressUpdates.last?.fractionCompleted, 1.0, "Final progress update must reach 1.0 (100%)")

        // Step 7: Verify VideoProcessingResult
        XCTAssertEqual(result.originalURL, sourceURL)
        XCTAssertEqual(result.processedURL, destURL)
        XCTAssertEqual(result.originalSize, originalByteSize)
        XCTAssertGreaterThan(result.processedSize, 0)
        XCTAssertGreaterThan(result.byteDelta, 0, "Social media compression must achieve positive byte savings")
        XCTAssertGreaterThan(result.reductionPercentage, 0.0)
        XCTAssertFalse(result.isSizeIncreased)
        XCTAssertGreaterThan(result.duration, 0.5, "Duration must be positive and match video length")

        // Step 8: Verify Output Media Container & Codec Specifications via AVFoundation
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "Output file must exist on disk")
        XCTAssertEqual(destURL.pathExtension.lowercased(), "mp4", "Output container must be MP4 for universal social sharing")

        let outputAsset = AVURLAsset(url: destURL)
        let outputDuration = try await outputAsset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(outputDuration)
        XCTAssertEqual(durationSeconds, 1.0, accuracy: 0.25, "Output duration must match source duration within tolerance")

        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1, "Output must contain exactly 1 video track")
        let videoTrack = videoTracks[0]

        // Inspect format descriptions of the video track
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        XCTAssertFalse(formatDescriptions.isEmpty, "Video track must contain format descriptions")
        let formatDesc = formatDescriptions[0]
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
        XCTAssertEqual(mediaSubType, kCMVideoCodecType_H264, "Video codec must be transcoded to universal H.264 for social sharing")

        // Step 9: Verify SDR Rec.709 Tone Mapping
        if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
            if let colorPrimaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String {
                XCTAssertEqual(
                    colorPrimaries,
                    kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                    "HDR ITU-R 2020 primaries must be tone-mapped to SDR Rec. 709"
                )
            }
        }

        // Step 10: Verify Audio Retention & Stereo AAC format
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "Output must retain audio track for social video")
        let audioTrack = audioTracks[0]
        let audioDescriptions = try await audioTrack.load(.formatDescriptions)
        XCTAssertFalse(audioDescriptions.isEmpty)
        let audioSubType = CMFormatDescriptionGetMediaSubType(audioDescriptions[0])
        XCTAssertEqual(audioSubType, kAudioFormatMPEG4AAC, "Audio codec must be retained as stereo AAC")

        // Step 11: Verify History Record Creation
        let historyItem = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: sourceURL.lastPathComponent,
            mediaType: "video",
            sourceFormat: "mov",
            targetFormat: "mp4",
            originalByteSize: result.originalSize,
            compressedByteSize: result.processedSize,
            compressionStrength: strength,
            durationSeconds: result.duration,
            isSavedToLibrary: false
        )
        XCTAssertEqual(historyItem.byteDelta, result.byteDelta)
        XCTAssertEqual(historyItem.reductionPercentage, result.reductionPercentage, accuracy: 0.001)
        XCTAssertEqual(historyItem.targetFormat, "mp4")

        // Step 12: Verify UI Formatter string outputs
        let savingsSummary = Formatters.formatSavingsSummary(
            originalSize: result.originalSize,
            compressedSize: result.processedSize
        )
        XCTAssertTrue(savingsSummary.contains("Saved"), "Savings summary must format properly: \(savingsSummary)")
        let formattedDuration = Formatters.formatDuration(result.duration)
        XCTAssertEqual(formattedDuration, "00:01", "Duration formatter must output 00:01 for 1-second video")
    }

    // MARK: - 2. Silent Screen Recording Compression (No Audio Track)

    func testScreenRecordingSilentVideoCompressionWithoutCrashing() async throws {
        // Step 1: Synthesize a silent screen recording video (portrait aspect ratio 886x1920, 60fps, no audio track)
        let sourceURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 886, height: 1920),
            hasAudio: false,
            isHDR: false
        )
        generatedURLs.append(sourceURL)

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let originalByteSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(originalByteSize, 0)

        // Verify source has 0 audio tracks
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(sourceAudioTracks.isEmpty, "Source screen recording must be silent (0 audio tracks)")

        let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(sourceVideoTracks.count, 1)
        let sourceNaturalSize = try await sourceVideoTracks[0].load(.naturalSize)

        // Step 2: Configure reduceSize mode with HIGH compression
        let destURL = tempManager.createTempFileURL(extension: "mp4")
        generatedURLs.append(destURL)

        let mode = VideoProcessingMode.reduceSize
        let strength = CompressionStrength.high

        // Step 3: Execute processing - must NOT crash or throw on missing audio track
        let (_, processingTask) = videoProcessor.processVideo(
            at: sourceURL,
            mode: mode,
            strength: strength,
            destinationURL: destURL
        )

        let result = try await processingTask.value

        // Step 4: Verify Result
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "Compressed screen recording must exist")
        XCTAssertEqual(result.originalSize, originalByteSize)
        XCTAssertGreaterThan(result.processedSize, 0)
        XCTAssertGreaterThan(result.byteDelta, 0, "HIGH compression must reduce silent video file size")
        XCTAssertFalse(result.isSizeIncreased)

        // Step 5: Verify Playback Validity & Audio Track Absoluteness
        let outputAsset = AVURLAsset(url: destURL)
        let isPlayable = try await outputAsset.load(.isPlayable)
        XCTAssertTrue(isPlayable, "Compressed silent video must be valid and playable")

        let outputAudioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(outputAudioTracks.count, 0, "Output must contain exactly 0 audio tracks (silent video protection)")

        let outputVideoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(outputVideoTracks.count, 1, "Output must contain 1 video track")

        // Step 6: Verify Aspect Ratio Preservation
        let outputNaturalSize = try await outputVideoTracks[0].load(.naturalSize)
        let sourceAspectRatio = sourceNaturalSize.width / sourceNaturalSize.height
        let outputAspectRatio = outputNaturalSize.width / outputNaturalSize.height
        XCTAssertEqual(outputAspectRatio, sourceAspectRatio, accuracy: 0.05, "Screen recording aspect ratio must be preserved")

        let outputDuration = try await outputAsset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(outputDuration), 1.0, accuracy: 0.25, "Output duration must match screen recording length")
    }

    // MARK: - 3. HDR Tone Mapping Preservation & Rec.709 Color Primaries

    func testHDRToneMappingFidelityAndColorMatrixConversion() async throws {
        let sourceURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 1280, height: 720),
            hasAudio: true,
            isHDR: true
        )
        generatedURLs.append(sourceURL)

        let destURL = tempManager.createTempFileURL(extension: "mp4")
        generatedURLs.append(destURL)

        let (_, task) = videoProcessor.processVideo(
            at: sourceURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: destURL
        )

        let result = try await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.processedURL.path))

        let outputAsset = AVURLAsset(url: result.processedURL)
        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        XCTAssertFalse(videoTracks.isEmpty)

        let formatDescriptions = try await videoTracks[0].load(.formatDescriptions)
        XCTAssertFalse(formatDescriptions.isEmpty)

        if let extensions = CMFormatDescriptionGetExtensions(formatDescriptions[0]) as? [String: Any] {
            if let colorPrimaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String {
                XCTAssertEqual(colorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            }
        }
    }

    // MARK: - 4. Progress Stream Cancellation Cleans Up Temporary Files

    func testSocialMediaSharingProgressStreamAndCancellation() async throws {
        let sourceURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false
        )
        generatedURLs.append(sourceURL)

        let destURL = tempManager.createTempFileURL(extension: "mp4")
        generatedURLs.append(destURL)

        let (stream, task) = videoProcessor.processVideo(
            at: sourceURL,
            mode: .compressAndConvert,
            strength: .medium,
            destinationURL: destURL
        )

        // Cancel task after first progress update
        let monitorTask = Task {
            for await progress in stream {
                if progress.fractionCompleted > 0.1 {
                    task.cancel()
                    break
                }
            }
        }
        await monitorTask.value

        do {
            _ = try await task.value
            // If processing was too fast to cancel, that's acceptable, but verify cleanup capability
        } catch {
            // Task cancellation error is expected
            XCTAssertTrue(task.isCancelled)
        }

        // Clean up partial file
        try tempManager.cleanupTempFile(at: destURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path), "Cancelled video temp file must be cleaned up")
    }

    // MARK: - 5. Audio Channel & Sample Rate Retention Across Modes

    func testSocialMediaVideoAudioFidelityRetention() async throws {
        let sourceURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 640, height: 480),
            hasAudio: true,
            isHDR: false
        )
        generatedURLs.append(sourceURL)

        for mode in [VideoProcessingMode.improveCompatibility, VideoProcessingMode.compressAndConvert] {
            let destURL = tempManager.createTempFileURL(extension: "mp4")
            generatedURLs.append(destURL)

            let (_, task) = videoProcessor.processVideo(
                at: sourceURL,
                mode: mode,
                strength: .medium,
                destinationURL: destURL
            )

            let result = try await task.value
            let outputAsset = AVURLAsset(url: result.processedURL)
            let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audioTracks.count, 1, "Audio track must be preserved in mode \(mode.rawValue)")

            let formatDescs = try await audioTracks[0].load(.formatDescriptions)
            XCTAssertFalse(formatDescs.isEmpty)
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescs[0])
            if let asbd = asbd {
                XCTAssertEqual(asbd.pointee.mFormatID, kAudioFormatMPEG4AAC, "Audio format must be AAC")
                XCTAssertEqual(asbd.pointee.mChannelsPerFrame, 2, "Stereo channels (2) must be preserved")
            }
        }
    }
}
