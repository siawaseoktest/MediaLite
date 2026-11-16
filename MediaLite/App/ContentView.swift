//
//  ContentView.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5: SwiftUI Liquid Glass UI (5 Tabs).
//  Root navigation container implementing standard 5-tab TabView with
//  SF Symbols, system tints, selection state, and VoiceOver accessibility.
//

import SwiftUI

// MARK: - AppTab Enumeration

/// Defines the five primary tabs of MediaLite matching Apple Liquid Glass HIG.
public enum AppTab: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case home = 0
    case compress = 1
    case convert = 2
    case history = 3
    case settings = 4
    
    public static let photos = AppTab.compress
    public static let videos = AppTab.convert
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .home:
            return "Home"
        case .compress:
            return "Photos"
        case .convert:
            return "Videos"
        case .history:
            return "History"
        case .settings:
            return "Settings"
        }
    }
    
    public var iconName: String {
        switch self {
        case .home:
            return "house"
        case .compress:
            return "photo"
        case .convert:
            return "video"
        case .history:
            return "clock.arrow.circlepath"
        case .settings:
            return "gearshape"
        }
    }
    
    public var selectedIconName: String {
        switch self {
        case .home:
            return "house.fill"
        case .compress:
            return "photo.fill"
        case .convert:
            return "video.fill"
        case .history:
            return "clock.arrow.circlepath"
        case .settings:
            return "gearshape.fill"
        }
    }
    
    public var accessibilityIdentifier: String {
        switch self {
        case .home:
            return "tab_home"
        case .compress:
            return "tab_compress"
        case .convert:
            return "tab_convert"
        case .history:
            return "tab_history"
        case .settings:
            return "tab_settings"
        }
    }
}

// MARK: - ContentView

public struct ContentView: View {
    @State public var selectedTab: AppTab
    @AppStorage(AppSettings.Keys.appLanguage) private var appLanguageRaw: String = AppLanguage.system.rawValue
    
    public init(selectedTab: AppTab = .home) {
        _selectedTab = State(initialValue: selectedTab)
    }
    
    private var selectedLocale: Locale {
        let lang = AppLanguage(rawValue: appLanguageRaw) ?? .system
        switch lang {
        case .system:
            return Locale.autoupdatingCurrent
        case .japanese:
            return Locale(identifier: "ja")
        case .english:
            return Locale(identifier: "en")
        }
    }
    
    public var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem {
                    Label(
                        LocalizedStringKey(AppTab.home.title),
                        systemImage: selectedTab == .home ? AppTab.home.selectedIconName : AppTab.home.iconName
                    )
                }
                .tag(AppTab.home)
                .accessibilityIdentifier(AppTab.home.accessibilityIdentifier)
            
            CompressView()
                .tabItem {
                    Label(
                        LocalizedStringKey(AppTab.compress.title),
                        systemImage: selectedTab == .compress ? AppTab.compress.selectedIconName : AppTab.compress.iconName
                    )
                }
                .tag(AppTab.compress)
                .accessibilityIdentifier(AppTab.compress.accessibilityIdentifier)
            
            ConvertView()
                .tabItem {
                    Label(
                        LocalizedStringKey(AppTab.convert.title),
                        systemImage: selectedTab == .convert ? AppTab.convert.selectedIconName : AppTab.convert.iconName
                    )
                }
                .tag(AppTab.convert)
                .accessibilityIdentifier(AppTab.convert.accessibilityIdentifier)
            
            HistoryView()
                .tabItem {
                    Label(
                        LocalizedStringKey(AppTab.history.title),
                        systemImage: selectedTab == .history ? AppTab.history.selectedIconName : AppTab.history.iconName
                    )
                }
                .tag(AppTab.history)
                .accessibilityIdentifier(AppTab.history.accessibilityIdentifier)
            
            SettingsView()
                .tabItem {
                    Label(
                        LocalizedStringKey(AppTab.settings.title),
                        systemImage: selectedTab == .settings ? AppTab.settings.selectedIconName : AppTab.settings.iconName
                    )
                }
                .tag(AppTab.settings)
                .accessibilityIdentifier(AppTab.settings.accessibilityIdentifier)
        }
        .tint(DesignSystem.Colors.accent)
        .environment(\.locale, selectedLocale)
    }
}
