//
//  SettingsView.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  Settings Tab view featuring compression preferences, cache inspection & purge,
//  factory reset, and on-device privacy assurance card.
//

import SwiftUI

@MainActor
public struct SettingsView: View {
    @StateObject public var viewModel: SettingsViewModel
    
    public init(viewModel: SettingsViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? SettingsViewModel())
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                // Section 1: Default Compression Qualities
                compressionDefaultsSection
                
                // Section 2: Photo & Video Preferences
                preferencesSection
                
                // Section 3: Language
                languageSection
                
                // Section 4: Storage & Cache Management
                cacheSection
                
                // Section 5: Privacy Assurance
                privacyAssuranceSection
                
                // Section 6: Reset Preferences
                resetSection
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 36)
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Clear Cache",
                isPresented: $viewModel.showClearCacheConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Temporary Cache", role: .destructive) {
                    viewModel.clearCache()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all sandboxed temporary processing files. Completed exports saved to your Photo Library will remain safe.")
            }
            .confirmationDialog(
                "Reset All Preferences",
                isPresented: $viewModel.showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset to Factory Defaults", role: .destructive) {
                    viewModel.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All compression and conversion preferences will be restored to their original default settings.")
            }
            .onAppear {
                viewModel.inspectCache()
            }
        }
    }
    
    // MARK: - Compression Defaults Section
    
    private var compressionDefaultsSection: some View {
        Section(header: Text("Default Compression Settings")) {
            Picker("Photo Quality", selection: $viewModel.settings.defaultCompressionStrength) {
                ForEach(CompressionStrength.allCases, id: \.self) { strength in
                    Text(LocalizedStringKey(strength.displayName)).tag(strength)
                }
            }
            .onChange(of: viewModel.settings.defaultCompressionStrength) { _, _ in
                viewModel.updateSettings()
            }
            .accessibilityIdentifier("settings_picker_photo_quality")
            
            Picker("Video Mode", selection: $viewModel.settings.defaultVideoMode) {
                ForEach(VideoProcessingMode.allCases, id: \.self) { mode in
                    Text(LocalizedStringKey(mode.title)).tag(mode)
                }
            }
            .onChange(of: viewModel.settings.defaultVideoMode) { _, _ in
                viewModel.updateSettings()
            }
            .accessibilityIdentifier("settings_picker_video_mode")
        }
    }
    
    // MARK: - Preferences Section
    
    private var preferencesSection: some View {
        Section(header: Text("Photo & Video Preferences")) {
            Toggle("Auto-Save to Photo Library", isOn: $viewModel.settings.autoSaveToLibrary)
                .onChange(of: viewModel.settings.autoSaveToLibrary) { _, _ in
                    viewModel.updateSettings()
                }
                .accessibilityIdentifier("settings_toggle_autosave")
            
            Toggle("Preserve EXIF & Metadata", isOn: $viewModel.settings.preserveMetadata)
                .onChange(of: viewModel.settings.preserveMetadata) { _, _ in
                    viewModel.updateSettings()
                }
                .accessibilityIdentifier("settings_toggle_metadata")
            
            Toggle("Prompt Before Deleting Original", isOn: $viewModel.settings.deleteOriginalPrompt)
                .onChange(of: viewModel.settings.deleteOriginalPrompt) { _, _ in
                    viewModel.updateSettings()
                }
                .accessibilityIdentifier("settings_toggle_delete_prompt")
        }
    }
    
    // MARK: - Language Section
    
    private var languageSection: some View {
        Section(header: Text("Language")) {
            Picker("Language", selection: $viewModel.settings.appLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(LocalizedStringKey(lang.displayName)).tag(lang)
                }
            }
            .onChange(of: viewModel.settings.appLanguage) { _, _ in
                viewModel.updateSettings()
            }
            .accessibilityIdentifier("settings_picker_language")
        }
    }
    
    // MARK: - Cache Section
    
    private var cacheSection: some View {
        Section(header: Text("Temporary Storage & Cache")) {
            HStack {
                Text("Cache Footprint")
                Spacer()
                Text(Formatters.formatBytes(viewModel.cacheSizeBytes))
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }
            .accessibilityIdentifier("settings_cache_size_row")
            
            if let freeSpace = viewModel.availableDiskBytes {
                HStack {
                    Text("Device Free Storage")
                    Spacer()
                    Text(Formatters.formatBytes(freeSpace))
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                }
                .accessibilityIdentifier("settings_disk_space_row")
            }
            
            Button("Clear Temporary Cache", role: .destructive) {
                viewModel.showClearCacheConfirmation = true
            }
            .accessibilityIdentifier("settings_button_clear_cache")
        }
    }
    
    // MARK: - Privacy Assurance Section
    
    private var privacyAssuranceSection: some View {
        Section(header: Text("Privacy & Security")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title2)
                        .foregroundStyle(Color.green)
                    
                    Text("100% On-Device Processing")
                        .font(DesignSystem.Fonts.headline)
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                }
                
                Text("MediaLite operates strictly offline. No photos, videos, or metadata are ever transmitted, tracked, or collected over the network.")
                    .font(DesignSystem.Fonts.subheadline)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                
                Text("Photo Library Add-Only: MediaLite can only export newly compressed items and cannot inspect or delete existing photos.")
                    .font(DesignSystem.Fonts.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings_privacy_assurance_card")
        }
    }
    
    // MARK: - Reset Section
    
    private var resetSection: some View {
        Section {
            Button("Reset All Preferences to Defaults", role: .destructive) {
                viewModel.showResetConfirmation = true
            }
            .accessibilityIdentifier("settings_button_reset_defaults")
        }
    }
}
