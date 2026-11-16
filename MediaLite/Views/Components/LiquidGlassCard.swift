//
//  LiquidGlassCard.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  Apple Liquid Glass translucent card component with continuous corners,
//  specular catch-light gradient borders, ambient drop shadows, and full
//  accessibility adaptations (Reduce Transparency fallback & Reduce Motion).
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Translucent material variants for Liquid Glass surfaces.
public enum LiquidGlassMaterialStyle: Sendable {
    case ultraThin
    case thin
    case regular
    case thick
    
    public var material: Material {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        }
    }
}

/// A container view providing Apple-native Liquid Glass card styling.
public struct LiquidGlassCard<Content: View>: View {
    public var cornerRadius: CGFloat
    public var materialStyle: LiquidGlassMaterialStyle
    public var borderOpacity: Double
    public var contentPadding: CGFloat
    public let content: Content
    
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    
    public init(
        cornerRadius: CGFloat = DesignSystem.Metrics.cardCornerRadius,
        materialStyle: LiquidGlassMaterialStyle = .ultraThin,
        borderOpacity: Double = DesignSystem.Metrics.borderDefaultOpacity,
        contentPadding: CGFloat = DesignSystem.Metrics.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.materialStyle = materialStyle
        self.borderOpacity = borderOpacity
        self.contentPadding = contentPadding
        self.content = content()
    }
    
    public var body: some View {
        content
            .padding(contentPadding)
            .background {
                backgroundShape
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                specularCatchLightBorder
            }
            .shadow(
                color: shadowColor,
                radius: DesignSystem.Metrics.shadowRadius,
                x: 0,
                y: DesignSystem.Metrics.shadowYOffset
            )
    }
    
    @ViewBuilder
    private var backgroundShape: some View {
        if reduceTransparency {
            // High-contrast opaque fallback for accessibility
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color(UIColor.secondarySystemBackground)
                      : Color(UIColor.systemBackground))
        } else {
            // Apple Liquid Glass translucent material
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(materialStyle.material)
        }
    }
    
    private var specularCatchLightBorder: some View {
        let highlightMultiplier = colorScheme == .dark ? 2.4 : 1.8
        let shadowMultiplier = colorScheme == .dark ? 1.2 : 0.8
        
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(
                            color: DesignSystem.Colors.catchLightHighlight.opacity(borderOpacity * highlightMultiplier),
                            location: 0.0
                        ),
                        .init(
                            color: DesignSystem.Colors.catchLightHighlight.opacity(borderOpacity * 0.4),
                            location: 0.35
                        ),
                        .init(
                            color: DesignSystem.Colors.catchLightShadow.opacity(borderOpacity * shadowMultiplier),
                            location: 1.0
                        )
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
    }
    
    private var shadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.28)
        } else {
            return Color.black.opacity(0.06)
        }
    }
}

// MARK: - View Modifiers & Extensions

public struct LiquidGlassViewModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var materialStyle: LiquidGlassMaterialStyle
    public var borderOpacity: Double
    public var contentPadding: CGFloat
    
    public func body(content: Content) -> some View {
        LiquidGlassCard(
            cornerRadius: cornerRadius,
            materialStyle: materialStyle,
            borderOpacity: borderOpacity,
            contentPadding: contentPadding
        ) {
            content
        }
    }
}

public extension View {
    /// Wraps the view inside a LiquidGlassCard with specified styling.
    func liquidGlass(
        cornerRadius: CGFloat = DesignSystem.Metrics.cardCornerRadius,
        materialStyle: LiquidGlassMaterialStyle = .ultraThin,
        borderOpacity: Double = DesignSystem.Metrics.borderDefaultOpacity,
        contentPadding: CGFloat = DesignSystem.Metrics.cardPadding
    ) -> some View {
        modifier(
            LiquidGlassViewModifier(
                cornerRadius: cornerRadius,
                materialStyle: materialStyle,
                borderOpacity: borderOpacity,
                contentPadding: contentPadding
            )
        )
    }
}
