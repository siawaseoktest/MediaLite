//
//  PhotoLibraryService.swift
//  MediaLite
//
//  Add-only PhotoKit integration service.
//  Implements PhotoLibraryProtocol with non-destructive image and video export
//  via PHAssetCreationRequest, honoring the add-only privacy model.
//

import Foundation

#if canImport(Photos)
import Photos

/// Sendable wrapper to hold mutable reference across PHPhotoLibrary performChanges closure.
final class LocalIdentifierBox: @unchecked Sendable {
    var value: String?
}
#else
public enum PHAuthorizationStatus: Int, Sendable {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case authorized = 3
    case limited = 4
}

public enum PHAccessLevel: Int, Sendable {
    case addOnly = 1
    case readWrite = 2
}
#endif

// MARK: - PhotoLibraryProtocol

/// Interface contract for PhotoKit library operations.
public protocol PhotoLibraryProtocol: Sendable {
    func checkAuthorizationStatus() -> PHAuthorizationStatus
    func requestAuthorization() async -> PHAuthorizationStatus
    func saveImage(at fileURL: URL) async throws -> String
    func saveVideo(at fileURL: URL) async throws -> String
}

// MARK: - PhotoLibraryError

/// Strongly typed errors encountered during PhotoKit operations.
public enum PhotoLibraryError: LocalizedError, Sendable, Equatable {
    case permissionDenied
    case assetCreationFailed(String)
    case invalidFileURL(URL)

    // MARK: - Backward Compatibility Aliases
    public static var authorizationDenied: PhotoLibraryError { .permissionDenied }
    public static func fileNotFound(_ url: URL) -> PhotoLibraryError { .invalidFileURL(url) }
    public static func saveFailed(_ reason: String) -> PhotoLibraryError { .assetCreationFailed(reason) }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Photo library access is not authorized."
        case .invalidFileURL(let url):
            return "Media asset file not found or invalid at '\(url.path)'."
        case .assetCreationFailed(let reason):
            return "Failed to save asset to Photo Library: \(reason)."
        }
    }
}

// MARK: - PhotoLibraryService

/// Production PhotoKit service providing safe, add-only asset export.
/// Non-destructive guarantee: NEVER modifies or deletes existing user photos.
public final class PhotoLibraryService: PhotoLibraryProtocol, @unchecked Sendable {

    public typealias StatusProvider = @Sendable () -> PHAuthorizationStatus
    public typealias RequestAuthHandler = @Sendable () async -> PHAuthorizationStatus
    public typealias SaveHandler = @Sendable (_ fileURL: URL, _ isVideo: Bool) async throws -> String

    private let statusProvider: StatusProvider
    private let requestAuthHandler: RequestAuthHandler
    private let customSaveHandler: SaveHandler?

    /// Initializes the PhotoLibraryService.
    /// Default parameters interact directly with system PhotoKit APIs with `.addOnly` access.
    /// Injectable handlers allow isolated unit testing of authorization and failure paths.
    public init(
        statusProvider: StatusProvider? = nil,
        requestAuthHandler: RequestAuthHandler? = nil,
        customSaveHandler: SaveHandler? = nil
    ) {
        self.statusProvider = statusProvider ?? {
            #if canImport(Photos)
            return PHPhotoLibrary.authorizationStatus(for: .addOnly)
            #else
            return .authorized
            #endif
        }
        self.requestAuthHandler = requestAuthHandler ?? {
            #if canImport(Photos)
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            #else
            return .authorized
            #endif
        }
        self.customSaveHandler = customSaveHandler
    }

    /// Checks the current authorization status for add-only photo library access.
    public func checkAuthorizationStatus() -> PHAuthorizationStatus {
        statusProvider()
    }

    /// Prompts the user for add-only photo library access if not determined.
    public func requestAuthorization() async -> PHAuthorizationStatus {
        await requestAuthHandler()
    }

    /// Saves a compressed image to the Photo Library non-destructively.
    /// Throws `PhotoLibraryError.invalidFileURL` if the file does not exist,
    /// `PhotoLibraryError.permissionDenied` if access is denied/restricted,
    /// or `PhotoLibraryError.assetCreationFailed` if creation fails.
    public func saveImage(at fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PhotoLibraryError.invalidFileURL(fileURL)
        }

        var status = checkAuthorizationStatus()
        if status == .notDetermined {
            status = await requestAuthorization()
        }
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }

        if let customSaveHandler = customSaveHandler {
            return try await customSaveHandler(fileURL, false)
        }

        #if canImport(Photos)
        let idBox = LocalIdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                idBox.value = request?.placeholderForCreatedAsset?.localIdentifier
            }
        } catch let error as PhotoLibraryError {
            throw error
        } catch {
            throw PhotoLibraryError.assetCreationFailed(error.localizedDescription)
        }

        guard let id = idBox.value else {
            throw PhotoLibraryError.assetCreationFailed("No local identifier returned after photo creation")
        }
        return id
        #else
        return "synthetic-asset-id-\(UUID().uuidString)"
        #endif
    }

    /// Saves a compressed or converted video to the Photo Library non-destructively.
    /// Throws `PhotoLibraryError.invalidFileURL` if the file does not exist,
    /// `PhotoLibraryError.permissionDenied` if access is denied/restricted,
    /// or `PhotoLibraryError.assetCreationFailed` if creation fails.
    public func saveVideo(at fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PhotoLibraryError.invalidFileURL(fileURL)
        }

        var status = checkAuthorizationStatus()
        if status == .notDetermined {
            status = await requestAuthorization()
        }
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }

        if let customSaveHandler = customSaveHandler {
            return try await customSaveHandler(fileURL, true)
        }

        #if canImport(Photos)
        let idBox = LocalIdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                idBox.value = request?.placeholderForCreatedAsset?.localIdentifier
            }
        } catch let error as PhotoLibraryError {
            throw error
        } catch {
            throw PhotoLibraryError.assetCreationFailed(error.localizedDescription)
        }

        guard let id = idBox.value else {
            throw PhotoLibraryError.assetCreationFailed("No local identifier returned after video creation")
        }
        return id
        #else
        return "synthetic-asset-id-\(UUID().uuidString)"
        #endif
    }
}
