//
//  HistoryRecord.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import Foundation

/// Persistent record of a completed compression or conversion operation.
public struct CompressionHistoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let fileName: String
    /// Type of media: "photo" or "video"
    public let mediaType: String
    public let sourceFormat: String
    public let targetFormat: String
    public let originalByteSize: Int64
    public let compressedByteSize: Int64
    public let compressionStrength: CompressionStrength
    public let durationSeconds: Double?
    public var isSavedToLibrary: Bool
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        fileName: String,
        mediaType: String,
        sourceFormat: String,
        targetFormat: String,
        originalByteSize: Int64,
        compressedByteSize: Int64,
        compressionStrength: CompressionStrength,
        durationSeconds: Double? = nil,
        isSavedToLibrary: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.mediaType = mediaType
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.originalByteSize = originalByteSize
        self.compressedByteSize = compressedByteSize
        self.compressionStrength = compressionStrength
        self.durationSeconds = durationSeconds
        self.isSavedToLibrary = isSavedToLibrary
    }
    
    /// Difference in bytes (positive indicates bytes saved, negative indicates size increase).
    public var byteDelta: Int64 {
        originalByteSize - compressedByteSize
    }
    
    /// Percentage of file size reduction relative to the original size.
    /// Returns 0.0 if originalByteSize <= 0 to safely prevent division by zero.
    public var reductionPercentage: Double {
        guard originalByteSize > 0 else { return 0.0 }
        return (Double(byteDelta) / Double(originalByteSize)) * 100.0
    }
    
    /// True if the compressed file size is strictly larger than the original file size.
    public var isSizeIncreased: Bool {
        compressedByteSize > originalByteSize
    }
}

/// Type alias for backward compatibility and semantic clarity across components.
public typealias HistoryRecord = CompressionHistoryItem

// MARK: - Backward Compatibility & Architecture Facades

/// Alias for CompressionHistoryItem matching architecture specifications
public typealias ProcessingRecord = CompressionHistoryItem

/// Lifetime and storage statistics representation
public struct LifetimeStats: Equatable, Sendable {
    public let totalOriginalBytes: Int64
    public let totalCompressedBytes: Int64
    public let totalSavedBytes: Int64
    public let reductionPercentage: Double
    public let photoCount: Int
    public let videoCount: Int
    
    public var totalItems: Int { photoCount + videoCount }
    
    public init(
        totalOriginalBytes: Int64 = 0,
        totalCompressedBytes: Int64 = 0,
        totalSavedBytes: Int64 = 0,
        reductionPercentage: Double = 0.0,
        photoCount: Int = 0,
        videoCount: Int = 0
    ) {
        self.totalOriginalBytes = totalOriginalBytes
        self.totalCompressedBytes = totalCompressedBytes
        self.totalSavedBytes = totalSavedBytes
        self.reductionPercentage = reductionPercentage
        self.photoCount = photoCount
        self.videoCount = videoCount
    }
}

public typealias StorageStats = LifetimeStats
public typealias ActivityLoggerProtocol = HistoryStorageProtocol
