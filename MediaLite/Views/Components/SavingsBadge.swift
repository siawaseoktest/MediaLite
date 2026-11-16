//
//  SavingsBadge.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  Status and reduction badge with color-coding, animated scale/fade,
//  motion suppression, and full VoiceOver accessibility descriptions.
//

import SwiftUI

/// Display style variations for SavingsBadge.
public enum SavingsBadgeStyle: Sendable {
    /// Shows reduction percentage only (e.g. "-65.0%").
    case percentageOnly
    /// Shows compact format with icon and percentage (e.g. "↓ 65.0%").
    case compact
    /// Shows detailed badge with icon, percentage, and byte savings (e.g. "↓ 65.0% (2.4 MB)").
    case detailed
}

/// An Apple-native status and savings badge with color-coding, animated scale/fade,
/// and full VoiceOver accessibility descriptions.
public struct SavingsBadge: View {
    public let reductionPercentage: Double
    public let isSizeIncreased: Bool
    public var byteDelta: Int64?
    public var style: SavingsBadgeStyle
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 10.0
    @ScaledMetric(relativeTo: .caption) private var horizontalPadding: CGFloat = 8.0
    @ScaledMetric(relativeTo: .caption) private var verticalPadding: CGFloat = 4.0
    
    public init(
        reductionPercentage: Double,
        isSizeIncreased: Bool = false,
        byteDelta: Int64? = nil,
        style: SavingsBadgeStyle = .percentageOnly
    ) {
        self.reductionPercentage = reductionPercentage
        self.isSizeIncreased = isSizeIncreased || reductionPercentage < -0.05
        self.byteDelta = byteDelta
        self.style = style
    }
    
    public init(
        percentage: Double,
        byteDelta: Int64,
        isSizeIncreased: Bool = false,
        style: SavingsBadgeStyle = .compact
    ) {
        self.init(
            reductionPercentage: percentage,
            isSizeIncreased: isSizeIncreased,
            byteDelta: byteDelta,
            style: style
        )
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            if style != .percentageOnly {
                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .bold))
            }
            
            Text(formattedText)
                .font(DesignSystem.Fonts.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .foregroundStyle(tintColor)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Metrics.badgeCornerRadius, style: .continuous)
                .fill(tintColor.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Metrics.badgeCornerRadius, style: .continuous)
                .strokeBorder(tintColor.opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizedStringKey(accessibilityDescription))
        .accessibilityAddTraits(.isStaticText)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }
    
    public var isSignificantSavings: Bool {
        reductionPercentage >= 0.05 && !isSizeIncreased
    }
    
    public var isSignificantIncrease: Bool {
        isSizeIncreased || reductionPercentage <= -0.05
    }
    
    public var tintColor: Color {
        if isSignificantSavings {
            return DesignSystem.Colors.savingsGreen
        } else if isSignificantIncrease {
            return DesignSystem.Colors.increaseWarning
        } else {
            return DesignSystem.Colors.secondaryText
        }
    }
    
    public var iconName: String {
        if isSignificantSavings {
            return "arrow.down.right"
        } else if isSignificantIncrease {
            return "arrow.up.right"
        } else {
            return "minus"
        }
    }
    
    public var formattedText: String {
        let percentStr = Formatters.formatPercentage(
            reductionPercentage: reductionPercentage,
            isSizeIncreased: isSizeIncreased
        )
        
        switch style {
        case .percentageOnly, .compact:
            return percentStr
        case .detailed:
            if let byteDelta = byteDelta, byteDelta != 0 {
                let bytesStr = Formatters.formatBytes(abs(byteDelta))
                return "\(percentStr) (\(bytesStr))"
            }
            return percentStr
        }
    }
    
    public var accessibilityDescription: String {
        if isSignificantSavings {
            let magnitude = String(format: "%.1f", abs(reductionPercentage))
            if let byteDelta = byteDelta, byteDelta > 0 {
                let saved = Formatters.formatBytes(byteDelta)
                return "Saved \(saved), \(magnitude) percent reduction in file size"
            }
            return "\(magnitude) percent reduction in file size"
        } else if isSignificantIncrease {
            let magnitude = String(format: "%.1f", abs(reductionPercentage))
            if let byteDelta = byteDelta, byteDelta < 0 {
                let increased = Formatters.formatBytes(abs(byteDelta))
                return "File size increased by \(increased), \(magnitude) percent increase"
            }
            return "\(magnitude) percent increase in file size"
        } else {
            return "No change in file size"
        }
    }
}
