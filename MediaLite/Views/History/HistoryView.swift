//
//  HistoryView.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  History Tab view presenting categorized processing history,
//  dynamic aggregate statistics, swipe deletion, and clear all.
//

import SwiftUI

@MainActor
public struct HistoryView: View {
    @StateObject public var viewModel: HistoryViewModel
    
    public init(viewModel: HistoryViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? HistoryViewModel())
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter Segmented Control
                filterBar
                    .padding(.horizontal, DesignSystem.Metrics.paddingMedium)
                    .padding(.top, DesignSystem.Metrics.paddingSmall)
                    .padding(.bottom, DesignSystem.Metrics.paddingSmall)
                
                // Aggregate Stats Banner
                statsBanner
                    .padding(.horizontal, DesignSystem.Metrics.paddingMedium)
                    .padding(.bottom, DesignSystem.Metrics.paddingSmall)
                
                // History Items List or Empty State
                if viewModel.filteredItems.isEmpty {
                    emptyStateView
                } else {
                    itemsList
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        viewModel.showClearAllConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.allItems.isEmpty)
                    .accessibilityIdentifier("button_clear_all_history")
                }
            }
            .confirmationDialog(
                "Clear All History",
                isPresented: $viewModel.showClearAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    Task {
                        await viewModel.clearAllHistory()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action permanently removes all compression records from your local history archive. Original and processed media files will not be deleted.")
            }
            .task {
                await viewModel.loadHistory()
            }
            .refreshable {
                await viewModel.loadHistory()
            }
        }
    }
    
    // MARK: - Filter Bar
    
    private var filterBar: some View {
        Picker("History Category", selection: $viewModel.selectedFilter) {
            ForEach(HistoryFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("history_filter_picker")
    }
    
    // MARK: - Stats Banner
    
    private var statsBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.filteredItems.count) item\(viewModel.filteredItems.count == 1 ? "" : "s")")
                    .font(DesignSystem.Fonts.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                
                Text(Formatters.formatBytes(viewModel.filteredStats.totalSavedBytes) + " saved")
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
            }
            
            Spacer()
            
            SavingsBadge(
                reductionPercentage: viewModel.filteredStats.reductionPercentage,
                isSizeIncreased: false,
                style: .compact
            )
        }
        .padding(.horizontal, DesignSystem.Metrics.paddingMedium)
        .padding(.vertical, DesignSystem.Metrics.paddingSmall)
        .liquidGlassCard(cornerRadius: DesignSystem.Metrics.buttonCornerRadius)
        .accessibilityIdentifier("history_stats_banner")
    }
    
    // MARK: - Items List
    
    private var itemsList: some View {
        List {
            ForEach(viewModel.filteredItems) { item in
                historyRow(for: item)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task {
                                await viewModel.deleteItem(id: item.id)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
    }
    
    private func historyRow(for item: CompressionHistoryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.mediaType.lowercased() == "photo" ? "photo.fill" : "video.fill")
                .font(.title3)
                .foregroundStyle(item.mediaType.lowercased() == "photo" ? Color.blue : Color.indigo)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(item.mediaType.lowercased() == "photo" ? Color.blue.opacity(0.12) : Color.indigo.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.fileName)
                        .font(DesignSystem.Fonts.headline)
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                        .lineLimit(1)
                    
                    if item.isSavedToLibrary {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                
                Text("\(Formatters.formatBytes(item.originalByteSize)) → \(Formatters.formatBytes(item.compressedByteSize))")
                    .font(DesignSystem.Fonts.caption)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Text("\(item.sourceFormat) → \(item.targetFormat) • \(Formatters.formatRelativeDate(item.timestamp))")
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
        .accessibilityIdentifier("history_row_\(item.id.uuidString)")
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer()
            
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 44))
                .foregroundStyle(DesignSystem.Colors.secondaryText)
            
            Text("No History Found")
                .font(DesignSystem.Fonts.headline)
                .foregroundStyle(DesignSystem.Colors.primaryText)
            
            Text(viewModel.selectedFilter == .all
                 ? "No media files have been compressed or converted yet."
                 : "No \(viewModel.selectedFilter.rawValue.lowercased()) have been processed yet.")
                .font(DesignSystem.Fonts.subheadline)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
        .padding(DesignSystem.Metrics.cardPadding)
        .accessibilityIdentifier("history_empty_state")
    }
}
