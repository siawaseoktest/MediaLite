//
//  CompressionRatioCalculatorTests.swift
//  MediaLiteTests
//
//  Created for MediaLite Milestone 1.
//

import XCTest
import UniformTypeIdentifiers
@testable import MediaLite

final class CompressionRatioCalculatorTests: XCTestCase {
    
    // MARK: - Normal Compression Tests
    
    func testNormalPhotoCompressionCalculations() {
        let originalSize: Int64 = 10_000_000 // 10 MB
        let compressedSize: Int64 = 3_500_000 // 3.5 MB
        
        let result = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/original.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/compressed.jpg"),
            originalSize: originalSize,
            compressedSize: compressedSize,
            format: .jpeg
        )
        
        XCTAssertEqual(result.byteDelta, 6_500_000)
        XCTAssertEqual(result.reductionPercentage, 65.0, accuracy: 0.001)
        XCTAssertFalse(result.isSizeIncreased)
    }
    
    func testNormalVideoCompressionCalculations() {
        let originalSize: Int64 = 100_000_000 // 100 MB
        let processedSize: Int64 = 25_000_000  // 25 MB
        
        let result = VideoProcessingResult(
            originalURL: URL(fileURLWithPath: "/tmp/source.mov"),
            processedURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            originalSize: originalSize,
            processedSize: processedSize,
            duration: 45.0
        )
        
        XCTAssertEqual(result.byteDelta, 75_000_000)
        XCTAssertEqual(result.reductionPercentage, 75.0, accuracy: 0.001)
        XCTAssertFalse(result.isSizeIncreased)
        XCTAssertEqual(result.duration, 45.0)
    }
    
    // MARK: - Boundary Conditions: 100% and 0% Reduction
    
    func testHundredPercentReduction() {
        let originalSize: Int64 = 5_000_000
        let compressedSize: Int64 = 0
        
        let result = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/original.heic"),
            compressedURL: URL(fileURLWithPath: "/tmp/empty.heic"),
            originalSize: originalSize,
            compressedSize: compressedSize,
            format: .heic
        )
        
        XCTAssertEqual(result.byteDelta, 5_000_000)
        XCTAssertEqual(result.reductionPercentage, 100.0, accuracy: 0.001)
        XCTAssertFalse(result.isSizeIncreased)
    }
    
    func testZeroPercentReductionEqualSizes() {
        let size: Int64 = 4_096
        
        let result = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/source.png"),
            compressedURL: URL(fileURLWithPath: "/tmp/target.png"),
            originalSize: size,
            compressedSize: size,
            format: .png
        )
        
        XCTAssertEqual(result.byteDelta, 0)
        XCTAssertEqual(result.reductionPercentage, 0.0, accuracy: 0.001)
        XCTAssertFalse(result.isSizeIncreased)
    }
    
    // MARK: - Size Increase (Negative Delta) Tests
    
    func testSizeIncreaseWhenCompressedIsLarger() {
        let originalSize: Int64 = 1_000_000 // 1 MB
        let compressedSize: Int64 = 1_250_000 // 1.25 MB (25% increase)
        
        let result = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/original.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/bloated.jpg"),
            originalSize: originalSize,
            compressedSize: compressedSize,
            format: .jpeg
        )
        
        XCTAssertEqual(result.byteDelta, -250_000)
        XCTAssertEqual(result.reductionPercentage, -25.0, accuracy: 0.001)
        XCTAssertTrue(result.isSizeIncreased)
    }
    
    func testVideoSizeIncrease() {
        let originalSize: Int64 = 50_000_000
        let processedSize: Int64 = 60_000_000 // 20% increase
        
        let result = VideoProcessingResult(
            originalURL: URL(fileURLWithPath: "/tmp/orig.mp4"),
            processedURL: URL(fileURLWithPath: "/tmp/transcoded.mp4"),
            originalSize: originalSize,
            processedSize: processedSize,
            duration: 12.0
        )
        
        XCTAssertEqual(result.byteDelta, -10_000_000)
        XCTAssertEqual(result.reductionPercentage, -20.0, accuracy: 0.001)
        XCTAssertTrue(result.isSizeIncreased)
    }
    
    // MARK: - Zero-Byte & Negative Safety Tests
    
    func testZeroByteOriginalFileSafety() {
        let result = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/empty.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/empty_out.jpg"),
            originalSize: 0,
            compressedSize: 0,
            format: .jpeg
        )
        
        // Division by zero guard verification
        XCTAssertEqual(result.byteDelta, 0)
        XCTAssertEqual(result.reductionPercentage, 0.0)
        XCTAssertFalse(result.isSizeIncreased)
    }
    
    func testZeroByteOriginalWithNonZeroCompressed() {
        let result = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/empty.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/header_only.jpg"),
            originalSize: 0,
            compressedSize: 128,
            format: .jpeg
        )
        
        XCTAssertEqual(result.byteDelta, -128)
        XCTAssertEqual(result.reductionPercentage, 0.0)
        XCTAssertTrue(result.isSizeIncreased)
    }
    
    func testNegativeOriginalSizeHandledSafely() {
        let result = PhotoCompressionResult(
            originalURL: URL(fileURLWithPath: "/tmp/corrupt.jpg"),
            compressedURL: URL(fileURLWithPath: "/tmp/corrupt_out.jpg"),
            originalSize: -500,
            compressedSize: 200,
            format: .jpeg
        )
        
        XCTAssertEqual(result.byteDelta, -700)
        XCTAssertEqual(result.reductionPercentage, 0.0)
        XCTAssertTrue(result.isSizeIncreased)
    }
    
    // MARK: - CompressionHistoryItem Math Tests
    
    func testCompressionHistoryItemCalculations() {
        let historyItem = CompressionHistoryItem(
            id: UUID(),
            timestamp: Date(),
            fileName: "vacation.heic",
            mediaType: "photo",
            sourceFormat: "heic",
            targetFormat: "heic",
            originalByteSize: 8_000_000,
            compressedByteSize: 2_000_000,
            compressionStrength: .medium
        )
        
        XCTAssertEqual(historyItem.byteDelta, 6_000_000)
        XCTAssertEqual(historyItem.reductionPercentage, 75.0, accuracy: 0.001)
        XCTAssertFalse(historyItem.isSizeIncreased)
    }
    
    // MARK: - Formatter Percentage & Savings String Tests
    
    func testPercentageFormatting() {
        // Normal savings
        let savingsStr = Formatters.formatPercentage(reductionPercentage: 45.2, isSizeIncreased: false)
        XCTAssertEqual(savingsStr, "-45.2%")
        
        // Size increase
        let increaseStr = Formatters.formatPercentage(reductionPercentage: -12.5, isSizeIncreased: true)
        XCTAssertEqual(increaseStr, "+12.5%")
        
        // Zero / negligible difference
        let zeroStr = Formatters.formatPercentage(reductionPercentage: 0.0, isSizeIncreased: false)
        XCTAssertEqual(zeroStr, "0.0%")
        
        // NaN / Inf safety
        let nanStr = Formatters.formatPercentage(reductionPercentage: Double.nan, isSizeIncreased: false)
        XCTAssertEqual(nanStr, "0.0%")
    }
    
    func testSavingsSummaryFormatting() {
        let saved = Formatters.formatSavingsSummary(originalSize: 10_000_000, compressedSize: 6_000_000)
        XCTAssertTrue(saved.contains("Saved") || saved.contains("40.0%"))
        
        let increased = Formatters.formatSavingsSummary(originalSize: 5_000_000, compressedSize: 6_000_000)
        XCTAssertTrue(increased.contains("Increased") || increased.contains("+20.0%"))
        
        let equal = Formatters.formatSavingsSummary(originalSize: 1_000, compressedSize: 1_000)
        XCTAssertEqual(equal, "No size change")
    }
    
    func testTotalSavingsSummaryFormatting() {
        let saved = Formatters.formatTotalSavingsSummary(originalSize: 10_000_000, compressedSize: 6_000_000)
        XCTAssertTrue(saved.contains("合計") && saved.contains("削減") && saved.contains("40.0%"))
        
        let increased = Formatters.formatTotalSavingsSummary(originalSize: 5_000_000, compressedSize: 6_000_000)
        XCTAssertTrue(increased.contains("合計") && increased.contains("増加") && increased.contains("+20.0%"))
        
        let equal = Formatters.formatTotalSavingsSummary(originalSize: 1_000, compressedSize: 1_000)
        XCTAssertEqual(equal, "サイズ変更なし")
    }
    
    func testByteFormatting() {
        XCTAssertFalse(Formatters.formatBytes(1_048_576).isEmpty)
        XCTAssertFalse(Formatters.formatBytes(0).isEmpty)
        let negative = Formatters.formatBytes(-500_000)
        XCTAssertTrue(negative.hasPrefix("-"))
    }
    
    func testDurationFormatting() {
        XCTAssertEqual(Formatters.formatDuration(0), "00:00")
        XCTAssertEqual(Formatters.formatDuration(65), "01:05")
        XCTAssertEqual(Formatters.formatDuration(3665), "01:01:05")
        XCTAssertEqual(Formatters.formatDuration(-10), "00:00")
    }
}
