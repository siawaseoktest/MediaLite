//
//  TempFileManagerTests.swift
//  MediaLiteTests
//
//  Created for MediaLite Milestone 1.
//

import XCTest
@testable import MediaLite

final class TempFileManagerTests: XCTestCase {
    
    private var tempManager: TempFileManager!
    private var testSubdirectory: String!
    
    override func setUp() {
        super.setUp()
        testSubdirectory = "com.medialite.tests.temp.\(UUID().uuidString)"
        tempManager = TempFileManager(tempSubdirectoryName: testSubdirectory)
    }
    
    override func tearDown() {
        try? tempManager.purgeAllTempFiles()
        try? FileManager.default.removeItem(at: tempManager.baseDirectory)
        tempManager = nil
        testSubdirectory = nil
        super.tearDown()
    }
    
    func testUniqueTempURLGeneration() {
        let url1 = tempManager.createTempFileURL(extension: "jpg")
        let url2 = tempManager.createTempFileURL(extension: "jpg")
        let url3 = tempManager.createTempFileURL(extension: ".mp4")
        
        XCTAssertNotEqual(url1, url2)
        XCTAssertEqual(url1.pathExtension, "jpg")
        XCTAssertEqual(url3.pathExtension, "mp4")
        XCTAssertTrue(url1.path.contains(testSubdirectory))
        XCTAssertTrue(url2.path.contains(testSubdirectory))
    }
    
    func testFileCreationAndSingleCleanup() throws {
        let fileURL = tempManager.createTempFileURL(extension: "tmp")
        let sampleData = "Sample temp content for MediaLite".data(using: .utf8)!
        
        // Write data
        try sampleData.write(to: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        
        // Cleanup
        try tempManager.cleanupTempFile(at: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        
        // Cleanup on non-existent file should not throw
        XCTAssertNoThrow(try tempManager.cleanupTempFile(at: fileURL))
    }
    
    func testBatchCleanup() throws {
        var urls: [URL] = []
        for i in 0..<4 {
            let url = tempManager.createTempFileURL(extension: "dat")
            let data = "Batch item \(i)".data(using: .utf8)!
            try data.write(to: url)
            urls.append(url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        
        try tempManager.cleanupTempFiles(at: urls)
        
        for url in urls {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    
    func testOrphanedTempFilePurge() throws {
        let oldFileURL = tempManager.createTempFileURL(extension: "old")
        let freshFileURL = tempManager.createTempFileURL(extension: "fresh")
        
        let testData = "test".data(using: .utf8)!
        try testData.write(to: oldFileURL)
        try testData.write(to: freshFileURL)
        
        // Set oldFileURL modification date to 3 hours ago (10,800 seconds)
        let oldDate = Date().addingTimeInterval(-10800)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFileURL.path)
        
        // Purge files older than 1 hour (3600 seconds)
        let purgedCount = try tempManager.purgeOrphanedTempFiles(olderThan: 3600)
        
        XCTAssertEqual(purgedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFileURL.path), "Old file should be purged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFileURL.path), "Fresh file should be kept")
    }
    
    func testPurgeAllTempFiles() throws {
        for _ in 0..<3 {
            let url = tempManager.createTempFileURL(extension: "tmp")
            try "data".data(using: .utf8)!.write(to: url)
        }
        
        let purgedCount = try tempManager.purgeAllTempFiles()
        XCTAssertEqual(purgedCount, 3)
    }
    
    func testAvailableDiskSpaceReporting() {
        let availableSpace = tempManager.getAvailableDiskSpace()
        XCTAssertNotNil(availableSpace, "Available disk space should be queryable")
        if let space = availableSpace {
            XCTAssertGreaterThan(space, 0, "Available disk space should be greater than zero")
        }
    }
    
    func testCleanupRefusesToDeleteExternalFiles() throws {
        // Create an external file outside the sandbox
        let externalDir = FileManager.default.temporaryDirectory.appendingPathComponent("com.medialite.tests.external.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }
        
        let externalFile = externalDir.appendingPathComponent("external_secret.txt")
        let secretData = "Important User Data".data(using: .utf8)!
        try secretData.write(to: externalFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))
        
        // Attempt cleanup of external file through tempManager - should refuse removal
        try tempManager.cleanupTempFile(at: externalFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path), "cleanupTempFile must not delete external files outside baseDirectory")
        
        // Also verify attempting to delete baseDirectory itself is safely refused
        try tempManager.cleanupTempFile(at: tempManager.baseDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempManager.baseDirectory.path), "cleanupTempFile must not delete baseDirectory itself")
    }
    
    func testCreateTempFileURLSanitizesMaliciousExtension() {
        let maliciousExtension = "../../../../secret"
        let generatedURL = tempManager.createTempFileURL(extension: maliciousExtension)
        
        // Ensure path is strictly inside baseDirectory
        let baseStandardized = tempManager.baseDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let generatedStandardized = generatedURL.standardizedFileURL.resolvingSymlinksInPath().path
        
        XCTAssertTrue(generatedStandardized.hasPrefix(baseStandardized + "/"), "Generated URL must remain inside baseDirectory")
        XCTAssertEqual(generatedURL.pathExtension, "secret", "Extension should have path separators and traversal tokens stripped")
        
        // Test traversal-only extension defaults to tmp
        let emptyExtURL = tempManager.createTempFileURL(extension: "../../..")
        XCTAssertEqual(emptyExtURL.pathExtension, "tmp", "Traversal-only extension must default to tmp")
    }
    
    func testPurgeAllTempFilesRemovesFutureTimestampedFiles() throws {
        let futureFileURL = tempManager.createTempFileURL(extension: "future")
        try "future content".data(using: .utf8)!.write(to: futureFileURL)
        
        // Set modification date 2 days into the future
        let futureDate = Date().addingTimeInterval(172800)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: futureFileURL.path)
        
        let purgedCount = try tempManager.purgeAllTempFiles()
        XCTAssertEqual(purgedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: futureFileURL.path), "Purge all must unconditionally delete files regardless of future timestamps")
    }
}
