//
//  PhotoCompressionE2ETests.swift
//  MediaLiteTests
//
//  Tier 1 Feature Coverage E2E Tests: Photo Compression Engine.
//  Covers JPEG, HEIC, PNG compression at LOW/MEDIUM/HIGH strengths,
//  EXIF/metadata/orientation retention, alpha channel preservation,
//  and byte reduction & delta calculations.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaLite

final class PhotoCompressionE2ETests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var compressor: PhotoCompressorProtocol!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        compressor = PhotoCompressorService()
    }

    override func tearDown() {
        SyntheticAssetGenerator.cleanup(urls: trackedURLs)
        trackedURLs.removeAll()
        try? TempFileManager.shared.purgeAllTempFiles()
        compressor = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func trackURL(_ url: URL) -> URL {
        trackedURLs.append(url)
        return url
    }

    // MARK: - 1. JPEG Compression Across Strengths

    func testJPEGCompressionAtLowMediumHighStrengths() async throws {
        // 1. Synthesize high-fidelity test JPEG with high-contrast lines and EXIF metadata
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(
            width: 400,
            height: 400,
            color: CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1.0),
            hasExif: true
        ))

        let originalAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let originalByteSize = (originalAttributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(originalByteSize, 0, "Source JPEG must have non-zero size")

        var previousCompressedSize = originalByteSize

        // Test LOW, MEDIUM, and HIGH compression strengths sequentially
        let strengths: [CompressionStrength] = [.low, .medium, .high]
        for strength in strengths {
            let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "jpg"))

            let result = try await compressor.compressPhoto(
                at: sourceURL,
                strength: strength,
                destinationURL: destURL
            )

            // Verify result contract properties
            XCTAssertEqual(result.originalURL, sourceURL)
            XCTAssertEqual(result.compressedURL, destURL)
            XCTAssertEqual(result.originalSize, originalByteSize)
            XCTAssertGreaterThan(result.compressedSize, 0, "Compressed JPEG must have non-zero size")
            XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "Compressed file must exist on disk")

            // Verify genuine byte reduction
            XCTAssertLessThan(
                result.compressedSize,
                originalByteSize,
                "Compression at \(strength.rawValue) must reduce file size"
            )
            XCTAssertEqual(result.byteDelta, originalByteSize - result.compressedSize)
            XCTAssertGreaterThan(result.reductionPercentage, 0.0)
            XCTAssertFalse(result.isSizeIncreased)

            // Verify scaling hierarchy: higher compression strength should yield smaller or equal file size
            XCTAssertLessThanOrEqual(
                result.compressedSize,
                previousCompressedSize,
                "Strength \(strength.rawValue) should yield smaller or equal size than previous level"
            )
            previousCompressedSize = result.compressedSize

            // Verify output file is a valid, readable JPEG container
            guard let imageSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
                XCTFail("Failed to create CGImageSource from compressed JPEG at \(destURL)")
                continue
            }
            let uti = CGImageSourceGetType(imageSource)
            XCTAssertEqual(uti, UTType.jpeg.identifier as CFString, "Output must be valid JPEG format")
        }
    }

    // MARK: - 2. HEIC Compression & Format Preservation

    func testHEICCompressionPreservesFormatAndReducesSize() async throws {
        // Synthesize valid HEIC container with standard orientation
        let sourceURL = trackURL(try SyntheticAssetGenerator.createHEIC(
            width: 320,
            height: 320,
            orientation: .up
        ))

        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(sourceSize, 0)

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "heic"))

        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .medium,
            destinationURL: destURL
        )

        XCTAssertEqual(result.originalSize, sourceSize)
        XCTAssertGreaterThan(result.compressedSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertFalse(result.isSizeIncreased)
        XCTAssertGreaterThan(result.reductionPercentage, 0.0)

        // Verify output is genuinely retained as HEIC (requirement: HEIC remains HEIC)
        guard let destSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Failed to create CGImageSource for compressed HEIC")
            return
        }
        let outputType = CGImageSourceGetType(destSource)
        XCTAssertEqual(outputType, UTType.heic.identifier as CFString, "HEIC source must output HEIC format")
    }

    // MARK: - 3. PNG Dimension Scaling

    func testPNGCompressionDownsamplesAndPreservesFormat() async throws {
        let initialWidth = 400
        let initialHeight = 400
        let sourceURL = trackURL(try SyntheticAssetGenerator.createPNG(
            width: initialWidth,
            height: initialHeight,
            hasAlpha: false
        ))

        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(sourceSize, 0)

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "png"))

        // HIGH strength scales dimensions down by factor 0.74 (400 * 0.74 ≈ 296)
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .high,
            destinationURL: destURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertLessThan(result.compressedSize, sourceSize, "Downscaled PNG must be smaller than source")

        guard let destSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Failed to read compressed PNG source")
            return
        }
        XCTAssertEqual(CGImageSourceGetType(destSource), UTType.png.identifier as CFString)

        guard let properties = CGImageSourceCopyPropertiesAtIndex(destSource, 0, nil) as? [CFString: Any] else {
            XCTFail("Missing properties in compressed PNG")
            return
        }

        let compressedWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let compressedHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        XCTAssertLessThanOrEqual(compressedWidth, Int(Double(initialWidth) * 0.85), "Width must be downscaled")
        XCTAssertLessThanOrEqual(compressedHeight, Int(Double(initialHeight) * 0.85), "Height must be downscaled")
    }

    // MARK: - 4. EXIF & Metadata Retention

    func testEXIFAndMetadataRetentionAfterCompression() async throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(
            width: 300,
            height: 300,
            color: CGColor(srgbRed: 0.1, green: 0.4, blue: 0.8, alpha: 1.0),
            hasExif: true
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "jpg"))

        _ = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .low,
            destinationURL: destURL
        )

        guard let destSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Failed to open compressed JPEG for EXIF check")
            return
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(destSource, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to extract image properties dictionary")
            return
        }

        // Verify TIFF metadata retention (Make, Model, Software)
        let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNotNil(tiffDict, "Compressed image must retain TIFF metadata dictionary")
        if let tiff = tiffDict {
            let make = tiff[kCGImagePropertyTIFFMake] as? String
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            XCTAssertEqual(make, "Apple", "TIFF Make must be preserved across compression")
            XCTAssertEqual(model, "iPhone 15 Pro", "TIFF Model must be preserved across compression")
        }

        // Verify EXIF metadata retention
        let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNotNil(exifDict, "Compressed image must retain EXIF metadata dictionary")
        if let exif = exifDict {
            let dateTime = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            XCTAssertEqual(dateTime, "2026:01:01 12:00:00", "Original timestamp must be retained in EXIF")
        }
    }

    // MARK: - 5. Orientation Preservation

    func testOrientationPreservationAcrossHEICCompression() async throws {
        // Create HEIC with right orientation (.right = 6 in TIFF orientation convention)
        let targetOrientation = CGImagePropertyOrientation.right
        let sourceURL = trackURL(try SyntheticAssetGenerator.createHEIC(
            width: 300,
            height: 200,
            orientation: targetOrientation
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "heic"))

        _ = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .medium,
            destinationURL: destURL
        )

        guard let destSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Failed to open compressed HEIC")
            return
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(destSource, 0, nil) as? [CFString: Any] else {
            XCTFail("Properties missing in compressed HEIC")
            return
        }

        // Orientation must be synchronized: either orientation tag 6 is preserved,
        // or pixels are normalized upright with orientation 1 (upright).
        let orientationTag = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
            ?? ((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.uint32Value

        XCTAssertNotNil(orientationTag, "Image must contain valid orientation metadata")
        if let tag = orientationTag {
            XCTAssertTrue(
                tag == targetOrientation.rawValue || tag == CGImagePropertyOrientation.up.rawValue,
                "Orientation tag must be preserved (\(targetOrientation.rawValue)) or normalized to upright (1). Got: \(tag)"
            )
        }
    }

    // MARK: - 6. Alpha Channel Preservation

    func testAlphaChannelPreservationInPNGCompression() async throws {
        // Synthesize PNG with transparent regions and semi-transparent alpha shapes
        let sourceURL = trackURL(try SyntheticAssetGenerator.createPNG(
            width: 200,
            height: 200,
            hasAlpha: true
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "png"))

        _ = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .medium,
            destinationURL: destURL
        )

        guard let destSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Failed to open compressed PNG")
            return
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(destSource, 0, nil) else {
            XCTFail("Failed to render CGImage from compressed PNG")
            return
        }

        // Verify alpha channel info is preserved (not stripped or flattened into opaque RGB)
        let alphaInfo = cgImage.alphaInfo
        let hasAlphaChannel = (
            alphaInfo == .premultipliedLast ||
            alphaInfo == .premultipliedFirst ||
            alphaInfo == .last ||
            alphaInfo == .first
        )
        XCTAssertTrue(hasAlphaChannel, "Compressed PNG must maintain its alpha channel (got \(alphaInfo.rawValue))")
    }

    // MARK: - 7. Accurate Byte Delta & Math Verification

    func testAccurateByteDeltaAndReductionCalculations() async throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(
            width: 350,
            height: 350,
            color: CGColor(srgbRed: 0.7, green: 0.3, blue: 0.1, alpha: 1.0),
            hasExif: false
        ))

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "jpg"))

        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .high,
            destinationURL: destURL
        )

        // Delta = original - compressed
        XCTAssertEqual(result.byteDelta, result.originalSize - result.compressedSize)

        // Reduction % = (byteDelta / originalSize) * 100.0
        let expectedPercentage = (Double(result.byteDelta) / Double(result.originalSize)) * 100.0
        XCTAssertEqual(result.reductionPercentage, expectedPercentage, accuracy: 0.001)

        // Verify Formatter string matches mathematical result
        let formattedStr = Formatters.formatPercentage(
            reductionPercentage: result.reductionPercentage,
            isSizeIncreased: result.isSizeIncreased
        )
        XCTAssertTrue(formattedStr.hasPrefix("-"), "Savings percentage string must start with '-'")
    }

    // MARK: - 8. Multi-Format Batch Verification

    func testBatchMultiFormatPhotoCompression() async throws {
        let jpegURL = trackURL(try SyntheticAssetGenerator.createJPEG(width: 250, height: 250))
        let heicURL = trackURL(try SyntheticAssetGenerator.createHEIC(width: 250, height: 250))
        let pngURL = trackURL(try SyntheticAssetGenerator.createPNG(width: 250, height: 250, hasAlpha: true))

        let batchSources = [jpegURL, heicURL, pngURL]
        var batchResults: [PhotoCompressionResult] = []

        for source in batchSources {
            let ext = source.pathExtension
            let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: ext))
            let res = try await compressor.compressPhoto(
                at: source,
                strength: .medium,
                destinationURL: destURL
            )
            batchResults.append(res)
        }

        XCTAssertEqual(batchResults.count, 3)

        // Verify all 3 produced unique destination files
        let uniqueDestinations = Set(batchResults.map { $0.compressedURL })
        XCTAssertEqual(uniqueDestinations.count, 3, "Each item in batch must have unique output URL")

        // Verify all 3 completed with positive reductions
        for res in batchResults {
            XCTAssertGreaterThan(res.originalSize, 0)
            XCTAssertGreaterThan(res.compressedSize, 0)
            XCTAssertFalse(res.isSizeIncreased)
        }
    }
}
