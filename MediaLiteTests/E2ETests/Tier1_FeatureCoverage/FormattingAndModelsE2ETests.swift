//
//  FormattingAndModelsE2ETests.swift
//  MediaLiteTests
//
//  Tier 1 Feature Coverage E2E Tests: Formatters, Math & Core Models.
//  Covers byte formatting, reduction ratio math (positive reduction, 0% delta,
//  size increase expansion), duration & savings formatting, and Core Model
//  Codable, Sendable, and Equatable properties.
//

import XCTest
import UniformTypeIdentifiers
@testable import MediaLite

final class FormattingAndModelsE2ETests: XCTestCase {

    // MARK: - 1. Byte Formatting

    func testByteFormattingAcrossAllScalesAndNegativeValues() {
        // Zero bytes
        let zeroStr = Formatters.formatBytes(0)
        XCTAssertFalse(zeroStr.isEmpty, "Zero bytes must produce a valid formatted string")

        // Byte scale
        let bytesStr = Formatters.formatBytes(512)
        XCTAssertTrue(bytesStr.contains("512"), "Expected byte string to contain 512, got \(bytesStr)")

        // Kilobyte scale (1024 B = 1 KB)
        let kbStr = Formatters.formatBytes(1_024)
        XCTAssertTrue(kbStr.contains("1") && (kbStr.contains("KB") || kbStr.contains("kB")), "Expected 1 KB, got \(kbStr)")

        // Megabyte scale (10 * 1024 * 1024 B = 10 MB)
        let mbStr = Formatters.formatBytes(10_485_760)
        XCTAssertTrue(mbStr.contains("10") && mbStr.contains("MB"), "Expected 10 MB, got \(mbStr)")

        // Gigabyte scale (2 * 1024 * 1024 * 1024 B = 2 GB)
        let gbStr = Formatters.formatBytes(2_147_483_648)
        XCTAssertTrue(gbStr.contains("2") && gbStr.contains("GB"), "Expected 2 GB, got \(gbStr)")

        // Negative values (e.g. byte increase / penalty)
        let negStr = Formatters.formatBytes(-1_048_576)
        XCTAssertTrue(negStr.hasPrefix("-"), "Negative byte count must be prefixed with '-', got \(negStr)")
        XCTAssertTrue(negStr.contains("MB") || negStr.contains("1"), "Expected -1 MB, got \(negStr)")

        // Boundary case: Int64.min should not crash due to arithmetic overflow
        let minStr = Formatters.formatBytes(Int64.min)
        XCTAssertTrue(minStr.hasPrefix("-"), "Int64.min must be prefixed with '-'")
    }

    // MARK: - 2. Reduction Ratio Math: Positive, Zero Delta, Size Increase

    func testReductionRatioMathPositiveReductionZeroDeltaAndSizeIncrease() {
        // Case A: Positive Reduction (10 MB -> 2.5 MB = 75% savings)
        let posResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/orig.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/comp.jpg"),
            originalSize: 10_000_000,
            compressedSize: 2_500_000,
            format: .jpeg
        )
        XCTAssertEqual(posResult.byteDelta, 7_500_000)
        XCTAssertEqual(posResult.reductionPercentage, 75.0, accuracy: 0.001)
        XCTAssertFalse(posResult.isSizeIncreased)

        let posFormatted = Formatters.formatPercentage(
            reductionPercentage: posResult.reductionPercentage,
            isSizeIncreased: posResult.isSizeIncreased
        )
        XCTAssertEqual(posFormatted, "-75.0%")

        // Case B: Zero Delta (Identical file sizes, 0% change)
        let zeroResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/orig.png"),
            compressedURL: URL(fileURLWithPath: "/tmp/comp.png"),
            originalSize: 4_096,
            compressedSize: 4_096,
            format: .png
        )
        XCTAssertEqual(zeroResult.byteDelta, 0)
        XCTAssertEqual(zeroResult.reductionPercentage, 0.0, accuracy: 0.001)
        XCTAssertFalse(zeroResult.isSizeIncreased)

        let zeroFormatted = Formatters.formatPercentage(
            reductionPercentage: zeroResult.reductionPercentage,
            isSizeIncreased: zeroResult.isSizeIncreased
        )
        XCTAssertEqual(zeroFormatted, "0.0%")

        // Case C: Size Increase Expansion (1 MB -> 1.3 MB = 30% increase)
        let expResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/orig.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/bloated.jpg"),
            originalSize: 1_000_000,
            compressedSize: 1_300_000,
            format: .jpeg
        )
        XCTAssertEqual(expResult.byteDelta, -300_000)
        XCTAssertEqual(expResult.reductionPercentage, -30.0, accuracy: 0.001)
        XCTAssertTrue(expResult.isSizeIncreased)

        let expFormatted = Formatters.formatPercentage(
            reductionPercentage: expResult.reductionPercentage,
            isSizeIncreased: expResult.isSizeIncreased
        )
        XCTAssertEqual(expFormatted, "+30.0%")

        // Case D: Division by Zero Safety Guard
        let zeroByteResult = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/empty.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/empty_out.jpg"),
            originalSize: 0,
            compressedSize: 0,
            format: .jpeg
        )
        XCTAssertEqual(zeroByteResult.reductionPercentage, 0.0, "Must not divide by zero")
        XCTAssertFalse(zeroByteResult.reductionPercentage.isNaN)
        XCTAssertFalse(zeroByteResult.reductionPercentage.isInfinite)
    }

    // MARK: - 3. Duration Formatting

    func testDurationFormattingShortAndLongMedia() {
        // Zero seconds
        XCTAssertEqual(Formatters.formatDuration(0), "00:00")

        // Sub-minute seconds
        XCTAssertEqual(Formatters.formatDuration(45), "00:45")

        // Minutes and seconds (2m 5s = 125s)
        XCTAssertEqual(Formatters.formatDuration(125), "02:05")

        // Over one hour (1h 1m 1s = 3661s)
        XCTAssertEqual(Formatters.formatDuration(3661), "01:01:01")

        // Defensive guards for negative, NaN, and Infinite values
        XCTAssertEqual(Formatters.formatDuration(-15), "00:00")
        XCTAssertEqual(Formatters.formatDuration(Double.nan), "00:00")
        XCTAssertEqual(Formatters.formatDuration(Double.infinity), "00:00")
    }

    // MARK: - 4. Savings Summary Formatting

    func testSavingsSummaryFormatting() {
        // Savings scenario
        let savedSummary = Formatters.formatSavingsSummary(originalSize: 10_000_000, compressedSize: 4_000_000)
        XCTAssertTrue(savedSummary.contains("Saved"), "Must indicate savings")
        XCTAssertTrue(savedSummary.contains("60.0%"), "Must display correct reduction percentage")

        // Size expansion scenario
        let increasedSummary = Formatters.formatSavingsSummary(originalSize: 4_000_000, compressedSize: 5_000_000)
        XCTAssertTrue(increasedSummary.contains("Increased by"), "Must indicate size increase")
        XCTAssertTrue(increasedSummary.contains("+25.0%"), "Must display correct increase percentage")

        // Equal size scenario
        let equalSummary = Formatters.formatSavingsSummary(originalSize: 5_000, compressedSize: 5_000)
        XCTAssertEqual(equalSummary, "No size change")
    }

    // MARK: - 5. Core Model Codable & Equatable Properties

    func testCoreModelCodableRoundTripAndEquatable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // 1. CompressionHistoryItem
        let historyItem = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1700000000),
            fileName: "video_clip.mov",
            mediaType: "video",
            sourceFormat: "mov",
            targetFormat: "mp4",
            originalByteSize: 100_000_000,
            compressedByteSize: 30_000_000,
            compressionStrength: .high,
            durationSeconds: 15.2,
            isSavedToLibrary: true
        )
        let historyData = try encoder.encode(historyItem)
        let decodedHistoryItem = try decoder.decode(CompressionHistoryItem.self, from: historyData)
        XCTAssertEqual(decodedHistoryItem, historyItem, "Decoded history item must be identical")
        XCTAssertEqual(decodedHistoryItem.byteDelta, 70_000_000)
        XCTAssertEqual(decodedHistoryItem.reductionPercentage, 70.0, accuracy: 0.001)

        // 2. AppSettings
        var customSettings = AppSettings()
        customSettings.defaultCompressionStrength = .low
        customSettings.defaultVideoMode = .compressAndConvert
        customSettings.autoSaveToLibrary = true
        customSettings.maxCacheAgeDays = 30
        let settingsData = try encoder.encode(customSettings)
        let decodedSettings = try decoder.decode(AppSettings.self, from: settingsData)
        XCTAssertEqual(decodedSettings, customSettings)

        // 3. CompressionStrength Raw Values and Codable
        for strength in CompressionStrength.allCases {
            let data = try encoder.encode(strength)
            let decoded = try decoder.decode(CompressionStrength.self, from: data)
            XCTAssertEqual(decoded, strength)
        }

        // 4. VideoProcessingMode Raw Values and Codable
        for mode in VideoProcessingMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(VideoProcessingMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    // MARK: - 6. MediaItem Properties and State Transitions

    func testMediaItemPropertiesAndProcessingStateTransitions() {
        // Photo Item
        let photoItem = MediaItem(
            format: .jpeg,
            byteSize: 2_048_000
        )
        XCTAssertTrue(photoItem.isPhoto)
        XCTAssertFalse(photoItem.isVideo)
        XCTAssertTrue(photoItem.suggestedFileName.hasSuffix(".jpeg") || photoItem.suggestedFileName.hasSuffix(".jpg"))

        // Video Item
        let videoItem = MediaItem(
            format: .mpeg4Movie,
            duration: 10.0,
            byteSize: 45_000_000
        )
        XCTAssertTrue(videoItem.isVideo)
        XCTAssertFalse(videoItem.isPhoto)
        XCTAssertTrue(videoItem.suggestedFileName.hasSuffix(".mp4"))

        // ProcessingState Transitions
        let states: [MediaItem.ProcessingState] = [
            .idle, .queued, .processing, .completed, .failed, .cancelled
        ]
        for state in states {
            var item = photoItem
            item.state = state
            XCTAssertEqual(item.state, state)
        }
    }
}
