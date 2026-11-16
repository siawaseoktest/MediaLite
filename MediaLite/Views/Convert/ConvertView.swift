//
//  ConvertView.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  Convert Tab view featuring video selection, inspector card,
//  mode selection, live progress, and AVPlayer preview.
//

import SwiftUI
import PhotosUI
import AVKit

public struct ConvertView: View {
    @StateObject public var viewModel: ConvertViewModel
    
    public init(viewModel: ConvertViewModel = ConvertViewModel()) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.isCompleted {
                        // Results State with AVPlayer
                        resultsView
                    } else if viewModel.isConverting {
                        // Conversion In Progress State
                        convertingView
                    } else if viewModel.selectedVideoURL != nil {
                        // Video Inspected & Ready for Configuration State
                        configurationView
                    } else {
                        // Empty Selection State
                        videoPickerDropZone
                    }
                }
                .padding(.horizontal, DesignSystem.Metrics.paddingMedium)
                .padding(.top, DesignSystem.Metrics.paddingSmall)
                .padding(.bottom, DesignSystem.Metrics.paddingLarge)
            }
            .navigationTitle("Convert")
            .alert("Error", isPresented: $viewModel.showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "An unknown error occurred.")
            }
        }
    }
    
    // MARK: - Video Picker Drop Zone
    
    private var videoPickerDropZone: some View {
        PhotosPicker(
            selection: $viewModel.selectedPickerItem,
            matching: .videos
        ) {
            VStack(spacing: 14) {
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(DesignSystem.Colors.accent)
                
                Text("Select Video to Convert")
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Text("Supports MOV, MP4, and HDR videos.\nReduce size or transcode to universal H.264/MP4.")
                    .font(DesignSystem.Fonts.subheadline)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, DesignSystem.Metrics.cardPadding)
            .liquidGlassCard()
        }
        .accessibilityIdentifier("video_picker_button")
    }
    
    // MARK: - Configuration View
    
    private var configurationView: some View {
        VStack(spacing: 20) {
            // Video Inspector Card
            inspectorCard
            
            // Mode Selector
            modeSelectorSection
            
            // Strength Selector
            strengthSelectorSection
            
            // Action Button
            Button {
                viewModel.startConversion()
            } label: {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("Start Video Conversion")
                        .font(DesignSystem.Fonts.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(DesignSystem.Metrics.paddingMedium)
                .background(DesignSystem.Colors.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Metrics.buttonCornerRadius, style: .continuous))
            }
            .accessibilityIdentifier("button_start_conversion")
        }
    }
    
    // MARK: - Inspector Card
    
    private var inspectorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.sourceFileName)
                        .font(DesignSystem.Fonts.headline)
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                        .lineLimit(1)
                    
                    Text("Original Size: \(Formatters.formatBytes(viewModel.sourceFileSize))")
                        .font(DesignSystem.Fonts.caption)
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                }
                
                Spacer()
                
                Button("Change") {
                    viewModel.resetSelection()
                }
                .font(DesignSystem.Fonts.subheadline)
                .foregroundStyle(DesignSystem.Colors.accent)
                .accessibilityIdentifier("button_change_video")
            }
            
            Divider().opacity(0.3)
            
            if let meta = viewModel.videoMetadata {
                HStack(spacing: 12) {
                    StatMetricView(
                        title: "Duration",
                        value: Formatters.formatDuration(meta.duration),
                        systemImage: "clock.fill",
                        tintColor: .orange
                    )
                    
                    StatMetricView(
                        title: "Resolution",
                        value: "\(Int(meta.naturalSize.width))×\(Int(meta.naturalSize.height))",
                        systemImage: "tv.fill",
                        tintColor: .blue
                    )
                    
                    StatMetricView(
                        title: "HDR",
                        value: meta.isHDR ? "Yes" : "SDR",
                        systemImage: meta.isHDR ? "sun.max.fill" : "sun.min.fill",
                        tintColor: meta.isHDR ? .yellow : .gray
                    )
                }
            }
        }
        .padding(DesignSystem.Metrics.cardPadding)
        .liquidGlassCard()
        .accessibilityIdentifier("video_inspector_card")
    }
    
    // MARK: - Mode Selector Section
    
    private var modeSelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversion Mode")
                .font(DesignSystem.Fonts.headline)
                .foregroundStyle(DesignSystem.Colors.primaryText)
            
            VStack(spacing: 8) {
                ForEach(VideoProcessingMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.selectedMode = mode
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.iconName)
                                .font(.title3)
                                .foregroundStyle(viewModel.selectedMode == mode ? DesignSystem.Colors.accent : DesignSystem.Colors.secondaryText)
                                .frame(width: 28)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title)
                                    .font(DesignSystem.Fonts.headline)
                                    .foregroundStyle(DesignSystem.Colors.primaryText)
                                
                                Text(mode.localizedDescription)
                                    .font(DesignSystem.Fonts.caption)
                                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                                    .multilineTextAlignment(.leading)
                            }
                            
                            Spacer()
                            
                            if viewModel.selectedMode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DesignSystem.Colors.accent)
                            }
                        }
                        .padding(DesignSystem.Metrics.paddingMedium)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Metrics.buttonCornerRadius, style: .continuous)
                                .fill(viewModel.selectedMode == mode ? DesignSystem.Colors.accent.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Metrics.buttonCornerRadius, style: .continuous)
                                .stroke(viewModel.selectedMode == mode ? DesignSystem.Colors.accent.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                    .accessibilityIdentifier("mode_\(mode.rawValue)")
                }
            }
        }
        .padding(DesignSystem.Metrics.cardPadding)
        .liquidGlassCard()
    }
    
    // MARK: - Strength Selector Section
    
    private var strengthSelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compression Strength")
                .font(DesignSystem.Fonts.headline)
                .foregroundStyle(DesignSystem.Colors.primaryText)
            
            Picker("Strength", selection: $viewModel.selectedStrength) {
                ForEach(CompressionStrength.allCases, id: \.self) { strength in
                    Text(strength.displayName).tag(strength)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("picker_video_strength")
            
            Text(viewModel.selectedStrength.localizedDescription)
                .font(DesignSystem.Fonts.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .padding(.horizontal, 4)
        }
        .padding(DesignSystem.Metrics.cardPadding)
        .liquidGlassCard()
    }
    
    // MARK: - Converting View
    
    private var convertingView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                ProgressView(value: viewModel.conversionProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(DesignSystem.Colors.accent)
                
                HStack {
                    Text(viewModel.progressDescription)
                        .font(DesignSystem.Fonts.caption)
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                    
                    Spacer()
                    
                    Text("\(Int(viewModel.conversionProgress * 100))%")
                        .font(DesignSystem.Fonts.caption)
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                }
            }
            .padding(DesignSystem.Metrics.cardPadding)
            .liquidGlassCard()
            
            Button("Cancel Conversion") {
                viewModel.cancelConversion()
            }
            .font(DesignSystem.Fonts.headline)
            .foregroundStyle(.red)
            .accessibilityIdentifier("button_cancel_video_conversion")
        }
        .padding(.vertical, 30)
    }
    
    // MARK: - Results View
    
    private var resultsView: some View {
        VStack(spacing: 20) {
            // Video Player
            if let player = viewModel.avPlayer {
                VideoPlayer(player: player)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Metrics.cardCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Metrics.cardCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .accessibilityIdentifier("video_player_preview")
            }
            
            // Savings Card
            if let result = viewModel.conversionResult {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CONVERSION COMPLETE")
                                .font(DesignSystem.Fonts.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(DesignSystem.Colors.secondaryText)
                            
                            Text(Formatters.formatBytes(result.byteDelta))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(result.isSizeIncreased ? DesignSystem.Colors.increaseWarning : DesignSystem.Colors.savingsGreen)
                        }
                        
                        Spacer()
                        
                        SavingsBadge(
                            reductionPercentage: result.reductionPercentage,
                            isSizeIncreased: result.isSizeIncreased,
                            style: .compact
                        )
                    }
                    
                    Divider().opacity(0.3)
                    
                    Text(Formatters.formatSavingsSummary(
                        originalSize: result.originalSize,
                        compressedSize: result.processedSize
                    ))
                    .font(DesignSystem.Fonts.subheadline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                }
                .padding(DesignSystem.Metrics.cardPadding)
                .liquidGlassCard()
                .accessibilityIdentifier("video_results_card")
            }
            
            // Action Buttons
            VStack(spacing: 12) {
                Button {
                    Task {
                        await viewModel.saveToPhotoLibrary()
                    }
                } label: {
                    HStack {
                        Image(systemName: viewModel.isSavedToLibrary ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                        Text(viewModel.isSavedToLibrary ? "Saved to Photos" : "Save Video to Photo Library")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DesignSystem.Metrics.paddingMedium)
                    .background(viewModel.isSavedToLibrary ? Color.green : DesignSystem.Colors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Metrics.buttonCornerRadius, style: .continuous))
                }
                .disabled(viewModel.isSavedToLibrary)
                .accessibilityIdentifier("button_save_video")
                
                Button("Convert Another Video") {
                    viewModel.resetSelection()
                }
                .font(DesignSystem.Fonts.headline)
                .foregroundStyle(DesignSystem.Colors.accent)
                .padding(.top, 4)
                .accessibilityIdentifier("button_reset_video")
            }
        }
    }
}
