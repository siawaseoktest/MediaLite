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

@MainActor
public struct ConvertView: View {
    @StateObject public var viewModel: ConvertViewModel
    
    public init(viewModel: ConvertViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? ConvertViewModel())
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
            .onAppear {
                viewModel.syncWithDefaultSettingsIfIdle()
            }
        }
    }
    
    // MARK: - Video Picker Drop Zone
    
    private var videoPickerDropZone: some View {
        PhotosPicker(
            selection: $viewModel.selectedPickerItem,
            matching: .videos
        ) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                        .frame(width: 72, height: 72)
                    
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.accent)
                }
                
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
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Metrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        DesignSystem.Colors.accent.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            }
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
                VStack(spacing: 12) {
                    // Top Row: Duration & Color/HDR (2 columns)
                    HStack(spacing: 12) {
                        StatMetricView(
                            title: "Duration",
                            value: Formatters.formatDuration(meta.duration),
                            systemImage: "clock.fill",
                            tintColor: DesignSystem.Colors.accent
                        )
                        
                        StatMetricView(
                            title: "Color / HDR",
                            value: meta.isHDR ? "HDR" : "SDR",
                            systemImage: meta.isHDR ? "sun.max.fill" : "sun.min.fill",
                            tintColor: DesignSystem.Colors.accent
                        )
                    }
                    
                    // Bottom Row: Full-width Resolution (1 column)
                    StatMetricView(
                        title: "Resolution",
                        value: "\(Int(meta.naturalSize.width)) × \(Int(meta.naturalSize.height))",
                        systemImage: "tv.fill",
                        tintColor: DesignSystem.Colors.accent
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Video Mode")
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                    .lineLimit(1)
                    .layoutPriority(0)
                
                Spacer(minLength: 4)
                
                Picker("Video Mode", selection: Binding(
                    get: { viewModel.selectedMode },
                    set: { viewModel.applyModeSelection($0) }
                )) {
                    ForEach(VideoProcessingMode.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey(mode.title))
                            .lineLimit(1)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .tint(DesignSystem.Colors.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
                .accessibilityIdentifier("picker_video_mode")
            }
            
            Text(LocalizedStringKey(viewModel.selectedMode.localizedDescription))
                .font(DesignSystem.Fonts.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .padding(.horizontal, 2)
            
            Divider().opacity(0.3)
            
            // 3-Option Toggle Chips
            VStack(alignment: .leading, spacing: 8) {
                Text("Processing Options")
                    .font(DesignSystem.Fonts.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                
                HStack(spacing: 8) {
                    optionToggleChip(
                        title: "Compress",
                        icon: "arrow.down.right.and.arrow.up.left",
                        isSelected: viewModel.optionCompress
                    ) {
                        viewModel.toggleOptionCompress()
                    }
                    
                    optionToggleChip(
                        title: "Universal MP4",
                        icon: "play.rectangle.on.rectangle",
                        isSelected: viewModel.optionUniversalMP4
                    ) {
                        viewModel.toggleOptionUniversalMP4()
                    }
                    
                    optionToggleChip(
                        title: "HDR → SDR",
                        icon: "sun.max.fill",
                        isSelected: viewModel.optionToneMapping
                    ) {
                        viewModel.toggleOptionToneMapping()
                    }
                }
            }
        }
        .padding(DesignSystem.Metrics.cardPadding)
        .liquidGlassCard()
    }
    
    private func optionToggleChip(
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 11, weight: .bold))
                Text(LocalizedStringKey(title))
                    .font(DesignSystem.Fonts.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.secondaryText)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? DesignSystem.Colors.accent.opacity(0.14) : Color.white.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.6) : Color.white.opacity(0.12),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toggle_option_\(title.lowercased().replacingOccurrences(of: " ", with: "_"))")
    }
    
    // MARK: - Strength Selector Section
    
    private var strengthSelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Compression Strength")
                    .font(DesignSystem.Fonts.headline)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Spacer()
                
                Picker("Compression Strength", selection: $viewModel.selectedStrength) {
                    ForEach(CompressionStrength.allCases, id: \.self) { strength in
                        Text(LocalizedStringKey(strength.displayName)).tag(strength)
                    }
                }
                .pickerStyle(.menu)
                .tint(DesignSystem.Colors.accent)
                .accessibilityIdentifier("picker_video_strength")
            }
            
            Text(LocalizedStringKey(viewModel.selectedStrength.localizedDescription))
                .font(DesignSystem.Fonts.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .padding(.horizontal, 2)
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
                        Text(LocalizedStringKey(viewModel.isSavedToLibrary ? "Saved to Photos" : "Save Video to Photo Library"))
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
