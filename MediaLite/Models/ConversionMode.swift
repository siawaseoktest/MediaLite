//
//  ConversionMode.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import Foundation

/// Defines video processing modes supported by the MediaLite transcoding engine.
public enum VideoProcessingMode: String, CaseIterable, Codable, Sendable {
    /// Reduce file size using the existing source codec and compression scaling.
    case reduceSize = "reduceSize"
    
    /// Transcode to universally compatible H.264 video and AAC-LC audio in an MP4 container.
    case improveCompatibility = "improveCompatibility"
    
    /// Apply both compression reduction and H.264/AAC transcoding simultaneously.
    case compressAndConvert = "compressAndConvert"
    
    /// User-friendly localized title.
    public var title: String {
        switch self {
        case .reduceSize:
            return "Reduce Size"
        case .improveCompatibility:
            return "Improve Compatibility (H.264)"
        case .compressAndConvert:
            return "Compress & Convert (H.264)"
        }
    }
    
    /// Descriptive explanation of the processing mode.
    public var localizedDescription: String {
        switch self {
        case .reduceSize:
            return "Compresses video using the original codec to save storage space while maintaining visual quality."
        case .improveCompatibility:
            return "Converts modern formats (HEVC, MOV) to universal H.264 and AAC in an MP4 container for playback on all devices."
        case .compressAndConvert:
            return "Combines aggressive file size reduction with universal H.264 conversion for web and cross-platform sharing."
        }
    }
    
    /// SF Symbol icon name representing the mode.
    public var iconName: String {
        switch self {
        case .reduceSize:
            return "arrow.down.right.and.arrow.up.left"
        case .improveCompatibility:
            return "play.rectangle.on.rectangle"
        case .compressAndConvert:
            return "bolt.horizontal.circle"
        }
    }
}

/// Type alias for backward compatibility and semantic clarity across components.
public typealias ConversionMode = VideoProcessingMode
