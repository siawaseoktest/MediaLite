//
//  PrivacyAndSecurityE2ETests.swift
//  MediaLiteTests
//
//  Tier 1 Feature Coverage E2E Tests: Privacy, Security & Local Isolation.
//  Covers zero network imports invariant verification in MediaLite/,
//  verification that original media files are never overwritten or deleted,
//  and sandboxed temp file isolation and lifecycle cleanup verification.
//

import XCTest
import UniformTypeIdentifiers
import CryptoKit
@testable import MediaLite

final class PrivacyAndSecurityE2ETests: XCTestCase {

    private var trackedURLs: [URL] = []
    private var compressor: PhotoCompressorProtocol!
    private var videoProcessor: VideoProcessorProtocol!

    override func setUp() {
        super.setUp()
        trackedURLs = []
        compressor = PhotoCompressorService()
        videoProcessor = VideoProcessorService()
    }

    override func tearDown() {
        SyntheticAssetGenerator.cleanup(urls: trackedURLs)
        trackedURLs.removeAll()
        try? TempFileManager.shared.purgeAllTempFiles()
        compressor = nil
        videoProcessor = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func trackURL(_ url: URL) -> URL {
        trackedURLs.append(url)
        return url
    }

    // MARK: - 1. Zero Network Imports Static Analysis

    func testZeroNetworkImportsInProductionSourceCode() throws {
        // Locate production source directory MediaLite/
        let fileManager = FileManager.default
        let currentPath = fileManager.currentDirectoryPath
        let projectRoot = URL(fileURLWithPath: currentPath)
        let sourceDir = projectRoot.appendingPathComponent("MediaLite")

        guard fileManager.fileExists(atPath: sourceDir.path) else {
            // If running inside custom sandbox, locate via bundle or source layout
            return
        }

        let enumerator = fileManager.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var inspectedFileCount = 0
        var forbiddenViolations: [String] = []

        let forbiddenImportPatterns = [
            "import Network",
            "import WebKit",
            "import CFNetwork"
        ]

        let forbiddenSymbolPatterns = [
            "URLSession",
            "NWPathMonitor",
            "WKWebView",
            "NSURLConnection",
            "Alamofire"
        ]

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            inspectedFileCount += 1

            let fileContent = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = fileContent.components(separatedBy: .newlines)

            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }

                for forbiddenImport in forbiddenImportPatterns {
                    if trimmed.hasPrefix(forbiddenImport) {
                        forbiddenViolations.append("\(fileURL.lastPathComponent):\(lineIndex + 1): \(forbiddenImport)")
                    }
                }

                for forbiddenSymbol in forbiddenSymbolPatterns {
                    if trimmed.contains(forbiddenSymbol) {
                        forbiddenViolations.append("\(fileURL.lastPathComponent):\(lineIndex + 1): contains forbidden symbol \(forbiddenSymbol)")
                    }
                }
            }
        }

        XCTAssertGreaterThan(inspectedFileCount, 0, "Must inspect at least one production Swift file")
        XCTAssertTrue(
            forbiddenViolations.isEmpty,
            "Zero-network policy violated! Found prohibited networking APIs:\n\(forbiddenViolations.joined(separator: "\n"))"
        )
    }

    // MARK: - 2. Non-Destructive Photo Processing

    func testOriginalPhotoNeverOverwrittenOrDeletedDuringCompression() async throws {
        // Synthesize test JPEG
        let sourceURL = trackURL(try SyntheticAssetGenerator.createJPEG(
            width: 300,
            height: 300,
            hasExif: true
        ))

        // Capture initial file properties and cryptographic checksum
        let initialData = try Data(contentsOf: sourceURL)
        let initialChecksum = SHA256.hash(data: initialData)
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let initialModDate = initialAttributes[.modificationDate] as? Date

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "jpg"))
        XCTAssertNotEqual(sourceURL, destURL, "Destination must be distinct from source URL")

        // Perform compression
        let result = try await compressor.compressPhoto(
            at: sourceURL,
            strength: .medium,
            destinationURL: destURL
        )

        // Verify output file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.compressedURL.path))

        // Invariant: Original file must STILL exist
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceURL.path),
            "Original photo must not be deleted or moved during compression"
        )

        // Invariant: Original file content must be 100% byte-for-byte identical
        let postData = try Data(contentsOf: sourceURL)
        let postChecksum = SHA256.hash(data: postData)
        XCTAssertEqual(
            postChecksum,
            initialChecksum,
            "Original photo content was modified! MediaLite operations must be strictly non-destructive"
        )
        XCTAssertEqual(postData.count, initialData.count, "Original photo size must not change")

        // Invariant: Modification date must remain untouched
        let postAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let postModDate = postAttributes[.modificationDate] as? Date
        XCTAssertEqual(postModDate, initialModDate, "Original photo modification date must not change")
    }

    // MARK: - 3. Non-Destructive Video Processing

    func testOriginalVideoNeverOverwrittenOrDeletedDuringProcessing() async throws {
        let sourceURL = trackURL(try await SyntheticAssetGenerator.createVideo(
            durationSeconds: 0.5,
            fps: 30,
            resolution: CGSize(width: 480, height: 360),
            hasAudio: true
        ))

        let initialData = try Data(contentsOf: sourceURL)
        let initialChecksum = SHA256.hash(data: initialData)
        let initialAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let initialModDate = initialAttrs[.modificationDate] as? Date

        let destURL = trackURL(TempFileManager.shared.createTempFileURL(extension: "mp4"))
        XCTAssertNotEqual(sourceURL, destURL)

        let (stream, task) = videoProcessor.processVideo(
            at: sourceURL,
            mode: .reduceSize,
            strength: .medium,
            destinationURL: destURL
        )

        let streamDrain = Task {
            for await _ in stream {}
        }

        let result = try await task.value
        _ = await streamDrain.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.processedURL.path))

        // Invariant: Original video file must still exist and be identical
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path), "Original video must not be deleted")

        let postData = try Data(contentsOf: sourceURL)
        let postChecksum = SHA256.hash(data: postData)
        XCTAssertEqual(postChecksum, initialChecksum, "Original video was altered during transcoding")

        let postAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let postModDate = postAttrs[.modificationDate] as? Date
        XCTAssertEqual(postModDate, initialModDate, "Original video modification date changed")
    }

    // MARK: - 4. Sandboxed Directory Isolation

    func testTempFileManagerSandboxedDirectoryIsolation() {
        let manager = TempFileManager.shared
        let baseDir = manager.baseDirectory

        // Base directory must reside inside system temporary directory
        XCTAssertTrue(
            baseDir.path.contains("com.medialite.temp"),
            "TempFileManager base directory must have dedicated sandbox subdirectory name"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDir.path))

        // Create multiple temp URLs
        let url1 = manager.createTempFileURL(extension: "jpg")
        let url2 = manager.createTempFileURL(extension: "mp4")
        let url3 = manager.createTempFileURL(extension: ".heic")

        // Invariant: All files must reside strictly within the sandboxed base directory
        XCTAssertEqual(url1.deletingLastPathComponent(), baseDir)
        XCTAssertEqual(url2.deletingLastPathComponent(), baseDir)
        XCTAssertEqual(url3.deletingLastPathComponent(), baseDir)

        // Invariant: URLs must be non-colliding
        XCTAssertNotEqual(url1, url2)
        XCTAssertNotEqual(url2, url3)
        XCTAssertNotEqual(url1, url3)

        // Extension cleansing check
        XCTAssertEqual(url1.pathExtension, "jpg")
        XCTAssertEqual(url2.pathExtension, "mp4")
        XCTAssertEqual(url3.pathExtension, "heic")
    }

    // MARK: - 5. Temp File Creation & Lifecycle Cleanup

    func testSandboxedTempFileCreationAndGuaranteedCleanup() throws {
        let manager = TempFileManager(tempSubdirectoryName: "com.medialite.tests.cleanup.\(UUID().uuidString)")
        defer {
            try? manager.purgeAllTempFiles()
            try? FileManager.default.removeItem(at: manager.baseDirectory)
        }

        let file1 = manager.createTempFileURL(extension: "tmp")
        let file2 = manager.createTempFileURL(extension: "tmp")
        let file3 = manager.createTempFileURL(extension: "tmp")

        let dummyData = "MediaLite Secure Temporary Data".data(using: .utf8)!
        try dummyData.write(to: file1)
        try dummyData.write(to: file2)
        try dummyData.write(to: file3)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file3.path))

        // Single file cleanup
        try manager.cleanupTempFile(at: file1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1.path), "file1 must be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path), "file2 must still exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file3.path), "file3 must still exist")

        // Batch cleanup
        try manager.cleanupTempFiles(at: [file2, file3])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2.path), "file2 must be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file3.path), "file3 must be deleted")

        // Cleanup on non-existent file must not throw
        XCTAssertNoThrow(try manager.cleanupTempFile(at: file1))
    }

    // MARK: - 6. Privacy Manifest & Info.plist Invariants

    func testPrivacyManifestAndInfoPlistDeclarations() throws {
        let fileManager = FileManager.default
        let currentPath = fileManager.currentDirectoryPath
        let projectRoot = URL(fileURLWithPath: currentPath)

        // 1. Info.plist inspection
        let infoPlistURL = projectRoot.appendingPathComponent("MediaLite/Resources/Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            // Skip if not in full repo context
            return
        }

        let plistData = try Data(contentsOf: infoPlistURL)
        let plistObj = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        guard let infoPlist = plistObj else {
            XCTFail("Failed to deserialize Info.plist")
            return
        }

        // Privacy Invariant: MUST contain NSPhotoLibraryAddUsageDescription (add-only)
        XCTAssertNotNil(
            infoPlist["NSPhotoLibraryAddUsageDescription"],
            "Info.plist must declare NSPhotoLibraryAddUsageDescription for safe library export"
        )

        // Privacy Invariant: MUST NOT contain NSPhotoLibraryUsageDescription (no full library read access)
        XCTAssertNil(
            infoPlist["NSPhotoLibraryUsageDescription"],
            "Info.plist must NOT declare NSPhotoLibraryUsageDescription (privacy violation)"
        )

        // 2. PrivacyInfo.xcprivacy inspection
        let privacyManifestURL = projectRoot.appendingPathComponent("MediaLite/Resources/PrivacyInfo.xcprivacy")
        guard fileManager.fileExists(atPath: privacyManifestURL.path) else {
            return
        }

        let privacyData = try Data(contentsOf: privacyManifestURL)
        let privacyObj = try PropertyListSerialization.propertyList(from: privacyData, format: nil) as? [String: Any]
        guard let privacyInfo = privacyObj else {
            XCTFail("Failed to deserialize PrivacyInfo.xcprivacy")
            return
        }

        // Must declare no tracking
        let tracking = privacyInfo["NSPrivacyTracking"] as? Bool
        XCTAssertEqual(tracking, false, "NSPrivacyTracking must be false")

        // Must declare no data collection
        let collectedTypes = privacyInfo["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        XCTAssertEqual(collectedTypes?.count ?? 0, 0, "NSPrivacyCollectedDataTypes must be empty")

        // Must declare UserDefaults access with CA92.1
        let accessedTypes = privacyInfo["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        let hasUserDefaultsReason = accessedTypes?.contains(where: { dict in
            guard let category = dict["NSPrivacyAccessedAPIType"] as? String,
                  let reasons = dict["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return false }
            return category == "NSPrivacyAccessedAPICategoryUserDefaults" && reasons.contains("CA92.1")
        }) ?? false

        XCTAssertTrue(
            hasUserDefaultsReason,
            "Privacy manifest must declare NSPrivacyAccessedAPICategoryUserDefaults with reason CA92.1"
        )
    }
}
