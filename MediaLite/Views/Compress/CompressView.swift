//
//  CompressView.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  Compress Tab view implementing multi-photo selection, quality control,
//  live batch progress, and result inspection.
//

import SwiftUI
import PhotosUI

@MainActor
public struct CompressView: View {
    @StateObject public var viewModel: CompressViewModel
    
    public init(viewModel: CompressViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? CompressViewModel())
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.isCompleted {
                        // Results State
                        resultsView
                    } else if viewModel.isProcessing {
                        // Processing State
                        processingView
                    } else {
                        // Configuration & Selection State
                        configurationView
                    }
                }
                .padding(.horizontal, DesignSystem.Metrics.paddingMedium)
                .padding(.top, DesignSystem.Metrics.paddingSmall)
                .padding(.bottom, DesignSystem.Metrics.paddingLarge)
            }
            .navigationTitle("Compress")
            .alert("Error", isPresented: $viewModel.showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "An unknown error occurred.")
            }
            .onAppear {
                viewModel.syncWithDefaultSettingsIfIdle()
            }
        }
    }
    
    // MARK: - Configuration & Selection View
    
    private var configurationView: some View {
        VStack(spacing: 20) {
            // Quality Selector
            qualitySelectorSection
            
            // Photo Picker Drop Zone
            if viewModel.selectedItems.isEmpty {
                photoPickerDropZone
            } else {
                selectedItemsSection
            }
            
            // Compress Action Button
            if !viewModel.selectedItems.isEmpty {
                Button {
                    viewModel.startCompression()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.headline)
                        Text("Compress \(viewModel.selectedItems.count) Photos")
                            .font(DesignSystem.Fonts.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DesignSystem.Metrics.paddingMedium)
                    .background(DesignSystem.Colors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Metrics.buttonCornerRadius, style: .continuous))
                }
                .accessibilityIdentifier("button_start_compression")
            }
        }
    }
    
    // MARK: - Quality Selector Section
    
    private var qualitySelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Photo Quality")
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Spacer()
                
                Picker("Photo Quality", selection: $viewModel.selectedQuality) {
                    ForEach(CompressionStrength.allCases, id: \.self) { strength in
                        Text(LocalizedStringKey(strength.displayName)).tag(strength)
                    }
                }
                .pickerStyle(.menu)
                .tint(DesignSystem.Colors.accent)
                .onChange(of: viewModel.selectedQuality) { _, _ in
                    viewModel.hasUserCustomizedQuality = true
                }
                .accessibilityIdentifier("picker_compression_quality")
            }
            
            Text(LocalizedStringKey(viewModel.selectedQuality.localizedDescription))
                .font(DesignSystem.Fonts.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .padding(.horizontal, 2)
        }
        .padding(DesignSystem.Metrics.cardPadding)
        .liquidGlassCard()
    }
    
    // MARK: - Photo Picker Drop Zone
    
    private var photoPickerDropZone: some View {
        PhotosPicker(
            selection: $viewModel.selectedPickerItems,
            maxSelectionCount: 0,
            matching: .images
        ) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                        .frame(width: 72, height: 72)
                    
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.accent)
                }
                
                Text("Select Photos to Compress")
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Text("Supports JPEG, HEIC, and PNG.\nSelect multiple photos for batch compression.")
                    .font(DesignSystem.Fonts.subheadline)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, DesignSystem.Metrics.cardPadding)
            .liquidGlassCard()
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Metrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        DesignSystem.Colors.accent.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            }
        }
        .accessibilityIdentifier("photos_picker_button")
    }
    
    // MARK: - Selected Items Section
    
    private var selectedItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected Photos (\(viewModel.selectedItems.count))")
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Spacer()
                
                PhotosPicker(
                    selection: $viewModel.selectedPickerItems,
                    maxSelectionCount: 0,
                    matching: .images
                ) {
                    Text("Add More")
                        .font(DesignSystem.Fonts.subheadline)
                        .foregroundStyle(DesignSystem.Colors.accent)
                }
                
                Button("Clear") {
                    viewModel.clearSelection()
                }
                .font(DesignSystem.Fonts.subheadline)
                .foregroundStyle(.red)
                .padding(.leading, 8)
                .accessibilityIdentifier("button_clear_photos")
            }
            
            VStack(spacing: 8) {
                ForEach(Array(viewModel.selectedItems.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        Image(systemName: "photo.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 32, height: 32)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.suggestedFileName)
                                .font(DesignSystem.Fonts.headline)
                                .foregroundStyle(DesignSystem.Colors.primaryText)
                                .lineLimit(1)
                            
                            Text("\(item.format.preferredFilenameExtension?.uppercased() ?? "IMAGE") • \(Formatters.formatBytes(item.byteSize))")
                                .font(DesignSystem.Fonts.caption)
                                .foregroundStyle(DesignSystem.Colors.secondaryText)
                        }
                        
                        Spacer()
                        
                        Button {
                            viewModel.removeItem(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DesignSystem.Colors.secondaryText)
                        }
                        .accessibilityIdentifier("remove_photo_\(index)")
                    }
                    .padding(DesignSystem.Metrics.paddingMedium)
                    .liquidGlassCard(cornerRadius: DesignSystem.Metrics.buttonCornerRadius)
                }
            }
        }
    }
    
    // MARK: - Processing View
    
    private var processingView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                ProgressView(value: viewModel.overallProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(DesignSystem.Colors.accent)
                
                HStack {
                    Text(viewModel.currentProcessingFileName)
                        .font(DesignSystem.Fonts.caption)
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text("\(Int(viewModel.overallProgress * 100))%")
                        .font(DesignSystem.Fonts.caption)
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                }
                
                Text("Compressing \(viewModel.currentProcessingIndex + 1) of \(viewModel.selectedItems.count)...")
                    .font(DesignSystem.Fonts.subheadline)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }
            .padding(DesignSystem.Metrics.cardPadding)
            .liquidGlassCard()
            
            Button("Cancel") {
                viewModel.cancelCompression()
            }
            .font(DesignSystem.Fonts.headline)
            .foregroundStyle(.red)
            .accessibilityIdentifier("button_cancel_compression")
        }
        .padding(.vertical, 30)
    }
    
    // MARK: - Results View
    
    private var resultsView: some View {
        VStack(spacing: 20) {
            // Savings Hero Card
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BATCH COMPRESSION COMPLETE")
                            .font(DesignSystem.Fonts.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(DesignSystem.Colors.secondaryText)
                        
                        Text(Formatters.formatBytes(viewModel.totalSavedBytes))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(viewModel.isSizeIncreased ? DesignSystem.Colors.increaseWarning : DesignSystem.Colors.savingsGreen)
                    }
                    
                    Spacer()
                    
                    SavingsBadge(
                        reductionPercentage: viewModel.totalReductionPercentage,
                        isSizeIncreased: viewModel.isSizeIncreased,
                        style: .compact
                    )
                }
                
                Divider().opacity(0.3)
                
                Text(Formatters.formatSavingsSummary(
                    originalSize: viewModel.totalOriginalSize,
                    compressedSize: viewModel.totalCompressedSize
                ))
                .font(DesignSystem.Fonts.subheadline)
                .foregroundStyle(DesignSystem.Colors.primaryText)
            }
            .padding(DesignSystem.Metrics.cardPadding)
            .liquidGlassCard()
            .accessibilityIdentifier("compression_results_card")
            
            // Action Buttons
            VStack(spacing: 12) {
                Button {
                    Task {
                        await viewModel.saveAllToLibrary()
                    }
                } label: {
                    HStack {
                        Image(systemName: viewModel.isSavedToLibrary ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                        Text(LocalizedStringKey(viewModel.isSavedToLibrary ? "Saved to Photos" : "Save All to Photo Library"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DesignSystem.Metrics.paddingMedium)
                    .background(viewModel.isSavedToLibrary ? Color.green : DesignSystem.Colors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Metrics.buttonCornerRadius, style: .continuous))
                }
                .disabled(viewModel.isSavedToLibrary)
                .accessibilityIdentifier("button_save_all_photos")
                
                Button("Done") {
                    viewModel.clearSelection()
                }
                .font(DesignSystem.Fonts.headline)
                .foregroundStyle(DesignSystem.Colors.accent)
                .padding(.top, 4)
                .accessibilityIdentifier("button_done_compression")
            }
        }
    }
}
