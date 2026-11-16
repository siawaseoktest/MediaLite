//
//  TempFileManager.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import Foundation

/// Sandboxed temporary file manager providing lifecycle management, unique file URL generation,
/// orphaned cache purging, and disk storage inspection.
public final class TempFileManager: @unchecked Sendable {
    
    public static let shared = TempFileManager()
    
    private let fileManager: FileManager
    private let tempSubdirectoryName: String
    private let lock = NSLock()
    
    public init(
        fileManager: FileManager = .default,
        tempSubdirectoryName: String = "com.medialite.temp"
    ) {
        self.fileManager = fileManager
        self.tempSubdirectoryName = tempSubdirectoryName
        ensureBaseDirectoryExists()
    }
    
    /// Convenience initializer allowing instantiation with a custom base directory URL.
    /// The last path component of the URL is used as the temporary subdirectory name.
    public convenience init(
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.init(fileManager: fileManager, tempSubdirectoryName: baseDirectory.lastPathComponent)
    }
    
    /// Root directory inside the system temporary folder dedicated to MediaLite operations.
    public var baseDirectory: URL {
        fileManager.temporaryDirectory.appendingPathComponent(tempSubdirectoryName, isDirectory: true)
    }
    
    /// Creates the base temporary directory if it does not yet exist.
    private func ensureBaseDirectoryExists() {
        lock.lock()
        defer { lock.unlock() }
        let dir = baseDirectory
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    /// Generates a unique, non-colliding file URL in the sandboxed temporary directory.
    /// Non-alphanumeric characters in the extension are sanitized to prevent directory traversal.
    /// - Parameter fileExtension: The file extension (e.g. "jpg", "heic", "mp4", "tmp").
    /// - Returns: A unique temporary file URL strictly inside baseDirectory.
    public func createTempFileURL(extension fileExtension: String) -> URL {
        ensureBaseDirectoryExists()
        let stripped = fileExtension.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let cleanExtension = stripped.isEmpty ? "tmp" : stripped
        let fileName = "\(UUID().uuidString).\(cleanExtension)"
        return baseDirectory.appendingPathComponent(fileName)
    }
    
    /// Deletes a specific temporary file at the given URL if it exists strictly within the sandbox.
    /// If the URL points outside the sandbox or targets the base directory itself, removal is refused.
    /// - Parameter url: The file URL to remove.
    public func cleanupTempFile(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let baseStandardizedPath = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let targetStandardizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        
        // Ensure url is strictly a child of baseDirectory and not baseDirectory itself
        guard targetStandardizedPath != baseStandardizedPath,
              targetStandardizedPath.hasPrefix(baseStandardizedPath + "/") else {
            // Outside sandbox or target is baseDirectory: refuse removal
            return
        }
        
        do {
            if fileManager.fileExists(atPath: targetStandardizedPath) {
                try fileManager.removeItem(at: url)
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File was concurrently deleted (TOCTOU safety)
            return
        } catch {
            if !fileManager.fileExists(atPath: targetStandardizedPath) {
                return
            }
            throw error
        }
    }
    
    /// Deletes a collection of temporary files.
    /// - Parameter urls: The file URLs to remove.
    public func cleanupTempFiles(at urls: [URL]) throws {
        var firstError: Error?
        for url in urls {
            do {
                try cleanupTempFile(at: url)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let error = firstError {
            throw error
        }
    }
    
    /// Purges all temporary files in the sandbox older than the specified time threshold.
    /// - Parameter threshold: Age in seconds beyond which files are considered orphaned and removed.
    /// - Returns: The count of orphaned files successfully removed.
    @discardableResult
    public func purgeOrphanedTempFiles(olderThan threshold: TimeInterval = 86400) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        let dir = baseDirectory
        guard fileManager.fileExists(atPath: dir.path) else { return 0 }
        
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let fileURLs = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        
        let cutoffDate = Date().addingTimeInterval(-threshold)
        var purgedCount = 0
        
        for fileURL in fileURLs {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  let modDate = values.contentModificationDate else {
                continue
            }
            
            if modDate < cutoffDate {
                do {
                    try fileManager.removeItem(at: fileURL)
                    purgedCount += 1
                } catch {
                    // Continue purging remaining files even if one fails
                }
            }
        }
        
        return purgedCount
    }
    
    /// Purges all temporary files in the MediaLite temp sandbox regardless of age or modification timestamp.
    /// - Returns: Count of files removed.
    @discardableResult
    public func purgeAllTempFiles() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        let dir = baseDirectory
        guard fileManager.fileExists(atPath: dir.path) else { return 0 }
        
        let fileURLs = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        
        var purgedCount = 0
        for fileURL in fileURLs {
            do {
                try fileManager.removeItem(at: fileURL)
                purgedCount += 1
            } catch {
                // Continue purging remaining files even if one fails
            }
        }
        
        return purgedCount
    }
    
    /// Retrieves the currently available storage capacity on the volume containing the temporary directory.
    /// - Returns: Available space in bytes, or nil if unavailable.
    public func getAvailableDiskSpace() -> Int64? {
        do {
            let values = try baseDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            if let importantCapacity = values.volumeAvailableCapacityForImportantUsage {
                return importantCapacity
            }
            if let availableCapacity = values.volumeAvailableCapacity {
                return Int64(availableCapacity)
            }
        } catch {
            // Fallback: check file system attributes on directory path
            if let attrs = try? fileManager.attributesOfFileSystem(forPath: baseDirectory.path),
               let freeSize = attrs[.systemFreeSize] as? NSNumber {
                return freeSize.int64Value
            }
        }
        return nil
    }
}

// MARK: - StorageManagerProtocol

public protocol StorageManagerProtocol: Sendable {
    func calculateCacheSize() -> Int64
    func purgeAllTempFiles() throws -> Int
    func getAvailableDiskSpace() -> Int64?
}

extension TempFileManager: StorageManagerProtocol {
    public func calculateCacheSize() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for file in files {
            if let vals = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = vals.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

public typealias StorageManager = TempFileManager
