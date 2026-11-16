//
//  Formatters.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import Foundation

/// Centralized formatting utilities for byte counts, time durations, percentages, and timestamps.
public enum Formatters {
    
    // MARK: - Byte Formatting
    
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
    
    /// Formats a byte count into a localized human-readable string (e.g. "1.2 MB", "450 KB").
    public static func formatBytes(_ bytes: Int64) -> String {
        guard bytes >= 0 else {
            // Handle negative values with explicit minus sign (safeguard Int64.min against arithmetic overflow)
            if bytes == Int64.min {
                return "-" + byteCountFormatter.string(fromByteCount: Int64.max)
            }
            return "-" + byteCountFormatter.string(fromByteCount: abs(bytes))
        }
        return byteCountFormatter.string(fromByteCount: bytes)
    }
    
    // MARK: - Duration Formatting
    
    private static let durationComponentsFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        formatter.allowedUnits = [.minute, .second]
        return formatter
    }()
    
    private static let longDurationComponentsFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter
    }()
    
    /// Formats a duration in seconds to "MM:SS" (or "HH:MM:SS" if >= 1 hour).
    public static func formatDuration(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else {
            return "00:00"
        }
        
        let roundedSeconds = max(0, seconds.rounded())
        if roundedSeconds >= 3600 {
            return longDurationComponentsFormatter.string(from: roundedSeconds) ?? "00:00:00"
        } else {
            return durationComponentsFormatter.string(from: roundedSeconds) ?? "00:00"
        }
    }
    
    // MARK: - Percentage Formatting
    
    private static let percentageFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "-" // Reduction is shown as -X% (e.g. -45.2%)
        formatter.negativePrefix = "+" // Size increase is shown as +X% (e.g. +12.5%)
        return formatter
    }()
    
    /// Formats a reduction percentage.
    /// - Parameters:
    ///   - percentage: The percentage value (e.g., 45.2 for 45.2% reduction, or -15.0 for 15% increase).
    ///   - isSizeIncreased: Whether the file size actually increased.
    /// - Returns: Localized string, e.g. "-45.2%", "+15.0%", or "0.0%".
    public static func formatPercentage(reductionPercentage: Double, isSizeIncreased: Bool = false) -> String {
        guard !reductionPercentage.isNaN && !reductionPercentage.isInfinite else {
            return "0.0%"
        }
        
        if abs(reductionPercentage) < 0.05 {
            return "0.0%"
        }
        
        if isSizeIncreased || reductionPercentage < 0 {
            let magnitude = abs(reductionPercentage)
            return String(format: "+%.1f%%", magnitude)
        } else {
            let magnitude = abs(reductionPercentage)
            return String(format: "-%.1f%%", magnitude)
        }
    }
    
    /// Formats savings for UI badges (e.g. "Saved 2.4 MB (-45%)" or "Increased by 500 KB (+10%)").
    public static func formatSavingsSummary(originalSize: Int64, compressedSize: Int64) -> String {
        let delta = originalSize - compressedSize
        if delta > 0 {
            let savedBytes = formatBytes(delta)
            let percentage = (Double(delta) / Double(max(1, originalSize))) * 100.0
            return "Saved \(savedBytes) (-\(String(format: "%.1f", percentage))%)"
        } else if delta < 0 {
            let increasedBytes = formatBytes(abs(delta))
            let percentage = (Double(abs(delta)) / Double(max(1, originalSize))) * 100.0
            return "Increased by \(increasedBytes) (+\(String(format: "%.1f", percentage))%)"
        } else {
            return "No size change"
        }
    }
    
    // MARK: - Date Formatting
    
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    
    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    
    /// Formats date for history display (e.g. "Today, 3:45 PM" or "Nov 15, 2026, 4:20 PM").
    public static func formatDate(_ date: Date) -> String {
        return historyDateFormatter.string(from: date)
    }
    
    /// Formats date relative to now (e.g. "2 hours ago", "yesterday").
    public static func formatRelativeDate(_ date: Date) -> String {
        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}
