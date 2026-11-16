//
//  MediaItem.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Represents a media item (photo or video) selected for processing in MediaLite.
public struct MediaItem: Identifiable, Equatable, Sendable {
    
    /// Processing lifecycle state of an individual media item.
    public enum ProcessingState: String, Codable, Sendable, Equatable {
        case idle
        case queued
        case processing
        case completed
        case failed
        case cancelled
    }
    
    public let id: UUID
    public var url: URL?
    public var data: Data?
    public var format: UTType
    public var originalDimensions: CGSize
    public var duration: Double?
    public var byteSize: Int64
    public var state: ProcessingState
    public var progress: Double // 0.0 ... 1.0
    public var errorMessage: String?
    public var thumbnailData: Data?
    
    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        data: Data? = nil,
        format: UTType,
        originalDimensions: CGSize = .zero,
        duration: Double? = nil,
        byteSize: Int64 = 0,
        state: ProcessingState = .idle,
        progress: Double = 0.0,
        errorMessage: String? = nil,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.url = url
        self.data = data
        self.format = format
        self.originalDimensions = originalDimensions
        self.duration = duration
        self.byteSize = byteSize
        self.state = state
        self.progress = progress
        self.errorMessage = errorMessage
        self.thumbnailData = thumbnailData
    }
    
    /// Indicates whether this item represents a video.
    public var isVideo: Bool {
        format.conforms(to: .movie) || format.conforms(to: .video) || duration != nil
    }
    
    /// Indicates whether this item represents a photo or image.
    public var isPhoto: Bool {
        format.conforms(to: .image) && !isVideo
    }
    
    /// Suggested file name derived from URL or UUID and format extension.
    public var suggestedFileName: String {
        if let url = url {
            return url.lastPathComponent
        }
        let ext = format.preferredFilenameExtension ?? (isVideo ? "mp4" : "jpg")
        return "\(id.uuidString.prefix(8)).\(ext)"
    }
}
