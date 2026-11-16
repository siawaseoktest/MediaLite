//
//  HistoryStorageService.swift
//  MediaLite
//
//  Thread-safe, atomic JSON disk-persisted history store actor.
//  Implements HistoryStorageProtocol matching PROJECT.md Interface Contracts.
//  Provides HistoryStore typealias for backward and test compatibility.
//

import Foundation

// MARK: - HistoryStorageProtocol

/// Interface contract for history storage engines.
public protocol HistoryStorageProtocol: Sendable {
    func loadHistory() async throws -> [CompressionHistoryItem]
    func addItem(_ item: CompressionHistoryItem) async throws
    func deleteItem(id: UUID) async throws
    func clearAllHistory() async throws
}

// MARK: - HistoryStorageService

/// Thread-safe actor providing atomic JSON-backed compression history management.
public actor HistoryStorageService: HistoryStorageProtocol {

    /// Default persistence file URL: `Application Support/MediaLite/history.json`.
    public static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("MediaLite/history.json")
    }

    private let fileURL: URL
    private let fileManager: FileManager

    /// Initializes a HistoryStorageService with an optional storage URL.
    /// Defaults to `Application Support/MediaLite/history.json`.
    public init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = storageURL ?? Self.defaultStorageURL
        self.fileManager = fileManager
    }

    /// Convenience initializer accepting a specific file URL.
    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// The active backing storage file URL.
    public var currentFileURL: URL {
        fileURL
    }

    /// Loads persisted history items from disk.
    /// Safely handles non-existent or corrupted files by returning an empty array without crashing.
    public func loadHistory() async throws -> [CompressionHistoryItem] {
        return readItemsFromDisk()
    }

    /// Adds a new compression history record at the front of the list and persists atomically.
    /// Executed with zero suspension points to guarantee no actor reentrancy race conditions.
    public func addItem(_ item: CompressionHistoryItem) async throws {
        var items = readItemsFromDisk()
        items.insert(item, at: 0)
        try persistItems(items)
    }

    /// Updates an existing history record by ID and persists atomically.
    public func updateItem(_ item: CompressionHistoryItem) async throws {
        var items = readItemsFromDisk()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
            try persistItems(items)
        }
    }

    /// Deletes a single history record by ID and persists atomically.
    public func deleteItem(id: UUID) async throws {
        var items = readItemsFromDisk()
        items.removeAll { $0.id == id }
        try persistItems(items)
    }

    /// Deletes a set of history records by IDs and persists atomically in a single write.
    public func deleteItems(ids: Set<UUID>) async throws {
        var items = readItemsFromDisk()
        items.removeAll { ids.contains($0.id) }
        try persistItems(items)
    }

    /// Clears all history records and updates disk storage.
    public func clearAllHistory() async throws {
        try persistItems([])
    }

    /// Calculates aggregate byte savings, total counts, and reduction percentages.
    public func calculateAggregates() async -> (
        totalOriginalBytes: Int64,
        totalCompressedBytes: Int64,
        totalSavedBytes: Int64,
        reductionPercentage: Double,
        photoCount: Int,
        videoCount: Int
    ) {
        let items = readItemsFromDisk()
        let totalOriginal = items.reduce(Int64(0)) { $0 + $1.originalByteSize }
        let totalCompressed = items.reduce(Int64(0)) { $0 + $1.compressedByteSize }
        let totalSaved = totalOriginal - totalCompressed
        let percentage: Double = totalOriginal > 0 ? (Double(totalSaved) / Double(totalOriginal)) * 100.0 : 0.0
        let photos = items.filter { $0.mediaType.lowercased() == "photo" }.count
        let videos = items.filter { $0.mediaType.lowercased() == "video" }.count

        return (
            totalOriginalBytes: totalOriginal,
            totalCompressedBytes: totalCompressed,
            totalSavedBytes: totalSaved,
            reductionPercentage: percentage,
            photoCount: photos,
            videoCount: videos
        )
    }

    // MARK: - Private Disk Access (Synchronous to prevent actor reentrancy)

    private func readItemsFromDisk() -> [CompressionHistoryItem] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CompressionHistoryItem].self, from: data)
        } catch {
            // Return empty list on corrupted backing file, enabling graceful recovery
            return []
        }
    }

    private func persistItems(_ items: [CompressionHistoryItem]) throws {
        let parentDir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Backward Compatibility Alias

/// Typealias ensuring consistent resolution for both HistoryStore and HistoryStorageService.
public typealias HistoryStore = HistoryStorageService
