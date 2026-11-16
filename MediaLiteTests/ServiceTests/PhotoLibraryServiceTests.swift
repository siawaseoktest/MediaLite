//
//  PhotoLibraryServiceTests.swift
//  MediaLiteTests
//
//  Unit tests for PhotoLibraryService and PhotoKit integration.
//  Covers authorization status checks, invalid file URL handling,
//  permission denied error paths, asset creation failure handling,
//  and successful photo/video save mock branches honoring the add-only privacy model.
//

import XCTest
#if canImport(Photos)
import Photos
#endif
@testable import MediaLite

final class PhotoLibraryServiceTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var testImageURL: URL!
    private var testVideoURL: URL!

    override func setUp() {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.medialite.tests.photolib.\(uniqueID)")
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        testImageURL = tempDirectoryURL.appendingPathComponent("test_image.jpg")
        testVideoURL = tempDirectoryURL.appendingPathComponent("test_video.mp4")

        try? "dummy image content".write(to: testImageURL, atomically: true, encoding: .utf8)
        try? "dummy video content".write(to: testVideoURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        testImageURL = nil
        testVideoURL = nil
        super.tearDown()
    }

    // MARK: - 1. Authorization Status Checks

    func testCheckAuthorizationStatusReturnsConfiguredStatus() {
        let authorizedService = PhotoLibraryService(statusProvider: { .authorized })
        XCTAssertEqual(authorizedService.checkAuthorizationStatus(), .authorized)

        let deniedService = PhotoLibraryService(statusProvider: { .denied })
        XCTAssertEqual(deniedService.checkAuthorizationStatus(), .denied)

        let restrictedService = PhotoLibraryService(statusProvider: { .restricted })
        XCTAssertEqual(restrictedService.checkAuthorizationStatus(), .restricted)

        let notDeterminedService = PhotoLibraryService(statusProvider: { .notDetermined })
        XCTAssertEqual(notDeterminedService.checkAuthorizationStatus(), .notDetermined)
    }

    func testRequestAuthorizationReturnsResult() async {
        let service = PhotoLibraryService(
            statusProvider: { .notDetermined },
            requestAuthHandler: { .authorized }
        )
        let status = await service.requestAuthorization()
        XCTAssertEqual(status, .authorized)
    }

    // MARK: - 2. Invalid File URL Handling

    func testSaveImageThrowsInvalidFileURLWhenFileDoesNotExist() async {
        let service = PhotoLibraryService(statusProvider: { .authorized })
        let nonExistentURL = tempDirectoryURL.appendingPathComponent("does_not_exist.jpg")

        do {
            _ = try await service.saveImage(at: nonExistentURL)
            XCTFail("Expected invalidFileURL error to be thrown")
        } catch let error as PhotoLibraryError {
            XCTAssertEqual(error, .invalidFileURL(nonExistentURL))
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSaveVideoThrowsInvalidFileURLWhenFileDoesNotExist() async {
        let service = PhotoLibraryService(statusProvider: { .authorized })
        let nonExistentURL = tempDirectoryURL.appendingPathComponent("does_not_exist.mp4")

        do {
            _ = try await service.saveVideo(at: nonExistentURL)
            XCTFail("Expected invalidFileURL error to be thrown")
        } catch let error as PhotoLibraryError {
            XCTAssertEqual(error, .invalidFileURL(nonExistentURL))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - 3. Permission Denied Branches

    func testSaveImageThrowsPermissionDeniedWhenDenied() async {
        let service = PhotoLibraryService(
            statusProvider: { .denied },
            requestAuthHandler: { .denied }
        )

        do {
            _ = try await service.saveImage(at: testImageURL)
            XCTFail("Expected permissionDenied error")
        } catch let error as PhotoLibraryError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveVideoThrowsPermissionDeniedWhenRestricted() async {
        let service = PhotoLibraryService(
            statusProvider: { .restricted },
            requestAuthHandler: { .restricted }
        )

        do {
            _ = try await service.saveVideo(at: testVideoURL)
            XCTFail("Expected permissionDenied error")
        } catch let error as PhotoLibraryError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveImageThrowsPermissionDeniedWhenUserRejectsPrompt() async {
        let service = PhotoLibraryService(
            statusProvider: { .notDetermined },
            requestAuthHandler: { .denied }
        )

        do {
            _ = try await service.saveImage(at: testImageURL)
            XCTFail("Expected permissionDenied error")
        } catch let error as PhotoLibraryError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - 4. Asset Creation Failure Branch

    func testSaveImageThrowsAssetCreationFailedWhenHandlerFails() async {
        let service = PhotoLibraryService(
            statusProvider: { .authorized },
            customSaveHandler: { _, _ in
                throw PhotoLibraryError.assetCreationFailed("Disk full or simulator restriction")
            }
        )

        do {
            _ = try await service.saveImage(at: testImageURL)
            XCTFail("Expected assetCreationFailed error")
        } catch let error as PhotoLibraryError {
            XCTAssertEqual(error, .assetCreationFailed("Disk full or simulator restriction"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveVideoThrowsAssetCreationFailedWhenHandlerFails() async {
        let service = PhotoLibraryService(
            statusProvider: { .authorized },
            customSaveHandler: { _, _ in
                throw PhotoLibraryError.assetCreationFailed("Video track missing")
            }
        )

        do {
            _ = try await service.saveVideo(at: testVideoURL)
            XCTFail("Expected assetCreationFailed error")
        } catch let error as PhotoLibraryError {
            XCTAssertEqual(error, .assetCreationFailed("Video track missing"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - 5. Successful Save Branches

    func testSaveImageSuccessReturnsLocalIdentifier() async throws {
        let expectedID = "PHAsset-\(UUID().uuidString)"
        let service = PhotoLibraryService(
            statusProvider: { .authorized },
            customSaveHandler: { fileURL, isVideo in
                XCTAssertFalse(isVideo)
                XCTAssertEqual(fileURL, self.testImageURL)
                return expectedID
            }
        )

        let localID = try await service.saveImage(at: testImageURL)
        XCTAssertEqual(localID, expectedID)
    }

    func testSaveVideoSuccessReturnsLocalIdentifier() async throws {
        let expectedID = "PHAssetVideo-\(UUID().uuidString)"
        let service = PhotoLibraryService(
            statusProvider: { .authorized },
            customSaveHandler: { fileURL, isVideo in
                XCTAssertTrue(isVideo)
                XCTAssertEqual(fileURL, self.testVideoURL)
                return expectedID
            }
        )

        let localID = try await service.saveVideo(at: testVideoURL)
        XCTAssertEqual(localID, expectedID)
    }

    func testSaveImageSuccessWithLimitedAuthorization() async throws {
        let expectedID = "PHAssetLimited-\(UUID().uuidString)"
        let service = PhotoLibraryService(
            statusProvider: { .limited },
            customSaveHandler: { fileURL, isVideo in
                XCTAssertFalse(isVideo)
                XCTAssertEqual(fileURL, self.testImageURL)
                return expectedID
            }
        )

        let localID = try await service.saveImage(at: testImageURL)
        XCTAssertEqual(localID, expectedID)
    }

    func testSaveVideoSuccessWithLimitedAuthorization() async throws {
        let expectedID = "PHAssetVideoLimited-\(UUID().uuidString)"
        let service = PhotoLibraryService(
            statusProvider: { .limited },
            customSaveHandler: { fileURL, isVideo in
                XCTAssertTrue(isVideo)
                XCTAssertEqual(fileURL, self.testVideoURL)
                return expectedID
            }
        )

        let localID = try await service.saveVideo(at: testVideoURL)
        XCTAssertEqual(localID, expectedID)
    }

    func testSaveImagePromptsWhenNotDeterminedAndSucceedsOnAuthorization() async throws {
        let expectedID = "PHAssetPromptAuth-\(UUID().uuidString)"
        let service = PhotoLibraryService(
            statusProvider: { .notDetermined },
            requestAuthHandler: { .authorized },
            customSaveHandler: { fileURL, isVideo in
                XCTAssertFalse(isVideo)
                return expectedID
            }
        )

        let localID = try await service.saveImage(at: testImageURL)
        XCTAssertEqual(localID, expectedID)
    }

    // MARK: - 6. Protocol Polymorphism & Mock Conformance

    func testProtocolConformanceWithMock() async throws {
        struct MockPhotoLibrary: PhotoLibraryProtocol {
            var statusToReturn: PHAuthorizationStatus = .authorized
            var idToReturn: String = "mock-id-123"

            func checkAuthorizationStatus() -> PHAuthorizationStatus { statusToReturn }
            func requestAuthorization() async -> PHAuthorizationStatus { statusToReturn }
            func saveImage(at fileURL: URL) async throws -> String { idToReturn }
            func saveVideo(at fileURL: URL) async throws -> String { idToReturn }
        }

        let mock: PhotoLibraryProtocol = MockPhotoLibrary()
        XCTAssertEqual(mock.checkAuthorizationStatus(), .authorized)
        let requestedStatus = await mock.requestAuthorization()
        XCTAssertEqual(requestedStatus, .authorized)

        let savedImageID = try await mock.saveImage(at: testImageURL)
        XCTAssertEqual(savedImageID, "mock-id-123")

        let savedVideoID = try await mock.saveVideo(at: testVideoURL)
        XCTAssertEqual(savedVideoID, "mock-id-123")
    }

    // MARK: - 7. Error Descriptions and Backward Compatibility

    func testPhotoLibraryErrorDescriptions() {
        let permissionError = PhotoLibraryError.permissionDenied
        XCTAssertEqual(permissionError.errorDescription, "Photo library access is not authorized.")

        let invalidURLError = PhotoLibraryError.invalidFileURL(testImageURL)
        XCTAssertTrue(invalidURLError.errorDescription?.contains(testImageURL.path) ?? false)

        let creationError = PhotoLibraryError.assetCreationFailed("Bad encoding")
        XCTAssertTrue(creationError.errorDescription?.contains("Bad encoding") ?? false)

        // Compatibility aliases
        XCTAssertEqual(PhotoLibraryError.authorizationDenied, .permissionDenied)
        XCTAssertEqual(PhotoLibraryError.fileNotFound(testImageURL), .invalidFileURL(testImageURL))
        XCTAssertEqual(PhotoLibraryError.saveFailed("fail"), .assetCreationFailed("fail"))
    }
}
