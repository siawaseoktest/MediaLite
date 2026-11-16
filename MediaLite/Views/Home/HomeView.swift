//
//  HomeView.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  Home Dashboard view featuring the Lifetime Savings Hero Card,
//  Quick Action buttons, and Recent Activity list.
//

import SwiftUI

@MainActor
public struct HomeView: View {
    @StateObject public var viewModel: HomeViewModel
    @Binding public var selectedTab: AppTab
    
    public init(viewModel: HomeViewModel? = nil, selectedTab: Binding<AppTab> = .constant(.home)) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? HomeViewModel())
        self._selectedTab = selectedTab
    }
    
    public init(viewModel: HomeViewModel? = nil, selectedTabInt: Binding<Int>) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? HomeViewModel())
        self._selectedTab = Binding(
            get: { AppTab(rawValue: selectedTabInt.wrappedValue) ?? .home },
            set: { selectedTabInt.wrappedValue = $0.rawValue }
        )
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 1. Lifetime Savings Hero Card
                    heroCard
                    
                    // 2. Quick Actions
                    quickActionsSection
                    
                    // 3. Recent Activity Section
                    recentActivitySection
                }
                .padding(.horizontal, DesignSystem.Metrics.paddingMedium)
                .padding(.top, DesignSystem.Metrics.paddingSmall)
                .padding(.bottom, DesignSystem.Metrics.paddingLarge)
            }
            .navigationTitle("MediaLite")
            .task {
                await viewModel.loadDashboardData()
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
    }
    
    // MARK: - Hero Card
    
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIFETIME SAVINGS")
                        .font(DesignSystem.Fonts.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                    
                    Text(Formatters.formatBytes(viewModel.stats.totalSavedBytes))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                }
                
                Spacer()
                
                SavingsBadge(
                    reductionPercentage: viewModel.stats.reductionPercentage,
                    isSizeIncreased: false,
                    style: .compact
                )
            }
            
            Divider()
                .opacity(0.3)
            
            // 2-Metric Summary Grid
            HStack(spacing: 12) {
                StatMetricView(
                    title: "Photos",
                    value: "\(viewModel.stats.photoCount)",
                    systemImage: "photo.fill",
                    tintColor: DesignSystem.Colors.accent
                )
                
                StatMetricView(
                    title: "Videos",
                    value: "\(viewModel.stats.videoCount)",
                    systemImage: "video.fill",
                    tintColor: DesignSystem.Colors.accent
                )
            }
        }
        .padding(DesignSystem.Metrics.cardPadding)
        .liquidGlassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home_hero_card")
    }
    
    // MARK: - Quick Actions Section
    
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(DesignSystem.Fonts.headline)
                .foregroundStyle(DesignSystem.Colors.primaryText)
            
            HStack(spacing: 12) {
                Button {
                    selectedTab = .compress
                } label: {
                    HStack {
                        Image(systemName: "photo.stack.fill")
                            .font(.title3)
                            .foregroundStyle(DesignSystem.Colors.accent)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Compress")
                                .font(DesignSystem.Fonts.headline)
                                .foregroundStyle(DesignSystem.Colors.primaryText)
                            Text("Photos & Images")
                                .font(DesignSystem.Fonts.caption)
                                .foregroundStyle(DesignSystem.Colors.secondaryText)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.subheadline.bold())
                            .foregroundStyle(DesignSystem.Colors.secondaryText.opacity(0.6))
                    }
                    .padding(DesignSystem.Metrics.paddingMedium)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .liquidGlassCard(cornerRadius: DesignSystem.Metrics.buttonCornerRadius)
                }
                .accessibilityIdentifier("action_compress_photos")
                
                Button {
                    selectedTab = .convert
                } label: {
                    HStack {
                        Image(systemName: "video.badge.plus")
                            .font(.title3)
                            .foregroundStyle(DesignSystem.Colors.accent)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Convert")
                                .font(DesignSystem.Fonts.headline)
                                .foregroundStyle(DesignSystem.Colors.primaryText)
                            Text("Videos & MP4")
                                .font(DesignSystem.Fonts.caption)
                                .foregroundStyle(DesignSystem.Colors.secondaryText)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.subheadline.bold())
                            .foregroundStyle(DesignSystem.Colors.secondaryText.opacity(0.6))
                    }
                    .padding(DesignSystem.Metrics.paddingMedium)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .liquidGlassCard(cornerRadius: DesignSystem.Metrics.buttonCornerRadius)
                }
                .accessibilityIdentifier("action_convert_videos")
            }
        }
    }
    
    // MARK: - Recent Activity Section
    
    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Activity")
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Spacer()
                
                if !viewModel.recentItems.isEmpty {
                    Button("See All") {
                        selectedTab = .history
                    }
                    .font(DesignSystem.Fonts.subheadline)
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .accessibilityIdentifier("home_see_all_history")
                }
            }
            
            if viewModel.recentItems.isEmpty {
                emptyRecentActivityCard
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.recentItems) { item in
                        recentActivityRow(for: item)
                    }
                }
            }
        }
    }
    
    private var emptyRecentActivityCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(DesignSystem.Colors.accent)
            
            Text("No Media Processed Yet")
                .font(DesignSystem.Fonts.headline)
                .foregroundStyle(DesignSystem.Colors.primaryText)
            
            Text("Compress photos or convert videos to see lifetime savings and processing history here.")
                .font(DesignSystem.Fonts.subheadline)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Metrics.cardPadding)
        .liquidGlassCard()
        .accessibilityIdentifier("empty_recent_activity_card")
    }
    
    private func recentActivityRow(for item: CompressionHistoryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.mediaType.lowercased() == "photo" ? "photo.fill" : "video.fill")
                .font(.title3)
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                    .lineLimit(1)
                
                Text("\(Formatters.formatBytes(item.originalByteSize)) → \(Formatters.formatBytes(item.compressedByteSize)) • \(Formatters.formatRelativeDate(item.timestamp))")
                    .font(DesignSystem.Fonts.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .lineLimit(1)
            }
            
            Spacer()
            
            SavingsBadge(
                reductionPercentage: item.reductionPercentage,
                isSizeIncreased: item.isSizeIncreased,
                style: .compact
            )
        }
        .padding(DesignSystem.Metrics.paddingMedium)
        .liquidGlassCard(cornerRadius: DesignSystem.Metrics.buttonCornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recent_item_\(item.id.uuidString)")
    }
}
