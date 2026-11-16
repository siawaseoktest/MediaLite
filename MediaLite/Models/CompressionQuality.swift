//
//  CompressionQuality.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import Foundation
import CoreGraphics

/// Defines the user-selectable compression intensity levels and their underlying scaling parameters.
public enum CompressionStrength: String, CaseIterable, Codable, Sendable {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    
    /// Target lossy image compression quality factor (0.0 to 1.0).
    /// - low: 0.90 (minimal compression, highest fidelity)
    /// - medium: 0.75 (balanced compression and size)
    /// - high: 0.55 (aggressive compression, maximum size reduction)
    public var lossyQuality: CGFloat {
        switch self {
        case .low:
            return 0.90
        case .medium:
            return 0.75
        case .high:
            return 0.55
        }
    }
    
    /// Target dimension scaling factor applied during downsampling (0.0 to 1.0).
    /// - low: 0.95 (95% of original dimensions)
    /// - medium: 0.87 (87% of original dimensions)
    /// - high: 0.74 (74% of original dimensions)
    public var dimensionScale: CGFloat {
        switch self {
        case .low:
            return 0.95
        case .medium:
            return 0.87
        case .high:
            return 0.74
        }
    }
    
    /// Human-readable title for UI presentation.
    public var displayName: String {
        switch self {
        case .low:
            return "Low (High Quality)"
        case .medium:
            return "Medium (Balanced)"
        case .high:
            return "High (Maximum Savings)"
        }
    }
    
    /// Detailed description of the compression trade-offs.
    public var localizedDescription: String {
        switch self {
        case .low:
            return "Light compression (~90% quality). Preserves maximum detail, ideal for archival or printing."
        case .medium:
            return "Balanced compression (~75% quality). Greatly reduces file size with imperceptible quality loss."
        case .high:
            return "Maximum compression (~55% quality). Maximizes storage savings, ideal for fast sharing or email."
        }
    }
    
    /// SF Symbol icon representation for the strength tier.
    public var iconName: String {
        switch self {
        case .low:
            return "gauge.with.dots.needle.33percent"
        case .medium:
            return "gauge.with.dots.needle.67percent"
        case .high:
            return "gauge.with.dots.needle.100percent"
        }
    }
}

/// Type alias for backward compatibility and semantic clarity across components.
public typealias CompressionQuality = CompressionStrength
