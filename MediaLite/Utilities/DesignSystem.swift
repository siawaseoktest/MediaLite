//
//  DesignSystem.swift
//  MediaLite
//
//  Created for MediaLite Milestone 1.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Apple-native Liquid Glass design tokens, color palettes, spacing metrics, and view modifiers.
public enum DesignSystem {
    
    // MARK: - Spacing & Corner Metrics
    public enum Metrics {
        public static let standardCornerRadius: CGFloat = 18.0
        public static let cardCornerRadius: CGFloat = 18.0
        public static let buttonCornerRadius: CGFloat = 14.0
        public static let badgeCornerRadius: CGFloat = 8.0
        
        public static let paddingSmall: CGFloat = 8.0
        public static let paddingMedium: CGFloat = 16.0
        public static let paddingLarge: CGFloat = 24.0
        public static let cardPadding: CGFloat = 18.0
        
        public static let borderDefaultOpacity: Double = 0.15
        public static let shadowRadius: CGFloat = 10.0
        public static let shadowYOffset: CGFloat = 4.0
    }
    
    // MARK: - Color Palette
    public enum Colors {
        /// Primary accent tint (system blue / accentColor).
        public static let accent = Color.accentColor
        
        /// Monochrome neutral foregrounds.
        public static let primaryText = Color.primary
        public static let secondaryText = Color.secondary
        
        /// Positive savings tint (system green).
        public static let savingsGreen = Color.green
        
        /// Size increase warning tint (system orange).
        public static let increaseWarning = Color.orange
        
        /// Catch-light gradient highlight (top-left edge specular catch light).
        public static let catchLightHighlight = Color.white.opacity(0.35)
        
        /// Catch-light gradient shadow (bottom-right edge subtle shadow).
        public static let catchLightShadow = Color.black.opacity(0.12)
        
        /// Fallback solid background used when Reduce Transparency is enabled.
        public static let opaqueCardBackgroundLight = Color(UIColor.secondarySystemBackground)
    }
    
    // MARK: - Typography & Scalable Tokens
    public enum Fonts {
        public static let largeTitle = Font.system(.largeTitle, design: .default, weight: .bold)
        public static let title = Font.system(.title2, design: .default, weight: .semibold)
        public static let headline = Font.system(.headline, design: .default, weight: .semibold)
        public static let body = Font.system(.body, design: .default, weight: .regular)
        public static let subheadline = Font.system(.subheadline, design: .default, weight: .regular)
        public static let caption = Font.system(.caption, design: .default, weight: .medium)
        public static let statNumber = Font.system(.title, design: .rounded, weight: .bold)
    }
}

// MARK: - Liquid Glass Card View Modifier

/// Applies Apple-native Liquid Glass card styling with translucent material, continuous corner radius,
/// specular catch-light borders, and accessibility adaptations (Reduce Motion & Reduce Transparency).
public struct LiquidGlassCardModifier: ViewModifier {
    
    public var cornerRadius: CGFloat
    public var borderOpacity: Double
    
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    
    public init(
        cornerRadius: CGFloat = DesignSystem.Metrics.cardCornerRadius,
        borderOpacity: Double = DesignSystem.Metrics.borderDefaultOpacity
    ) {
        self.cornerRadius = cornerRadius
        self.borderOpacity = borderOpacity
    }
    
    public func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    // Fallback to opaque background for accessibility
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(UIColor.systemBackground))
                } else {
                    // Apple Liquid Glass ultra-thin material
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // Specular catch-light border: light highlight from top-left to subtle shadow at bottom-right
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: DesignSystem.Colors.catchLightHighlight.opacity(borderOpacity * 2.0), location: 0.0),
                                .init(color: DesignSystem.Colors.catchLightHighlight.opacity(borderOpacity * 0.5), location: 0.4),
                                .init(color: DesignSystem.Colors.catchLightShadow.opacity(borderOpacity), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                radius: DesignSystem.Metrics.shadowRadius,
                x: 0,
                y: DesignSystem.Metrics.shadowYOffset
            )
    }
}

// MARK: - View Extension

public extension View {
    /// Wraps the view in an Apple Liquid Glass translucent card with continuous corners and specular catch-light.
    func liquidGlassCard(
        cornerRadius: CGFloat = DesignSystem.Metrics.cardCornerRadius,
        borderOpacity: Double = DesignSystem.Metrics.borderDefaultOpacity
    ) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, borderOpacity: borderOpacity))
    }
    
    /// Conditionally disables animations when Reduce Motion is enabled.
    @ViewBuilder
    func motionSafeAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        self.transaction { transaction in
            if UIAccessibility.isReduceMotionEnabled {
                transaction.animation = nil
            } else {
                transaction.animation = animation
            }
        }
    }
}
