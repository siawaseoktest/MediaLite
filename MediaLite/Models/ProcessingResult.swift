//
//  ProcessingResult.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import Foundation
import UniformTypeIdentifiers
import CoreGraphics

/// Result of an image compression operation.
public struct PhotoCompressionResult: Sendable, Equatable {
    public let originalURL: URL
    public let compressedURL: URL
    public let originalSize: Int64
    public let compressedSize: Int64
    public let format: UTType
    
    public init(
        originalURL: URL,
        compressedURL: URL,
        originalSize: Int64,
        compressedSize: Int64,
        format: UTType
    ) {
        self.originalURL = originalURL
        self.compressedURL = compressedURL
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.format = format
    }
    
    /// Difference in bytes (positive indicates bytes saved, negative indicates size increase).
    public var byteDelta: Int64 {
        originalSize - compressedSize
    }
    
    /// Percentage of file size reduction relative to the original size.
    /// Returns 0.0 if originalSize <= 0 to prevent division by zero or invalid calculations.
    public var reductionPercentage: Double {
        guard originalSize > 0 else { return 0.0 }
        return (Double(byteDelta) / Double(originalSize)) * 100.0
    }
    
    /// True if the compressed file size is strictly larger than the original file size.
    public var isSizeIncreased: Bool {
        compressedSize > originalSize
    }
}

/// Progress update for an active video transcoding or compression operation.
public struct VideoProcessingProgress: Sendable, Equatable {
    /// Fraction of task completed, normalized between 0.0 and 1.0.
    public let fractionCompleted: Double
    /// Human-readable description of current task phase.
    public let description: String
    
    public init(fractionCompleted: Double, description: String) {
        self.fractionCompleted = max(0.0, min(1.0, fractionCompleted))
        self.description = description
    }
}

/// Result of a video transcoding or compression operation.
public struct VideoProcessingResult: Sendable, Equatable {
    public let originalURL: URL
    public let processedURL: URL
    public let originalSize: Int64
    public let processedSize: Int64
    public let duration: Double
    
    public init(
        originalURL: URL,
        processedURL: URL,
        originalSize: Int64,
        processedSize: Int64,
        duration: Double
    ) {
        self.originalURL = originalURL
        self.processedURL = processedURL
        self.originalSize = originalSize
        self.processedSize = processedSize
        self.duration = duration
    }
    
    /// Difference in bytes (positive indicates bytes saved, negative indicates size increase).
    public var byteDelta: Int64 {
        originalSize - processedSize
    }
    
    /// Percentage of file size reduction relative to the original size.
    /// Returns 0.0 if originalSize <= 0 to prevent division by zero or invalid calculations.
    public var reductionPercentage: Double {
        guard originalSize > 0 else { return 0.0 }
        return (Double(byteDelta) / Double(originalSize)) * 100.0
    }
    
    /// True if the processed file size is strictly larger than the original file size.
    public var isSizeIncreased: Bool {
        processedSize > originalSize
    }
}

/// Interface contract for photo compression engines.
public protocol PhotoCompressorProtocol: Sendable {
    func compressPhoto(
        at sourceURL: URL,
        strength: CompressionStrength,
        destinationURL: URL
    ) async throws -> PhotoCompressionResult
}

/// Interface contract for video processing engines.
public protocol VideoProcessorProtocol: Sendable {
    func processVideo(
        at sourceURL: URL,
        mode: VideoProcessingMode,
        strength: CompressionStrength,
        destinationURL: URL
    ) -> (stream: AsyncStream<VideoProcessingProgress>, task: Task<VideoProcessingResult, Error>)
}

// MARK: - Compatibility Aliases
public typealias ImageCompressorProtocol = PhotoCompressorProtocol
public typealias CompressionOptions = CompressionStrength
public typealias VideoConverterProtocol = VideoProcessorProtocol
public typealias VideoConversionOptions = VideoProcessingMode
