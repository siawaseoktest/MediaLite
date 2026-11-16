//
//  MediaBoundaryE2ETests.swift
//  MediaLiteTests
//
//  Tier 2: Boundary & Corner Cases E2E Tests
//  Covers 1x1 image compression (JPEG/PNG/HEIC), extreme aspect ratios (4000x1, 1x4000),
//  large dimension scaling, ultra-short sub-second video processing, and zero-byte file handling.
//

import XCTest
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import AVFoundation
@testable import MediaLite

final class MediaBoundaryE2ETests: XCTestCase {

    private var tempURLsToCleanup: [URL] = []
    private var tempFileManager: TempFileManager!

    override func setUp() {
        super.setUp()
        tempFileManager = TempFileManager(tempSubdirectoryName: "com.medialite.tests.tier2.boundary.\(UUID().uuidString)")
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

    // MARK: - 1. 1x1 Image Compression Tests

    /// Verifies that a 1x1 pixel JPEG can be compressed with aggressive HIGH strength downsampling
    /// without dividing by zero, crashing, or producing invalid zero-dimension output.
    func testCompress1x1JPEGImageBoundary() async throws {
        let sourceURL = trackForCleanup(
            try SyntheticAssetGenerator.createJPEG(
                width: 1,
                height: 1,
                color: CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1.0),
                hasExif: false
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "jpg"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .high,
            destinationURL: destinationURL
        )

        // Result validation
        XCTAssertEqual(result.format, .jpeg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        // Read image properties using ImageIO to verify dimensions are clamped to >= 1x1
        guard let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil) else {
            XCTFail("Failed to create CGImageSource from compressed 1x1 JPEG output")
            return
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read image properties from compressed 1x1 JPEG")
            return
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(width, 1, "Pixel width must be at least 1")
        XCTAssertGreaterThanOrEqual(height, 1, "Pixel height must be at least 1")
    }

    /// Verifies that a 1x1 pixel PNG with alpha transparency can be compressed without collapsing
    /// the alpha channel or failing dimension scaling.
    func testCompress1x1PNGWithAlphaBoundary() async throws {
        let sourceURL = trackForCleanup(
            try SyntheticAssetGenerator.createPNG(
                width: 1,
                height: 1,
                hasAlpha: true
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "png"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .medium,
            destinationURL: destinationURL
        )

        XCTAssertEqual(result.format, .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        guard let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil) else {
            XCTFail("Failed to create CGImageSource from compressed 1x1 PNG output")
            return
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read image properties from compressed 1x1 PNG")
            return
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(width, 1, "PNG pixel width must be at least 1")
        XCTAssertGreaterThanOrEqual(height, 1, "PNG pixel height must be at least 1")
    }

    /// Verifies that a 1x1 pixel HEIC container can be processed and re-encoded cleanly.
    func testCompress1x1HEICImageBoundary() async throws {
        let sourceURL = trackForCleanup(
            try SyntheticAssetGenerator.createHEIC(
                width: 1,
                height: 1,
                orientation: .up
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "heic"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .low,
            destinationURL: destinationURL
        )

        XCTAssertEqual(result.format, .heic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        guard let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil) else {
            XCTFail("Failed to create CGImageSource from compressed 1x1 HEIC output")
            return
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read image properties from compressed 1x1 HEIC")
            return
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(width, 1, "HEIC pixel width must be at least 1")
        XCTAssertGreaterThanOrEqual(height, 1, "HEIC pixel height must be at least 1")
    }

    // MARK: - 2. Extreme Aspect Ratios

    /// Verifies that an ultra-wide panoramic image (4000x2) scaled with HIGH strength (0.74 scale)
    /// does not round the height down to 0 pixels and maintains an extreme aspect ratio.
    func testExtremeAspectRatioUltraWidePanoramicImage() async throws {
        let sourceURL = trackForCleanup(
            try SyntheticAssetGenerator.createJPEG(
                width: 4000,
                height: 2,
                color: CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1.0),
                hasExif: false
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "jpg"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .high,
            destinationURL: destinationURL
        )

        XCTAssertEqual(result.format, .jpeg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        guard let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil) else {
            XCTFail("Failed to create CGImageSource from panoramic JPEG output")
            return
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read image properties from panoramic JPEG")
            return
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        XCTAssertGreaterThanOrEqual(height, 1, "Height must not collapse to 0 when downsampling ultra-wide image")
        XCTAssertGreaterThan(width, height * 100, "Aspect ratio must remain ultra-wide after downscaling")
    }

    /// Verifies that an ultra-tall tower image (2x4000) scaled with HIGH strength
    /// does not round the width down to 0 pixels and preserves the vertical orientation aspect.
    func testExtremeAspectRatioUltraTallTowerImage() async throws {
        let sourceURL = trackForCleanup(
            try SyntheticAssetGenerator.createPNG(
                width: 2,
                height: 4000,
                hasAlpha: false
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "png"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .high,
            destinationURL: destinationURL
        )

        XCTAssertEqual(result.format, .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertGreaterThan(result.compressedSize, 0)

        guard let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil) else {
            XCTFail("Failed to create CGImageSource from tower PNG output")
            return
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read image properties from tower PNG")
            return
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        XCTAssertGreaterThanOrEqual(width, 1, "Width must not collapse to 0 when downsampling ultra-tall image")
        XCTAssertGreaterThan(height, width * 100, "Aspect ratio must remain ultra-tall after downscaling")
    }

    // MARK: - 3. Large Dimension Scaling Boundary

    /// Verifies downsampling of high-resolution 12-Megapixel image (4000x3000) with MEDIUM strength
    /// achieves measurable byte savings without memory blowup, and correctly scales dimensions.
    func testLargeDimensionHighResolutionScalingBoundary() async throws {
        let sourceURL = trackForCleanup(
            try SyntheticAssetGenerator.createJPEG(
                width: 4000,
                height: 3000,
                color: CGColor(srgbRed: 0.1, green: 0.7, blue: 0.4, alpha: 1.0),
                hasExif: true
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "jpg"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .medium,
            destinationURL: destinationURL
        )

        XCTAssertEqual(result.format, .jpeg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertGreaterThan(result.originalSize, 0)
        XCTAssertGreaterThan(result.compressedSize, 0)

        // Read output dimensions to verify proper scaling factor (~0.87)
        guard let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil) else {
            XCTFail("Failed to create CGImageSource from scaled JPEG")
            return
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read image properties from scaled JPEG")
            return
        }

        let scaledWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let scaledHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        XCTAssertLessThan(scaledWidth, 4000, "Scaled width should be less than original 4000")
        XCTAssertLessThan(scaledHeight, 3000, "Scaled height should be less than original 3000")
        XCTAssertGreaterThan(scaledWidth, 2500, "Scaled width should be reasonable (~3480)")
    }

    // MARK: - 4. Ultra-Short Video Processing Boundary

    /// Verifies that an ultra-short video (0.1 second / ~3 frames) can be transcoded/compressed
    /// without failing CMTime calculations, duration rounding errors, or empty track issues.
    func testUltraShortSubSecondVideoProcessingBoundary() async throws {
        let sourceURL = trackForCleanup(
            try await SyntheticAssetGenerator.createVideo(
                durationSeconds: 0.1,
                fps: 30,
                resolution: CGSize(width: 320, height: 240),
                hasAudio: true,
                isHDR: false
            )
        )
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destinationURL
        )

        // Monitor stream to ensure it emits progress without hanging
        var receivedProgress = false
        let streamConsumer = Task {
            for await progress in stream {
                if progress.fractionCompleted >= 0.0 {
                    receivedProgress = true
                }
            }
        }

        let result = try await task.value
        await streamConsumer.value

        XCTAssertTrue(receivedProgress, "Progress stream should have yielded updates")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertGreaterThan(result.processedSize, 0)
        XCTAssertGreaterThan(result.duration, 0.0, "Result duration should be positive")

        // Inspect output asset to verify readable tracks
        let asset = AVURLAsset(url: destinationURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "Output video should have at least one video track")
    }

    // MARK: - 5. Zero-Byte File Handling Boundaries

    /// Verifies that passing a 0-byte file to the photo compressor throws an error rather than
    /// corrupting the destination or causing an unhandled fatal error.
    func testZeroByteImageFileHandlingBoundary() async throws {
        let zeroByteURL = trackForCleanup(try SyntheticAssetGenerator.createZeroByteFile(extension: "jpg"))
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "jpg"))

        let compressor: PhotoCompressorProtocol = PhotoCompressorService()

        do {
            _ = try await compressor.compressPhoto(
                at: zeroByteURL,
                strength: .medium,
                destinationURL: destinationURL
            )
            XCTFail("Expected compression of 0-byte image file to throw an error, but it succeeded")
        } catch {
            // Error properly thrown
            XCTAssertNotNil(error)
        }

        // Verify destination file was not left in an unhandled state
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            XCTAssertEqual(size, 0, "Destination file, if created, should have 0 bytes or be removed")
        }
    }

    /// Verifies that passing a 0-byte file to the video processor fails gracefully,
    /// terminates the progress stream, and reports an error via the Task.
    func testZeroByteVideoFileHandlingBoundary() async throws {
        let zeroByteURL = trackForCleanup(try SyntheticAssetGenerator.createZeroByteFile(extension: "mp4"))
        let destinationURL = trackForCleanup(tempFileManager.createTempFileURL(extension: "mp4"))

        let processor: VideoProcessorProtocol = VideoProcessorService()
        let (stream, task) = processor.processVideo(
            at: zeroByteURL,
            mode: .improveCompatibility,
            strength: .low,
            destinationURL: destinationURL
        )

        // Progress stream should safely terminate
        let streamConsumer = Task {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        do {
            _ = try await task.value
            XCTFail("Expected video processing of 0-byte file to throw an error, but it succeeded")
        } catch {
            // Task properly threw error
            XCTAssertNotNil(error)
        }

        _ = await streamConsumer.value
    }

    /// Verifies that PhotoCompressionResult and VideoProcessingResult handle 0-byte originalSize
    /// safely without division by zero, NaN, or infinite percentages.
    func testZeroByteOriginalSizeDeltaMathBoundary() {
        let photoResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/empty.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/out.jpg"),
            originalSize: 0,
            compressedSize: 500,
            format: .jpeg
        )

        XCTAssertEqual(photoResult.byteDelta, -500)
        XCTAssertEqual(photoResult.reductionPercentage, 0.0, "0-byte original size must return 0.0% reduction")
        XCTAssertTrue(photoResult.isSizeIncreased)

        let videoResult = VideoProcessingResult(
            originalURL: URL(fileURLWithPath: "/tmp/empty.mp4"),
            processedURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            originalSize: 0,
            processedSize: 1000,
            duration: 0.0
        )

        XCTAssertEqual(videoResult.byteDelta, -1000)
        XCTAssertEqual(videoResult.reductionPercentage, 0.0, "0-byte original size must return 0.0% reduction")
        XCTAssertTrue(videoResult.isSizeIncreased)

        let historyItem = CompressionHistoryItem(
            fileName: "empty.jpg",
            mediaType: "photo",
            sourceFormat: "JPEG",
            targetFormat: "JPEG",
            originalByteSize: 0,
            compressedByteSize: 200,
            compressionStrength: .high
        )

        XCTAssertEqual(historyItem.byteDelta, -200)
        XCTAssertEqual(historyItem.reductionPercentage, 0.0)
        XCTAssertTrue(historyItem.isSizeIncreased)
    }
}
