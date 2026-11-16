//
//  StatMetricView.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  A metric presentation card displaying a label, formatted numeric value,
//  optional icon, and optional savings badge. Fully conforms to Dynamic Type
//  and VoiceOver.
//

import SwiftUI

public struct StatMetricView: View {
    public let title: String
    public let value: String
    public var subtitle: String?
    public var iconName: String?
    public var iconColor: Color
    public var badge: SavingsBadge?
    
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 20.0
    
    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        iconName: String? = nil,
        iconColor: Color = DesignSystem.Colors.accent,
        badge: SavingsBadge? = nil
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.iconName = iconName
        self.iconColor = iconColor
        self.badge = badge
    }
    
    public init(
        title: String,
        value: String,
        systemImage: String,
        tintColor: Color = DesignSystem.Colors.accent
    ) {
        self.init(
            title: title,
            value: value,
            subtitle: nil,
            iconName: systemImage,
            iconColor: tintColor,
            badge: nil
        )
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: Icon + Title + Optional Badge
            HStack(spacing: 6) {
                if let iconName = iconName {
                    Image(systemName: iconName)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                }
                
                Text(LocalizedStringKey(title))
                    .font(DesignSystem.Fonts.subheadline)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                
                Spacer(minLength: 0)
                
                if let badge = badge {
                    badge
                }
            }
            
            // Primary Numeric Value
            Text(value)
                .font(DesignSystem.Fonts.statNumber)
                .foregroundStyle(DesignSystem.Colors.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            
            // Optional Subtitle
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(DesignSystem.Fonts.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Metrics.paddingMedium)
        .liquidGlassCard(cornerRadius: DesignSystem.Metrics.buttonCornerRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityCombinedValue)
        .accessibilityIdentifier("stat_metric_\(sanitizedIdentifier)")
    }
    
    public var accessibilityCombinedValue: String {
        var components: [String] = [value]
        if let subtitle = subtitle {
            components.append(subtitle)
        }
        return components.joined(separator: ", ")
    }
    
    public var sanitizedIdentifier: String {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}
