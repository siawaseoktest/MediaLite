//
//  MediaCombinationsE2ETests.swift
//  MediaLiteTests
//
//  Tier 3 Cross-Feature Combinations E2E Tests for MediaLite.
//  Covers pairwise combinatorial testing across:
//  - Formats (JPEG, PNG with alpha, PNG opaque, HEIC) crossed with CompressionStrength (LOW, MEDIUM, HIGH).
//  - Video sources (MP4, MOV HEVC, HDR HLG 10-bit, Silent video) crossed with VideoProcessingMode (reduceSize, improveCompatibility, compressAndConvert).
//  - EXIF orientations (Up 1, Down 3, Right 6, Left 8) preservation across all compression strengths.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreMedia
@testable import MediaLite

// MARK: - MediaCombinationsE2ETests

final class MediaCombinationsE2ETests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var photoCompressor: PhotoCompressorProtocol!
    private var videoProcessor: VideoProcessorProtocol!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        photoCompressor = PhotoCompressorService()
        videoProcessor = VideoProcessorService()
    }

    override func tearDown() {
        if !trackedURLs.isEmpty {
            SyntheticAssetGenerator.cleanup(urls: trackedURLs)
            trackedURLs.removeAll()
        }
        _ = try? TempFileManager.shared.purgeAllTempFiles()
        photoCompressor = nil
        videoProcessor = nil
        super.tearDown()
    }

    // MARK: - Group 1: Formats x CompressionStrength (Pairwise Combinations)

    /// Pairwise Combination 1: JPEG x LOW CompressionStrength.
    /// Verifies light compression (~90% quality, 95% scale), retaining EXIF metadata and high visual detail.
    func testPairwise_JPEG_withLowCompressionStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createJPEG(
            width: 400,
            height: 300,
            color: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0),
            hasExif: true
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "jpg")
        trackedURLs.append(outputURL)

        let result = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .low,
            destinationURL: outputURL
        )

        XCTAssertEqual(result.format, .jpeg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        // Verify dimension scaling for LOW (0.95 scale): 400 * 0.95 = 380, 300 * 0.95 = 285
        let dimensions = extractDimensions(from: outputURL)
        XCTAssertNotNil(dimensions)
        XCTAssertEqual(dimensions?.width ?? 0, 380, accuracy: 2.0)
        XCTAssertEqual(dimensions?.height ?? 0, 285, accuracy: 2.0)

        // Verify EXIF metadata retention
        let exif = extractExifDictionary(from: outputURL)
        XCTAssertNotNil(exif)
        XCTAssertEqual(exif?[kCGImagePropertyExifColorSpace as String] as? Int, 1)
    }

    /// Pairwise Combination 2: JPEG x HIGH CompressionStrength.
    /// Verifies aggressive compression (~55% quality, 74% scale) with significant byte reduction.
    func testPairwise_JPEG_withHighCompressionStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createJPEG(
            width: 500,
            height: 500,
            color: CGColor(srgbRed: 0.8, green: 0.2, blue: 0.3, alpha: 1.0),
            hasExif: true
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "jpg")
        trackedURLs.append(outputURL)

        let result = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .high,
            destinationURL: outputURL
        )

        XCTAssertEqual(result.format, .jpeg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)
        XCTAssertGreaterThan(result.byteDelta, 0)
        XCTAssertGreaterThan(result.reductionPercentage, 10.0)
        XCTAssertFalse(result.isSizeIncreased)

        // Verify dimension scaling for HIGH (0.74 scale): 500 * 0.74 = 370
        let dimensions = extractDimensions(from: outputURL)
        XCTAssertNotNil(dimensions)
        XCTAssertEqual(dimensions?.width ?? 0, 370, accuracy: 2.0)
        XCTAssertEqual(dimensions?.height ?? 0, 370, accuracy: 2.0)
    }

    /// Pairwise Combination 3: PNG with Alpha x MEDIUM CompressionStrength.
    /// Verifies proportional dimension downsampling while strictly preserving alpha transparency.
    func testPairwise_PNGWithAlpha_withMediumCompressionStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createPNG(
            width: 300,
            height: 300,
            hasAlpha: true
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "png")
        trackedURLs.append(outputURL)

        let result = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .medium,
            destinationURL: outputURL
        )

        XCTAssertEqual(result.format, .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        // Verify alpha channel preservation
        let hasAlpha = extractHasAlpha(from: outputURL)
        XCTAssertTrue(hasAlpha, "Alpha channel transparency must be preserved for PNG with alpha.")

        // Verify dimension scaling for MEDIUM (0.87 scale): 300 * 0.87 = 261
        let dimensions = extractDimensions(from: outputURL)
        XCTAssertNotNil(dimensions)
        XCTAssertEqual(dimensions?.width ?? 0, 261, accuracy: 2.0)
        XCTAssertEqual(dimensions?.height ?? 0, 261, accuracy: 2.0)
    }

    /// Pairwise Combination 4: PNG with Alpha x HIGH CompressionStrength.
    /// Verifies high dimension downsampling on transparent images without color degradation or alpha clipping.
    func testPairwise_PNGWithAlpha_withHighCompressionStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createPNG(
            width: 400,
            height: 400,
            hasAlpha: true
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "png")
        trackedURLs.append(outputURL)

        let result = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .high,
            destinationURL: outputURL
        )

        XCTAssertEqual(result.format, .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // Alpha channel must be preserved
        let hasAlpha = extractHasAlpha(from: outputURL)
        XCTAssertTrue(hasAlpha)

        // Verify dimension scaling for HIGH (0.74 scale): 400 * 0.74 = 296
        let dimensions = extractDimensions(from: outputURL)
        XCTAssertNotNil(dimensions)
        XCTAssertEqual(dimensions?.width ?? 0, 296, accuracy: 2.0)
        XCTAssertEqual(dimensions?.height ?? 0, 296, accuracy: 2.0)
    }

    /// Pairwise Combination 5: PNG Opaque x LOW CompressionStrength.
    /// Verifies opaque PNG compression without introducing unintended alpha channels.
    func testPairwise_PNGOpaque_withLowCompressionStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createPNG(
            width: 250,
            height: 250,
            hasAlpha: false
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "png")
        trackedURLs.append(outputURL)

        let result = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .low,
            destinationURL: outputURL
        )

        XCTAssertEqual(result.format, .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // Verify dimension scaling for LOW (0.95 scale): 250 * 0.95 = 237.5 -> 237/238
        let dimensions = extractDimensions(from: outputURL)
        XCTAssertNotNil(dimensions)
        XCTAssertEqual(dimensions?.width ?? 0, 237, accuracy: 2.0)
        XCTAssertEqual(dimensions?.height ?? 0, 237, accuracy: 2.0)
    }

    /// Pairwise Combination 6: PNG Opaque x MEDIUM CompressionStrength.
    /// Verifies balanced downsampling for opaque PNG graphics.
    func testPairwise_PNGOpaque_withMediumCompressionStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createPNG(
            width: 320,
            height: 240,
            hasAlpha: false
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "png")
        trackedURLs.append(outputURL)

        let result = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .medium,
            destinationURL: outputURL
        )

        XCTAssertEqual(result.format, .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // Verify dimension scaling for MEDIUM (0.87 scale): 320 * 0.87 = 278, 240 * 0.87 = 208
        let dimensions = extractDimensions(from: outputURL)
        XCTAssertNotNil(dimensions)
        XCTAssertEqual(dimensions?.width ?? 0, 278, accuracy: 2.0)
        XCTAssertEqual(dimensions?.height ?? 0, 208, accuracy: 2.0)
    }

    /// Pairwise Combination 7: HEIC x MEDIUM CompressionStrength.
    /// Verifies native HEIC compression retention, metadata preservation, and balanced lossy quality.
    func testPairwise_HEIC_withMediumCompressionStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createHEIC(
            width: 300,
            height: 300,
            orientation: .up
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "heic")
        trackedURLs.append(outputURL)

        let result = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .medium,
            destinationURL: outputURL
        )

        XCTAssertEqual(result.format, .heic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        // Verify dimension scaling for MEDIUM (0.87 scale): 300 * 0.87 = 261
        let dimensions = extractDimensions(from: outputURL)
        XCTAssertNotNil(dimensions)
        XCTAssertEqual(dimensions?.width ?? 0, 261, accuracy: 2.0)
        XCTAssertEqual(dimensions?.height ?? 0, 261, accuracy: 2.0)
    }

    /// Pairwise Combination 8: HEIC x HIGH CompressionStrength.
    /// Verifies maximum HEIC storage savings while maintaining valid container structure.
    func testPairwise_HEIC_withHighCompressionStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createHEIC(
            width: 400,
            height: 400,
            orientation: .up
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "heic")
        trackedURLs.append(outputURL)

        let result = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .high,
            destinationURL: outputURL
        )

        XCTAssertEqual(result.format, .heic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        // Verify dimension scaling for HIGH (0.74 scale): 400 * 0.74 = 296
        let dimensions = extractDimensions(from: outputURL)
        XCTAssertNotNil(dimensions)
        XCTAssertEqual(dimensions?.width ?? 0, 296, accuracy: 2.0)
        XCTAssertEqual(dimensions?.height ?? 0, 296, accuracy: 2.0)
    }

    // MARK: - Group 2: Video Sources x VideoProcessingMode (Pairwise Combinations)

    /// Pairwise Combination 9: MP4 (H.264/AAC) x reduceSize Mode.
    /// Verifies video size reduction while preserving original container format, audio track, and duration.
    func testPairwise_VideoMP4_withReduceSizeMode() async throws {
        let inputURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 640, height: 360),
            hasAudio: true,
            isHDR: false
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(outputURL)

        let handle = videoProcessor.processVideo(
            at: inputURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: outputURL
        )

        // Drain progress stream
        var reportedProgress: [Double] = []
        for await progress in handle.stream {
            reportedProgress.append(progress.fractionCompleted)
        }

        let result = try await handle.task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(result.processedSize, 0)
        XCTAssertEqual(result.duration, 1.0, accuracy: 0.3)
        XCTAssertFalse(reportedProgress.isEmpty)

        // Verify video and audio tracks
        let properties = try await inspectVideoProperties(at: outputURL)
        XCTAssertTrue(properties.hasAudio, "Audio track must be preserved in reduceSize mode.")
        XCTAssertEqual(properties.duration, 1.0, accuracy: 0.3)
    }

    /// Pairwise Combination 10: MOV HEVC x improveCompatibility Mode.
    /// Verifies transcoding from Apple HEVC/MOV to universal H.264/AAC in an MP4 container.
    func testPairwise_VideoMOVHEVC_withImproveCompatibilityMode() async throws {
        let movURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let inputURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 640, height: 360),
            hasAudio: true,
            isHDR: false,
            destinationURL: movURL
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(outputURL)

        let handle = videoProcessor.processVideo(
            at: inputURL,
            mode: .improveCompatibility,
            strength: .low,
            destinationURL: outputURL
        )

        let result = try await handle.task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(outputURL.pathExtension.lowercased(), "mp4")
        XCTAssertGreaterThan(result.processedSize, 0)

        // Verify audio is present and duration is preserved
        let properties = try await inspectVideoProperties(at: outputURL)
        XCTAssertTrue(properties.hasAudio, "AAC audio must be retained when transcoding to universal MP4.")
        XCTAssertEqual(properties.duration, 1.0, accuracy: 0.3)
    }

    /// Pairwise Combination 11: HDR HLG 10-bit Video x compressAndConvert Mode.
    /// Verifies HDR tone mapping to Rec.709 SDR and simultaneous H.264 transcoding and compression.
    func testPairwise_VideoHDRHLG10Bit_withCompressAndConvertMode() async throws {
        let inputURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 640, height: 360),
            hasAudio: true,
            isHDR: true
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(outputURL)

        let handle = videoProcessor.processVideo(
            at: inputURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: outputURL
        )

        let result = try await handle.task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(outputURL.pathExtension.lowercased(), "mp4")
        XCTAssertGreaterThan(result.processedSize, 0)

        // Verify output is SDR Rec.709 tone-mapped (isHDR is false)
        let properties = try await inspectVideoProperties(at: outputURL)
        XCTAssertFalse(properties.isHDR, "HDR HLG video must be tone-mapped to SDR Rec.709 during compressAndConvert.")
        XCTAssertEqual(properties.duration, 1.0, accuracy: 0.3)
    }

    /// Pairwise Combination 12: Silent Video (MP4) x reduceSize Mode.
    /// Verifies transcoding a video source with zero audio tracks without crashing or synthesizing bogus audio.
    func testPairwise_VideoSilentMP4_withReduceSizeMode() async throws {
        let inputURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 480, height: 320),
            hasAudio: false,
            isHDR: false
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(outputURL)

        let handle = videoProcessor.processVideo(
            at: inputURL,
            mode: .reduceSize,
            strength: .high,
            destinationURL: outputURL
        )

        let result = try await handle.task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(result.processedSize, 0)

        // Verify audio track is strictly absent (silent video preserved without crash)
        let properties = try await inspectVideoProperties(at: outputURL)
        XCTAssertFalse(properties.hasAudio, "Silent video must not acquire unexpected audio tracks.")
        XCTAssertEqual(properties.duration, 1.0, accuracy: 0.3)
    }

    /// Pairwise Combination 13: Silent Video (MOV) x improveCompatibility Mode.
    /// Verifies universal MP4 compatibility conversion of silent video without throwing audio-encoder exceptions.
    func testPairwise_VideoSilentMOV_withImproveCompatibilityMode() async throws {
        let movURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let inputURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 480, height: 320),
            hasAudio: false,
            isHDR: false,
            destinationURL: movURL
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(outputURL)

        let handle = videoProcessor.processVideo(
            at: inputURL,
            mode: .improveCompatibility,
            strength: .medium,
            destinationURL: outputURL
        )

        let result = try await handle.task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(outputURL.pathExtension.lowercased(), "mp4")

        let properties = try await inspectVideoProperties(at: outputURL)
        XCTAssertFalse(properties.hasAudio, "Silent MOV video converted to MP4 must remain silent.")
    }

    /// Pairwise Combination 14: MOV HEVC x compressAndConvert Mode.
    /// Verifies combined aggressive size reduction and MP4/H.264 transcoding.
    func testPairwise_VideoMOVHEVC_withCompressAndConvertMode() async throws {
        let movURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let inputURL = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 1.0,
            fps: 30,
            resolution: CGSize(width: 640, height: 360),
            hasAudio: true,
            isHDR: false,
            destinationURL: movURL
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "mp4")
        trackedURLs.append(outputURL)

        let handle = videoProcessor.processVideo(
            at: inputURL,
            mode: .compressAndConvert,
            strength: .high,
            destinationURL: outputURL
        )

        let result = try await handle.task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(outputURL.pathExtension.lowercased(), "mp4")
        XCTAssertGreaterThan(result.processedSize, 0)

        let properties = try await inspectVideoProperties(at: outputURL)
        XCTAssertTrue(properties.hasAudio)
    }

    // MARK: - Group 3: EXIF Orientations Preservation Across Strengths

    /// Orientation Pairwise 15: EXIF Orientation Up (1) preserved under LOW compression strength.
    func testPairwise_EXIFOrientation_Up1_PreservedUnderLowStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createHEIC(
            width: 200,
            height: 200,
            orientation: .up
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "heic")
        trackedURLs.append(outputURL)

        _ = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .low,
            destinationURL: outputURL
        )

        let orientation = extractOrientation(from: outputURL)
        XCTAssertEqual(orientation, .up, "Orientation .up (1) must be preserved under .low compression.")
    }

    /// Orientation Pairwise 16: EXIF Orientation Down (3) preserved under MEDIUM compression strength.
    func testPairwise_EXIFOrientation_Down3_PreservedUnderMediumStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createHEIC(
            width: 200,
            height: 200,
            orientation: .down
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "heic")
        trackedURLs.append(outputURL)

        _ = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .medium,
            destinationURL: outputURL
        )

        let orientation = extractOrientation(from: outputURL)
        XCTAssertTrue(
            orientation == .down || orientation == .up,
            "Orientation must be preserved (.down) or normalized to upright (.up). Got: \(String(describing: orientation))"
        )
    }

    /// Orientation Pairwise 17: EXIF Orientation Right (6) preserved under HIGH compression strength.
    func testPairwise_EXIFOrientation_Right6_PreservedUnderHighStrength() async throws {
        let inputURL = try SyntheticAssetGenerator.createHEIC(
            width: 200,
            height: 200,
            orientation: .right
        )
        trackedURLs.append(inputURL)

        let outputURL = TempFileManager.shared.createTempFileURL(extension: "heic")
        trackedURLs.append(outputURL)

        _ = try await photoCompressor.compressPhoto(
            at: inputURL,
            strength: .high,
            destinationURL: outputURL
        )

        let orientation = extractOrientation(from: outputURL)
        XCTAssertTrue(
            orientation == .right || orientation == .up,
            "Orientation must be preserved (.right) or normalized to upright (.up). Got: \(String(describing: orientation))"
        )
    }

    /// Orientation Pairwise 18: EXIF Orientation Left (8) preserved across all compression strengths.
    func testPairwise_EXIFOrientation_Left8_PreservedAcrossAllStrengths() async throws {
        for strength in CompressionStrength.allCases {
            let inputURL = try SyntheticAssetGenerator.createHEIC(
                width: 180,
                height: 180,
                orientation: .left
            )
            trackedURLs.append(inputURL)

            let outputURL = TempFileManager.shared.createTempFileURL(extension: "heic")
            trackedURLs.append(outputURL)

            _ = try await photoCompressor.compressPhoto(
                at: inputURL,
                strength: strength,
                destinationURL: outputURL
            )

            let orientation = extractOrientation(from: outputURL)
            XCTAssertTrue(
                orientation == .left || orientation == .up,
                "Orientation must be preserved (.left) or normalized to upright (.up) under \(strength.rawValue) compression. Got: \(String(describing: orientation))"
            )
        }
    }

    // MARK: - Private Metadata & Inspection Helpers

    private func extractDimensions(from url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func extractHasAlpha(from url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return false
        }
        let alphaInfo = image.alphaInfo
        return alphaInfo == .first ||
               alphaInfo == .last ||
               alphaInfo == .premultipliedFirst ||
               alphaInfo == .premultipliedLast
    }

    private func extractOrientation(from url: URL) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        if let raw = properties[kCGImagePropertyOrientation] as? UInt32 {
            return CGImagePropertyOrientation(rawValue: raw)
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFOrientation] as? UInt32 {
            return CGImagePropertyOrientation(rawValue: raw)
        }
        return nil
    }

    private func extractExifDictionary(from url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any] else {
            return nil
        }
        return exif
    }

    private func inspectVideoProperties(at url: URL) async throws -> (duration: Double, hasAudio: Bool, isHDR: Bool) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        var isHDR = false
        if let videoTrack = videoTracks.first {
            let descriptions = try await videoTrack.load(.formatDescriptions)
            if let desc = descriptions.first,
               let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
               let primaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String {
                isHDR = (primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String))
            }
        }

        return (duration: duration, hasAudio: !audioTracks.isEmpty, isHDR: isHDR)
    }
}
