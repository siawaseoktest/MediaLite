//
//  PhotoCompressorServiceTests.swift
//  MediaLiteTests
//
//  Unit tests for PhotoCompressorService and ExifHelper.
//  Covers JPEG, HEIC, PNG compression at LOW/MEDIUM/HIGH tiers,
//  EXIF/metadata/orientation retention, alpha transparency preservation,
//  size delta calculations, and edge cases (0-byte, corruption, unwritable destination).
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaLite

final class PhotoCompressorServiceTests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var compressor: PhotoCompressorProtocol!
    private var tempFileManager: TempFileManager!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        compressor = PhotoCompressorService()
        tempFileManager = TempFileManager(tempSubdirectoryName: "com.medialite.tests.photocompressor.\(UUID().uuidString)")
    }

    override func tearDown() {
        SyntheticAssetGenerator.cleanup(urls: trackedURLs)
        trackedURLs.removeAll()
        try? tempFileManager.purgeAllTempFiles()
        try? FileManager.default.removeItem(at: tempFileManager.baseDirectory)
        tempFileManager = nil
        compressor = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    @discardableResult
    private func trackURL(_ url: URL) -> URL {
        trackedURLs.append(url)
        return url
    }

    // MARK: - 1. JPEG Compression Across Strengths

    func testJPEGCompressionAcrossAllStrengths() async throws {
        let initialWidth = 400
        let initialHeight = 400
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(
            width: initialWidth,
            height: initialHeight,
            color: CGColor(srgbRed: 0.1, green: 0.5, blue: 0.8, alpha: 1.0),
            hasExif: true
        ))

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let originalByteSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(originalByteSize, 0)

        var previousCompressedSize = originalByteSize

        let strengths: [CompressionStrength] = [.low, .medium, .high]
        for strength in strengths {
            let destURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))

            let result = try await compressor.compressPhoto(
                at: sourceURL,
                strength: strength,
                destinationURL: destURL
            )

            // Result integrity
            XCTAssertEqual(result.originalURL, sourceURL)
            XCTAssertEqual(result.compressedURL, destURL)
            XCTAssertEqual(result.originalSize, originalByteSize)
            XCTAssertGreaterThan(result.compressedSize, 0)
            XCTAssertEqual(result.format, .jpeg)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

            // Reduction math
            XCTAssertLessThan(result.compressedSize, originalByteSize)
            XCTAssertEqual(result.byteDelta, originalByteSize - result.compressedSize)
            XCTAssertGreaterThan(result.reductionPercentage, 0.0)
            XCTAssertFalse(result.isSizeIncreased)

            // Monotonic size reduction hierarchy
            XCTAssertLessThanOrEqual(
                result.compressedSize,
                previousCompressedSize,
                "Higher strength \(strength.rawValue) should produce smaller or equal size"
            )
            previousCompressedSize = result.compressedSize

            // Verify readable JPEG container
            guard let destSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
                XCTFail("Failed to read compressed JPEG")
                continue
            }
            XCTAssertEqual(CGImageSourceGetType(destSource), UTType.jpeg.identifier as CFString)

            // Verify EXIF & TIFF retention
            guard let properties = CGImageSourceCopyPropertiesAtIndex(destSource, 0, nil) as? [CFString: Any] else {
                XCTFail("Failed to extract properties from compressed JPEG")
                continue
            }
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertNotNil(tiff)
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "Apple")
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "iPhone 15 Pro")

            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            XCTAssertNotNil(exif)
            XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:01:01 12:00:00")
        }
    }

    // MARK: - 2. HEIC Compression & Format Preservation

    func testHEICCompressionPreservesFormatAndOrientation() async throws {
        let targetOrientation = CGImagePropertyOrientation.right // tag 6
        let sourceURL = trackURL(try SyntheticAssetGenerator.createHEIC(
            width: 320,
            height: 320,
            orientation: targetOrientation
        ))

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(sourceSize, 0)

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "heic"))

        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .medium,
            destinationURL: destURL
        )

        XCTAssertEqual(result.originalSize, sourceSize)
        XCTAssertGreaterThan(result.compressedSize, 0)
        XCTAssertEqual(result.format, .heic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertFalse(result.isSizeIncreased)

        // Read destination container
        guard let destSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Failed to read compressed HEIC")
            return
        }
        XCTAssertEqual(CGImageSourceGetType(destSource), UTType.heic.identifier as CFString)

        guard let properties = CGImageSourceCopyPropertiesAtIndex(destSource, 0, nil) as? [CFString: Any] else {
            XCTFail("Missing properties in compressed HEIC")
            return
        }

        // Orientation check: thumbnail transform normalizes pixels upright (1) or tag is retained
        let orientationTag = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
            ?? ((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.uint32Value
        XCTAssertNotNil(orientationTag)
        XCTAssertTrue(
            orientationTag == CGImagePropertyOrientation.up.rawValue || orientationTag == targetOrientation.rawValue,
            "Orientation tag must be normalized to upright (1) or match source"
        )
    }

    // MARK: - 3. PNG Compression & Alpha Transparency Preservation

    func testPNGCompressionScalingAndAlphaPreservation() async throws {
        let initialWidth = 300
        let initialHeight = 300
        let sourceURL = trackURL(try SyntheticAssetGenerator.createPNG(
            width: initialWidth,
            height: initialHeight,
            hasAlpha: true
        ))

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(sourceSize, 0)

        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "png"))

        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .high,
            destinationURL: destURL
        )

        XCTAssertEqual(result.format, .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertLessThan(result.compressedSize, sourceSize)

        guard let destSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Failed to open compressed PNG")
            return
        }
        XCTAssertEqual(CGImageSourceGetType(destSource), UTType.png.identifier as CFString)

        // Verify dimension downscaling
        guard let properties = CGImageSourceCopyPropertiesAtIndex(destSource, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read properties of compressed PNG")
            return
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertLessThan(width, initialWidth)
        XCTAssertLessThan(height, initialHeight)

        // Verify alpha channel is maintained
        guard let cgImage = CGImageSourceCreateImageAtIndex(destSource, 0, nil) else {
            XCTFail("Failed to render CGImage from compressed PNG")
            return
        }
        let alpha = cgImage.alphaInfo
        let hasAlpha = (
            alpha == .premultipliedLast ||
            alpha == .premultipliedFirst ||
            alpha == .last ||
            alpha == .first
        )
        XCTAssertTrue(hasAlpha, "Alpha transparency must be preserved in compressed PNG (got \(alpha.rawValue))")
    }

    // MARK: - 4. ExifHelper Deep Metadata Inspection

    func testExifHelperMetadataExtraction() throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(
            width: 250,
            height: 180,
            hasExif: true
        ))

        let metadata = try ExifHelper.extractMetadata(from: sourceURL)
        XCTAssertEqual(metadata.pixelWidth, 250)
        XCTAssertEqual(metadata.pixelHeight, 180)
        XCTAssertEqual(metadata.dimensions.width, 250)
        XCTAssertEqual(metadata.dimensions.height, 180)
        XCTAssertEqual(metadata.cameraMake, "Apple")
        XCTAssertEqual(metadata.cameraModel, "iPhone 15 Pro")
        XCTAssertEqual(metadata.captureDateString, "2026:01:01 12:00:00")
        XCTAssertNotNil(metadata.captureDate)
        XCTAssertEqual(metadata.format, .jpeg)
        XCTAssertGreaterThan(metadata.fileSize, 0)
        XCTAssertNotNil(metadata.exifDictionary)
        XCTAssertNotNil(metadata.tiffDictionary)

        // Test helper convenience methods
        let dims = ExifHelper.readDimensions(from: sourceURL)
        XCTAssertEqual(dims?.width, 250)
        XCTAssertEqual(dims?.height, 180)

        let orientation = ExifHelper.readOrientation(from: sourceURL)
        XCTAssertEqual(orientation, .up)

        let camera = ExifHelper.readCameraInfo(from: sourceURL)
        XCTAssertEqual(camera.make, "Apple")
        XCTAssertEqual(camera.model, "iPhone 15 Pro")

        let captureDate = ExifHelper.readCaptureDate(from: sourceURL)
        XCTAssertNotNil(captureDate)
    }

    func testExifHelperDateParsingAndFormatting() {
        let originalDateStr = "2026:01:01 12:00:00"
        let parsed = ExifHelper.parseExifDate(originalDateStr)
        XCTAssertNotNil(parsed)

        if let date = parsed {
            let formatted = ExifHelper.formatExifDate(date)
            XCTAssertEqual(formatted, originalDateStr)
        }

        // Invalid date string
        XCTAssertNil(ExifHelper.parseExifDate("not-a-date"))
        XCTAssertNil(ExifHelper.parseExifDate(""))
    }

    func testExifHelperExtractFromData() throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createPNG(
            width: 100,
            height: 100,
            hasAlpha: true
        ))
        let data = try Data(contentsOf: sourceURL)

        let metadata = try ExifHelper.extractMetadata(from: data)
        XCTAssertEqual(metadata.pixelWidth, 100)
        XCTAssertEqual(metadata.pixelHeight, 100)
        XCTAssertEqual(metadata.format, .png)
        XCTAssertTrue(metadata.hasAlphaChannel)
    }

    // MARK: - 5. Error & Edge Case Handling

    func testZeroByteFileHandling() async throws {
        let zeroByteURL = trackURL(try SyntheticAssetGenerator.createZeroByteFile(extension: "jpg"))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))

        do {
            _ = try await compressor.compressPhoto(
                at: zeroByteURL,
                strength: .medium,
                destinationURL: destURL
            )
            XCTFail("compressPhoto must throw for 0-byte source file")
        } catch {
            XCTAssertTrue(error is PhotoCompressionError)
            if let compressionError = error as? PhotoCompressionError {
                XCTAssertEqual(compressionError, .zeroByteFile(zeroByteURL))
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))

        // ExifHelper also rejects 0-byte file
        XCTAssertThrowsError(try ExifHelper.extractMetadata(from: zeroByteURL)) { err in
            XCTAssertTrue(err is ExifHelperError)
        }
    }

    func testCorruptedFileHandling() async throws {
        let corruptJPEG = trackURL(try SyntheticAssetGenerator.createCorruptedFile(extension: "jpg"))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))

        do {
            _ = try await compressor.compressPhoto(
                at: corruptJPEG,
                strength: .medium,
                destinationURL: destURL
            )
            XCTFail("compressPhoto must throw for corrupt file")
        } catch {
            XCTAssertTrue(error is PhotoCompressionError)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))
    }

    func testNonExistentFileHandling() async throws {
        let nonExistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).jpg")
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))

        do {
            _ = try await compressor.compressPhoto(
                at: nonExistentURL,
                strength: .low,
                destinationURL: destURL
            )
            XCTFail("compressPhoto must throw for non-existent file")
        } catch {
            if let compressionError = error as? PhotoCompressionError {
                XCTAssertEqual(compressionError, .fileNotFound(nonExistentURL))
            }
        }

        XCTAssertThrowsError(try ExifHelper.extractMetadata(from: nonExistentURL)) { err in
            if let exifError = err as? ExifHelperError {
                XCTAssertEqual(exifError, .fileNotFound(nonExistentURL))
            }
        }
    }

    func testUnwritableDestinationHandling() async throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(width: 100, height: 100))

        // Create a regular file to block subpath directory creation
        let obstacleFile = trackURL(tempFileManager.createTempFileURL(extension: "bin"))
        try Data("block".utf8).write(to: obstacleFile)

        let unwritableDest = obstacleFile
            .appendingPathComponent("subfolder")
            .appendingPathComponent("output.jpg")

        do {
            _ = try await compressor.compressPhoto(
                at: sourceURL,
                strength: .medium,
                destinationURL: unwritableDest
            )
            XCTFail("compressPhoto must throw for unwritable destination")
        } catch {
            XCTAssertTrue(error is PhotoCompressionError)
        }
    }

    // MARK: - 6. Destination Overwrite Cleanly

    func testDestinationOverwriteCleanly() async throws {
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(width: 200, height: 200))
        let destURL = trackURL(tempFileManager.createTempFileURL(extension: "jpg"))

        // Write existing dummy file at destination
        try Data("pre-existing content".utf8).write(to: destURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .low,
            destinationURL: destURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertGreaterThan(result.compressedSize, 20)

        // Confirm it is a valid JPEG and not the dummy content
        guard let source = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Overwritten destination is not a valid image")
            return
        }
        XCTAssertEqual(CGImageSourceGetType(source), UTType.jpeg.identifier as CFString)
    }

    // MARK: - 7. PhotoCompressionResult Math Verification

    func testPhotoCompressionResultMath() {
        // Normal reduction case
        let result = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/in.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/out.jpg"),
            originalSize: 1000,
            compressedSize: 400,
            format: .jpeg
        )
        XCTAssertEqual(result.byteDelta, 600)
        XCTAssertEqual(result.reductionPercentage, 60.0, accuracy: 0.001)
        XCTAssertFalse(result.isSizeIncreased)

        // Size increase case
        let increasedResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/in.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/out.jpg"),
            originalSize: 500,
            compressedSize: 800,
            format: .jpeg
        )
        XCTAssertEqual(increasedResult.byteDelta, -300)
        XCTAssertEqual(increasedResult.reductionPercentage, -60.0, accuracy: 0.001)
        XCTAssertTrue(increasedResult.isSizeIncreased)

        // Zero delta case
        let zeroDeltaResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/in.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/out.jpg"),
            originalSize: 500,
            compressedSize: 500,
            format: .jpeg
        )
        XCTAssertEqual(zeroDeltaResult.byteDelta, 0)
        XCTAssertEqual(zeroDeltaResult.reductionPercentage, 0.0, accuracy: 0.001)
        XCTAssertFalse(zeroDeltaResult.isSizeIncreased)

        // Zero byte original
        let zeroOriginalResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/in.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/out.jpg"),
            originalSize: 0,
            compressedSize: 200,
            format: .jpeg
        )
        XCTAssertEqual(zeroOriginalResult.byteDelta, -200)
        XCTAssertEqual(zeroOriginalResult.reductionPercentage, 0.0)
        XCTAssertTrue(zeroOriginalResult.isSizeIncreased)
    }

    // MARK: - 11. ExifHelper Format Detection Tests

    func testExifHelperDetectFormatFromMagicBytes() {
        // JPEG magic bytes
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        XCTAssertEqual(ExifHelper.detectFormat(from: jpegData), .jpeg)

        // PNG magic bytes
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(ExifHelper.detectFormat(from: pngData), .png)

        // HEIC magic bytes (offset 4 'ftyp', offset 8 'heic')
        var heicData = Data([0x00, 0x00, 0x00, 0x18])
        heicData.append(contentsOf: "ftypheic".utf8)
        XCTAssertEqual(ExifHelper.detectFormat(from: heicData), .heic)

        // TIFF Little Endian magic bytes
        let tiffLEData = Data([0x49, 0x49, 0x2A, 0x00])
        XCTAssertEqual(ExifHelper.detectFormat(from: tiffLEData), .tiff)

        // TIFF Big Endian magic bytes
        let tiffBEData = Data([0x4D, 0x4D, 0x00, 0x2A])
        XCTAssertEqual(ExifHelper.detectFormat(from: tiffBEData), .tiff)

        // Unknown fallback
        let unknownData = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(ExifHelper.detectFormat(from: unknownData), .jpeg)
    }

    func testExifHelperDetectFormatFromURL() {
        let jpgURL = URL(fileURLWithPath: "/tmp/sample.jpg")
        XCTAssertEqual(ExifHelper.detectFormat(from: jpgURL), .jpeg)

        let pngURL = URL(fileURLWithPath: "/tmp/sample.png")
        XCTAssertEqual(ExifHelper.detectFormat(from: pngURL), .png)

        let heicURL = URL(fileURLWithPath: "/tmp/sample.heic")
        XCTAssertEqual(ExifHelper.detectFormat(from: heicURL), .heic)
    }
}
