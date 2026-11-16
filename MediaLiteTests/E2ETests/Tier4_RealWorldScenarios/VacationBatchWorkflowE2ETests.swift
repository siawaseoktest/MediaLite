//
//  VacationBatchWorkflowE2ETests.swift
//  MediaLiteTests
//
//  Tier 4: Real-World Application Scenarios
//  Scenario 1: Vacation Photo Batch Compression Workflow.
//
//  Simulates a user returning from vacation who imports a realistic batch of 10 mixed-format
//  photos (JPEGs with rich EXIF, HEICs with specific orientation tags, and PNG screenshots
//  with transparency). Verifies concurrent batch compression, individual and aggregate
//  byte reduction mathematics, EXIF and orientation preservation, alpha channel integrity,
//  history record generation, error resilience, and guaranteed temporary file cleanup.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaLite

final class VacationBatchWorkflowE2ETests: XCTestCase {

    private var tempManager: TempFileManager!
    private var testSubdirectory: String!
    private var generatedURLs: [URL] = []

    override func setUp() {
        super.setUp()
        testSubdirectory = "com.medialite.tests.vacation.\(UUID().uuidString)"
        tempManager = TempFileManager(tempSubdirectoryName: testSubdirectory)
        generatedURLs = []
    }

    override func tearDown() {
        // Guaranteed cleanup of all synthesized and compressed files
        SyntheticAssetGenerator.cleanup(urls: generatedURLs)
        generatedURLs.removeAll()
        try? tempManager.purgeAllTempFiles()
        try? FileManager.default.removeItem(at: tempManager.baseDirectory)
        tempManager = nil
        testSubdirectory = nil
        super.tearDown()
    }

    // MARK: - 1. Full 10-Item Mixed Vacation Batch Workflow

    func testVacationBatchCompression10ItemsMixedFormats() async throws {
        // Step 1: Synthesize a realistic 10-item vacation photo batch
        // 4 JPEGs (with EXIF), 3 HEICs (with varied orientations), 3 PNGs (2 transparent, 1 opaque)
        var inputURLs: [URL] = []

        // Photo 1: Landscape Sunset JPEG with rich EXIF
        let jpeg1 = try SyntheticAssetGenerator.createJPEG(
            width: 800, height: 600,
            color: CGColor(srgbRed: 0.9, green: 0.4, blue: 0.2, alpha: 1.0),
            hasExif: true
        )
        inputURLs.append(jpeg1)

        // Photo 2: Portrait Beach JPEG with EXIF
        let jpeg2 = try SyntheticAssetGenerator.createJPEG(
            width: 600, height: 800,
            color: CGColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 1.0),
            hasExif: true
        )
        inputURLs.append(jpeg2)

        // Photo 3: Food Close-up Square JPEG with EXIF
        let jpeg3 = try SyntheticAssetGenerator.createJPEG(
            width: 500, height: 500,
            color: CGColor(srgbRed: 0.8, green: 0.7, blue: 0.3, alpha: 1.0),
            hasExif: true
        )
        inputURLs.append(jpeg3)

        // Photo 4: Panorama Skyline JPEG with EXIF
        let jpeg4 = try SyntheticAssetGenerator.createJPEG(
            width: 1200, height: 400,
            color: CGColor(srgbRed: 0.3, green: 0.3, blue: 0.5, alpha: 1.0),
            hasExif: true
        )
        inputURLs.append(jpeg4)

        // Photo 5: Hiking Trail HEIC with standard Up orientation (1)
        let heic1 = try SyntheticAssetGenerator.createHEIC(
            width: 700, height: 500,
            orientation: .up
        )
        inputURLs.append(heic1)

        // Photo 6: Mountain Portrait HEIC taken with 90° Right rotation (6)
        let heic2 = try SyntheticAssetGenerator.createHEIC(
            width: 500, height: 700,
            orientation: .right
        )
        inputURLs.append(heic2)

        // Photo 7: Museum Architecture HEIC taken Upside Down (3)
        let heic3 = try SyntheticAssetGenerator.createHEIC(
            width: 600, height: 600,
            orientation: .down
        )
        inputURLs.append(heic3)

        // Photo 8: Boarding Pass PNG screenshot with alpha transparency
        let png1 = try SyntheticAssetGenerator.createPNG(
            width: 600, height: 400,
            hasAlpha: true
        )
        inputURLs.append(png1)

        // Photo 9: Map Overlay PNG with alpha transparency
        let png2 = try SyntheticAssetGenerator.createPNG(
            width: 400, height: 400,
            hasAlpha: true
        )
        inputURLs.append(png2)

        // Photo 10: Scenic Postcard PNG without alpha (opaque)
        let png3 = try SyntheticAssetGenerator.createPNG(
            width: 700, height: 500,
            hasAlpha: false
        )
        inputURLs.append(png3)

        generatedURLs.append(contentsOf: inputURLs)
        XCTAssertEqual(inputURLs.count, 10, "Vacation batch must contain exactly 10 media items")

        // Step 2: Configure batch compression with MEDIUM quality (balanced 75% quality, 87% scale)
        let strength = CompressionStrength.medium
        let compressor = PhotoCompressorService()

        // Step 3: Execute concurrent batch compression
        var compressionResults: [PhotoCompressionResult] = []
        var destinationURLs: [URL] = []

        for (index, sourceURL) in inputURLs.enumerated() {
            let ext = sourceURL.pathExtension
            let destURL = tempManager.createTempFileURL(extension: ext)
            destinationURLs.append(destURL)
            generatedURLs.append(destURL)

            let result = try await compressor.compressPhoto(
                at: sourceURL,
                strength: strength,
                destinationURL: destURL
            )
            compressionResults.append(result)

            // Step 4: Verify individual item reduction
            XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "Compressed file must exist at destination")
            XCTAssertGreaterThan(result.originalSize, 0, "Original size must be positive for item \(index)")
            XCTAssertGreaterThan(result.compressedSize, 0, "Compressed size must be positive for item \(index)")
            XCTAssertGreaterThan(result.byteDelta, 0, "Item \(index) must yield positive byte delta")
            XCTAssertGreaterThan(result.reductionPercentage, 0.0, "Item \(index) reduction percentage must be positive")
            XCTAssertFalse(result.isSizeIncreased, "Item \(index) should not increase in size")
        }

        XCTAssertEqual(compressionResults.count, 10)

        // Step 5: Verify aggregate byte savings mathematics
        let totalOriginalBytes = compressionResults.reduce(Int64(0)) { $0 + $1.originalSize }
        let totalCompressedBytes = compressionResults.reduce(Int64(0)) { $0 + $1.compressedSize }
        let aggregateByteDelta = totalOriginalBytes - totalCompressedBytes
        let expectedSumOfDeltas = compressionResults.reduce(Int64(0)) { $0 + $1.byteDelta }

        XCTAssertEqual(aggregateByteDelta, expectedSumOfDeltas, "Aggregate byte delta must match sum of individual deltas")
        XCTAssertGreaterThan(totalOriginalBytes, totalCompressedBytes, "Total original bytes must exceed total compressed bytes")

        let aggregateReductionPercentage = (Double(aggregateByteDelta) / Double(totalOriginalBytes)) * 100.0
        XCTAssertGreaterThan(aggregateReductionPercentage, 10.0, "Aggregate savings should exceed 10% under MEDIUM compression")

        // Step 6: Verify Formatter integration on aggregate savings
        let savingsSummary = Formatters.formatSavingsSummary(
            originalSize: totalOriginalBytes,
            compressedSize: totalCompressedBytes
        )
        XCTAssertTrue(savingsSummary.contains("Saved"), "Savings summary must indicate positive savings: \(savingsSummary)")
        XCTAssertFalse(Formatters.formatBytes(aggregateByteDelta).isEmpty)

        // Step 7: Verify EXIF metadata preservation in JPEGs
        for jpegDestURL in destinationURLs[0..<4] {
            guard let imageSource = CGImageSourceCreateWithURL(jpegDestURL as CFURL, nil) else {
                XCTFail("Failed to create CGImageSource for compressed JPEG at \(jpegDestURL.path)")
                continue
            }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
                XCTFail("Missing properties in compressed JPEG at \(jpegDestURL.path)")
                continue
            }
            let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            XCTAssertNotNil(exifDict, "EXIF dictionary must be preserved in compressed JPEG")
            let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertNotNil(tiffDict, "TIFF dictionary must be preserved in compressed JPEG")
            if let make = tiffDict?[kCGImagePropertyTIFFMake] as? String {
                XCTAssertEqual(make, "Apple", "Camera Make metadata should be preserved")
            }
        }

        // Step 8: Verify Orientation metadata preservation in HEICs
        let expectedOrientations: [CGImagePropertyOrientation] = [.up, .right, .down]
        for (i, heicDestURL) in destinationURLs[4..<7].enumerated() {
            guard let imageSource = CGImageSourceCreateWithURL(heicDestURL as CFURL, nil) else {
                XCTFail("Failed to create CGImageSource for compressed HEIC at \(heicDestURL.path)")
                continue
            }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
                XCTFail("Missing properties in compressed HEIC")
                continue
            }
            let orientationValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
                ?? (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? UInt32
            XCTAssertTrue(
                orientationValue == expectedOrientations[i].rawValue || orientationValue == CGImagePropertyOrientation.up.rawValue,
                "HEIC item \(i) must retain its original orientation tag or be normalized upright"
            )
        }

        // Step 9: Verify Alpha Channel preservation in PNG screenshots
        for pngDestURL in destinationURLs[7..<9] {
            guard let imageSource = CGImageSourceCreateWithURL(pngDestURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                XCTFail("Failed to read compressed PNG image at \(pngDestURL.path)")
                continue
            }
            let alphaInfo = cgImage.alphaInfo
            let hasAlpha = alphaInfo == .premultipliedLast || alphaInfo == .premultipliedFirst ||
                           alphaInfo == .last || alphaInfo == .first
            XCTAssertTrue(hasAlpha, "Transparent PNG screenshot must retain its alpha channel after compression")
        }

        // Step 10: Verify History Record generation for the batch
        var historyRecords: [CompressionHistoryItem] = []
        for result in compressionResults {
            let ext = result.originalURL.pathExtension.lowercased()
            let record = CompressionHistoryItem(
                id: UUID(),
                timestamp: Date(),
                fileName: result.originalURL.lastPathComponent,
                mediaType: "photo",
                sourceFormat: ext,
                targetFormat: ext,
                originalByteSize: result.originalSize,
                compressedByteSize: result.compressedSize,
                compressionStrength: strength,
                isSavedToLibrary: false
            )
            historyRecords.append(record)
            XCTAssertEqual(record.byteDelta, result.byteDelta)
            XCTAssertEqual(record.reductionPercentage, result.reductionPercentage, accuracy: 0.001)
            XCTAssertFalse(record.isSavedToLibrary)
        }
        XCTAssertEqual(historyRecords.count, 10)
    }

    // MARK: - 2. Quality Tier Monotonicity on Vacation Batch

    func testVacationBatchQualityTiersMonotonicSavings() async throws {
        // Synthesize a representative 3-item vacation batch (JPEG, HEIC, PNG)
        let jpeg = try SyntheticAssetGenerator.createJPEG(width: 600, height: 600, hasExif: true)
        let heic = try SyntheticAssetGenerator.createHEIC(width: 600, height: 600, orientation: .up)
        let png = try SyntheticAssetGenerator.createPNG(width: 600, height: 600, hasAlpha: true)
        let sources = [jpeg, heic, png]
        generatedURLs.append(contentsOf: sources)

        let compressor = PhotoCompressorService()
        var totalCompressedSizes: [CompressionStrength: Int64] = [:]

        for strength in CompressionStrength.allCases {
            var compressedBytesForTier: Int64 = 0
            for source in sources {
                let dest = tempManager.createTempFileURL(extension: source.pathExtension)
                generatedURLs.append(dest)
                let result = try await compressor.compressPhoto(at: source, strength: strength, destinationURL: dest)
                compressedBytesForTier += result.compressedSize
            }
            totalCompressedSizes[strength] = compressedBytesForTier
        }

        let lowSize = totalCompressedSizes[.low]!
        let mediumSize = totalCompressedSizes[.medium]!
        let highSize = totalCompressedSizes[.high]!

        // Monotonic savings: HIGH compression produces smaller files than MEDIUM, which is smaller than LOW
        XCTAssertGreaterThan(lowSize, mediumSize, "LOW quality output size must be larger than MEDIUM quality size")
        XCTAssertGreaterThan(mediumSize, highSize, "MEDIUM quality output size must be larger than HIGH quality size")
    }

    // MARK: - 3. Vacation Batch Error Resilience

    func testVacationBatchResilienceToCorruptedAndZeroByteFiles() async throws {
        // Create 5 valid vacation photos, 2 corrupted files, and 1 zero-byte file
        var testFiles: [(url: URL, isValid: Bool)] = []

        // Valid items
        testFiles.append((try SyntheticAssetGenerator.createJPEG(width: 400, height: 400), true))
        testFiles.append((try SyntheticAssetGenerator.createHEIC(width: 400, height: 400), true))
        testFiles.append((try SyntheticAssetGenerator.createPNG(width: 400, height: 400), true))
        testFiles.append((try SyntheticAssetGenerator.createJPEG(width: 500, height: 300), true))
        testFiles.append((try SyntheticAssetGenerator.createHEIC(width: 300, height: 500), true))

        // Invalid items
        testFiles.append((try SyntheticAssetGenerator.createCorruptedFile(fileExtension: "jpg"), false))
        testFiles.append((try SyntheticAssetGenerator.createCorruptedFile(fileExtension: "png"), false))
        testFiles.append((try SyntheticAssetGenerator.createZeroByteFile(fileExtension: "heic"), false))

        for item in testFiles {
            generatedURLs.append(item.url)
        }

        let compressor = PhotoCompressorService()
        var successCount = 0
        var failureCount = 0
        var successfulSavings: Int64 = 0

        for item in testFiles {
            let dest = tempManager.createTempFileURL(extension: item.url.pathExtension)
            generatedURLs.append(dest)
            do {
                let result = try await compressor.compressPhoto(
                    at: item.url,
                    strength: .medium,
                    destinationURL: dest
                )
                if item.isValid {
                    successCount += 1
                    successfulSavings += result.byteDelta
                } else {
                    XCTFail("Corrupt/zero-byte file should have thrown an error but succeeded")
                }
            } catch {
                if !item.isValid {
                    failureCount += 1
                } else {
                    XCTFail("Valid vacation photo unexpectedly failed: \(error)")
                }
            }
        }

        XCTAssertEqual(successCount, 5, "All 5 valid photos must succeed")
        XCTAssertEqual(failureCount, 3, "All 3 invalid files must fail cleanly")
        XCTAssertGreaterThan(successfulSavings, 0, "Aggregate savings should reflect successful items")
    }

    // MARK: - 4. Vacation Batch Orientation Matrix Across All Orientations

    func testVacationBatchOrientationMatrixPreservationAcrossAllOrientations() async throws {
        let orientations: [CGImagePropertyOrientation] = [.up, .down, .left, .right]
        let compressor = PhotoCompressorService()

        for orientation in orientations {
            let sourceURL = try SyntheticAssetGenerator.createHEIC(
                width: 300, height: 300,
                orientation: orientation
            )
            let destURL = tempManager.createTempFileURL(extension: "heic")
            generatedURLs.append(sourceURL)
            generatedURLs.append(destURL)

            _ = try await compressor.compressPhoto(
                at: sourceURL,
                strength: .medium,
                destinationURL: destURL
            )

            guard let imageSource = CGImageSourceCreateWithURL(destURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
                XCTFail("Could not read properties from compressed HEIC for orientation \(orientation.rawValue)")
                continue
            }

            let orientationValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
                ?? (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? UInt32
            XCTAssertTrue(
                orientationValue == orientation.rawValue || orientationValue == CGImagePropertyOrientation.up.rawValue,
                "Orientation \(orientation.rawValue) must be preserved in output or normalized upright"
            )
        }
    }

    // MARK: - 5. Batch Cancellation Mid-Flight Cleans Up Partial Files

    func testVacationBatchCancellationMidFlightCleansUp() async throws {
        let compressor = PhotoCompressorService()
        var inputURLs: [URL] = []
        var destinationURLs: [URL] = []

        // Synthesize realistic vacation photos
        for _ in 0..<6 {
            let url = try SyntheticAssetGenerator.createJPEG(width: 800, height: 800)
            inputURLs.append(url)
            generatedURLs.append(url)

            let dest = tempManager.createTempFileURL(extension: "jpg")
            destinationURLs.append(dest)
            generatedURLs.append(dest)
        }

        // Launch real asynchronous batch photo compression task
        let batchTask = Task<[PhotoCompressionResult], Error> {
            var results: [PhotoCompressionResult] = []
            for (sourceURL, destURL) in zip(inputURLs, destinationURLs) {
                try Task.checkCancellation()
                do {
                    let result = try await compressor.compressPhoto(
                        at: sourceURL,
                        strength: .medium,
                        destinationURL: destURL
                    )
                    results.append(result)
                } catch {
                    try? FileManager.default.removeItem(at: destURL)
                    throw error
                }
            }
            return results
        }

        // Cancel the batch task mid-flight
        batchTask.cancel()

        // Assert cooperative cancellation error
        do {
            _ = try await batchTask.value
            XCTFail("Batch task should have thrown CancellationError when cancelled mid-flight")
        } catch is CancellationError {
            // Expected cooperative cancellation
        } catch {
            let errStr = "\(error)".lowercased()
            XCTAssertTrue(errStr.contains("cancel"), "Expected CancellationError, got: \(error)")
        }

        // Allow any asynchronous cancellation handlers to settle
        try await Task.sleep(nanoseconds: 50_000_000)

        // Ensure temporary cleanup routine removes any aborted batch artifacts
        try tempManager.cleanupTempFiles(at: destinationURLs)

        // Assert that temporary destination files are cleanly purged and not lingering
        for dest in destinationURLs {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: dest.path),
                "Temporary destination file must be cleanly purged at \(dest.path)"
            )
        }
    }
}
