//
//  SyntheticAssetGeneratorTests.swift
//  MediaLiteTests
//
//  Unit tests verifying the SyntheticAssetGenerator helper suite.
//

import XCTest
import CoreGraphics
import ImageIO
import AVFoundation
@testable import MediaLite

final class SyntheticAssetGeneratorTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    // MARK: - Image Generation Tests

    func testCreateJPEGGeneratesValidFile() throws {
        let url = try SyntheticAssetGenerator.createJPEG(
            width: 120,
            height: 120,
            color: CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1.0),
            hasExif: true
        )
        defer { SyntheticAssetGenerator.cleanup(url: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fileSize, 0)
        XCTAssertEqual(url.pathExtension.lowercased(), "jpg")
    }

    func testCreatePNGWithAlphaGeneratesValidFile() throws {
        let url = try SyntheticAssetGenerator.createPNG(
            width: 100,
            height: 100,
            hasAlpha: true
        )
        defer { SyntheticAssetGenerator.cleanup(url: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fileSize, 0)
        XCTAssertEqual(url.pathExtension.lowercased(), "png")
    }

    func testCreatePNGWithoutAlphaGeneratesValidFile() throws {
        let url = try SyntheticAssetGenerator.createPNG(
            width: 80,
            height: 80,
            hasAlpha: false
        )
        defer { SyntheticAssetGenerator.cleanup(url: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fileSize, 0)
    }

    func testCreateHEICGeneratesValidFile() throws {
        let url = try SyntheticAssetGenerator.createHEIC(
            width: 100,
            height: 100,
            orientation: .right
        )
        defer { SyntheticAssetGenerator.cleanup(url: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fileSize, 0)
        XCTAssertEqual(url.pathExtension.lowercased(), "heic")
    }

    // MARK: - Video Generation Tests

    func testCreateVideoWithAudioGeneratesFile() async throws {
        let url = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: true,
            isHDR: false,
            transform: .identity
        )
        defer { SyntheticAssetGenerator.cleanup(url: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fileSize, 0)
    }

    func testCreateSilentVideoGeneratesFile() async throws {
        let url = try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 320, height: 240),
            hasAudio: false,
            isHDR: false,
            transform: .identity
        )
        defer { SyntheticAssetGenerator.cleanup(url: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fileSize, 0)
    }

    func testCreateVideoWithInvalidParametersThrows() async {
        do {
            _ = try await SyntheticAssetGenerator.createVideo(
                durationSeconds: -1.0,
                fps: 30,
                resolution: CGSize(width: 320, height: 240)
            )
            XCTFail("Expected error for negative duration")
        } catch let error as SyntheticAssetError {
            if case .invalidParameters = error {
                // Expected
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Edge Cases and Fault Injection Tests

    func testCreateZeroByteFile() throws {
        let url = try SyntheticAssetGenerator.createZeroByteFile(fileExtension: "jpg")
        defer { SyntheticAssetGenerator.cleanup(url: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        XCTAssertEqual(fileSize, 0)
    }

    func testCreateCorruptedFile() throws {
        let url = try SyntheticAssetGenerator.createCorruptedFile(fileExtension: "mp4")
        defer { SyntheticAssetGenerator.cleanup(url: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
    }

    // MARK: - Cleanup Helper Test

    func testCleanupRemovesFiles() throws {
        let url1 = try SyntheticAssetGenerator.createZeroByteFile(fileExtension: "tmp")
        let url2 = try SyntheticAssetGenerator.createZeroByteFile(fileExtension: "tmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path))

        SyntheticAssetGenerator.cleanup(urls: [url1, url2])

        XCTAssertFalse(FileManager.default.fileExists(atPath: url1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url2.path))
    }
}
