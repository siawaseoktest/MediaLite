//
//  TabNavigationAndAccessibilityTests.swift
//  MediaLiteTests
//
//  Unit tests verifying Feature 30 (Tab Navigation & Root View) and
//  Feature 31 (Accessibility & System Adaptations) along with reusable
//  Liquid Glass components.
//

import XCTest
import SwiftUI
@testable import MediaLite

final class TabNavigationAndAccessibilityTests: XCTestCase {

    // MARK: - 1. Feature 30: Tab Navigation & AppTab Contract

    func testAppTabAllCasesEnumerationAndCount() {
        let tabs = AppTab.allCases
        XCTAssertEqual(tabs.count, 5, "MediaLite must have exactly 5 tabs")
        XCTAssertEqual(tabs, [.home, .compress, .convert, .history, .settings])
        
        for (index, tab) in tabs.enumerated() {
            XCTAssertEqual(tab.rawValue, index)
            XCTAssertEqual(tab.id, index)
        }
    }

    func testAppTabTitlesAndSFSymbolNames() {
        // Home
        XCTAssertEqual(AppTab.home.title, "Home")
        XCTAssertEqual(AppTab.home.iconName, "house")
        XCTAssertEqual(AppTab.home.selectedIconName, "house.fill")
        XCTAssertEqual(AppTab.home.accessibilityIdentifier, "tab_home")

        // Photos (formerly Compress)
        XCTAssertEqual(AppTab.compress.title, "Photos")
        XCTAssertEqual(AppTab.compress.iconName, "photo")
        XCTAssertEqual(AppTab.compress.selectedIconName, "photo.fill")
        XCTAssertEqual(AppTab.compress.accessibilityIdentifier, "tab_compress")

        // Videos (formerly Convert)
        XCTAssertEqual(AppTab.convert.title, "Videos")
        XCTAssertEqual(AppTab.convert.iconName, "video")
        XCTAssertEqual(AppTab.convert.selectedIconName, "video.fill")
        XCTAssertEqual(AppTab.convert.accessibilityIdentifier, "tab_convert")

        // History
        XCTAssertEqual(AppTab.history.title, "History")
        XCTAssertEqual(AppTab.history.iconName, "clock.arrow.circlepath")
        XCTAssertEqual(AppTab.history.selectedIconName, "clock.arrow.circlepath")
        XCTAssertEqual(AppTab.history.accessibilityIdentifier, "tab_history")

        // Settings
        XCTAssertEqual(AppTab.settings.title, "Settings")
        XCTAssertEqual(AppTab.settings.iconName, "gearshape")
        XCTAssertEqual(AppTab.settings.selectedIconName, "gearshape.fill")
        XCTAssertEqual(AppTab.settings.accessibilityIdentifier, "tab_settings")
    }

    func testContentViewInstantiationAndInitialTab() {
        let defaultContent = ContentView()
        XCTAssertEqual(defaultContent.selectedTab, .home)

        let compressContent = ContentView(selectedTab: .compress)
        XCTAssertEqual(compressContent.selectedTab, .compress)

        let convertContent = ContentView(selectedTab: .convert)
        XCTAssertEqual(convertContent.selectedTab, .convert)
    }

    // MARK: - 2. Feature 31: SavingsBadge Formatting & Color Coding

    func testSavingsBadgePositiveSavings() {
        let badge = SavingsBadge(reductionPercentage: 65.2, isSizeIncreased: false)
        XCTAssertTrue(badge.isSignificantSavings)
        XCTAssertFalse(badge.isSignificantIncrease)
        XCTAssertEqual(badge.tintColor, DesignSystem.Colors.savingsGreen)
        XCTAssertEqual(badge.iconName, "arrow.down.right")
        XCTAssertEqual(badge.formattedText, "-65.2%")
        XCTAssertTrue(badge.accessibilityDescription.contains("65.2 percent reduction in file size"))
    }

    func testSavingsBadgeSizeIncrease() {
        let badge = SavingsBadge(reductionPercentage: -15.4, isSizeIncreased: true)
        XCTAssertFalse(badge.isSignificantSavings)
        XCTAssertTrue(badge.isSignificantIncrease)
        XCTAssertEqual(badge.tintColor, DesignSystem.Colors.increaseWarning)
        XCTAssertEqual(badge.iconName, "arrow.up.right")
        XCTAssertEqual(badge.formattedText, "+15.4%")
        XCTAssertTrue(badge.accessibilityDescription.contains("15.4 percent increase in file size"))
    }

    func testSavingsBadgeZeroChange() {
        let badge = SavingsBadge(reductionPercentage: 0.0, isSizeIncreased: false)
        XCTAssertFalse(badge.isSignificantSavings)
        XCTAssertFalse(badge.isSignificantIncrease)
        XCTAssertEqual(badge.tintColor, DesignSystem.Colors.secondaryText)
        XCTAssertEqual(badge.iconName, "minus")
        XCTAssertEqual(badge.formattedText, "0.0%")
        XCTAssertEqual(badge.accessibilityDescription, "No change in file size")
    }

    func testSavingsBadgeDetailedWithByteDelta() {
        let badge = SavingsBadge(
            reductionPercentage: 50.0,
            isSizeIncreased: false,
            byteDelta: 2_500_000,
            style: .detailed
        )
        XCTAssertTrue(badge.formattedText.contains("-50.0%"))
        XCTAssertTrue(badge.formattedText.contains("MB") || badge.formattedText.contains("2.5"))
        XCTAssertTrue(badge.accessibilityDescription.contains("Saved"))
        XCTAssertTrue(badge.accessibilityDescription.contains("50.0 percent reduction"))
    }

    // MARK: - 3. StatMetricView Accessibility & Sanitized Identifiers

    func testStatMetricViewAccessibilityValuesAndIdentifiers() {
        let metric = StatMetricView(
            title: "Total Space Saved",
            value: "1.4 GB",
            subtitle: "Lifetime reduction across 42 files",
            iconName: "internaldrive"
        )
        XCTAssertEqual(metric.title, "Total Space Saved")
        XCTAssertEqual(metric.value, "1.4 GB")
        XCTAssertEqual(metric.sanitizedIdentifier, "total_space_saved")
        XCTAssertEqual(metric.accessibilityCombinedValue, "1.4 GB, Lifetime reduction across 42 files")
    }

    func testStatMetricViewWithoutSubtitle() {
        let metric = StatMetricView(
            title: "Photos Compressed",
            value: "28"
        )
        XCTAssertEqual(metric.sanitizedIdentifier, "photos_compressed")
        XCTAssertEqual(metric.accessibilityCombinedValue, "28")
    }

    // MARK: - 4. LiquidGlassCard & Material Styles

    func testLiquidGlassMaterialStyles() {
        let styles: [LiquidGlassMaterialStyle] = [.ultraThin, .thin, .regular, .thick]
        for style in styles {
            XCTAssertNotNil(style.material)
        }
    }

    // MARK: - 5. Zero Network Invariant in UI Components

    func testZeroNetworkImportsInUIComponents() throws {
        let fileManager = FileManager.default
        let currentURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        // Locate MediaLite source root by traversing upwards if necessary
        var mediaLiteDir: URL?
        var candidate = currentURL
        for _ in 0..<5 {
            let potential = candidate.appendingPathComponent("MediaLite")
            if fileManager.fileExists(atPath: potential.path) {
                mediaLiteDir = potential
                break
            }
            candidate = candidate.deletingLastPathComponent()
        }

        guard let sourceDir = mediaLiteDir else {
            throw XCTSkip("Production source directory 'MediaLite' not accessible in current sandbox runner environment")
        }

        let targetRelativePaths = [
            "App/ContentView.swift",
            "Views/Components/LiquidGlassCard.swift",
            "Views/Components/SavingsBadge.swift",
            "Views/Components/StatMetricView.swift"
        ]

        let forbiddenPatterns = [
            "URLSession",
            "import Network",
            "import WebKit",
            "import CFNetwork",
            "NWPathMonitor",
            "NSURLConnection",
            "Alamofire"
        ]

        var inspectedFileCount = 0
        for relativePath in targetRelativePaths {
            let fileURL = sourceDir.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                XCTFail("Target UI component source file missing: \(fileURL.path)")
                continue
            }
            inspectedFileCount += 1
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }
                for pattern in forbiddenPatterns {
                    XCTAssertFalse(
                        trimmed.contains(pattern),
                        "UI component \(relativePath):\(lineIndex + 1) contains forbidden networking symbol '\(pattern)'"
                    )
                }
            }
        }
        XCTAssertEqual(inspectedFileCount, targetRelativePaths.count, "All UI component source files must be inspected")
    }

    // MARK: - 6. Feature 32: Japanese Localization & Multi-Language Support

    func testLocalizationStringsFilesExistAndAreParsable() throws {
        let fileManager = FileManager.default
        let currentURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        var mediaLiteDir: URL?
        var candidate = currentURL
        for _ in 0..<5 {
            let potential = candidate.appendingPathComponent("MediaLite")
            if fileManager.fileExists(atPath: potential.path) {
                mediaLiteDir = potential
                break
            }
            candidate = candidate.deletingLastPathComponent()
        }

        guard let sourceDir = mediaLiteDir else {
            throw XCTSkip("Production source directory 'MediaLite' not accessible in current sandbox runner environment")
        }

        let lprojFiles = [
            "Resources/ja.lproj/Localizable.strings",
            "Resources/en.lproj/Localizable.strings",
            "Resources/ja.lproj/InfoPlist.strings",
            "Resources/en.lproj/InfoPlist.strings"
        ]

        for relativePath in lprojFiles {
            let fileURL = sourceDir.appendingPathComponent(relativePath)
            XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path), "Localization file must exist: \(relativePath)")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(content.isEmpty, "Localization file must not be empty: \(relativePath)")
            XCTAssertTrue(content.contains("="), "Localization file must contain key-value mappings: \(relativePath)")
        }
    }

    func testJapaneseLocalizationCoversAllCoreUITabKeys() throws {
        let fileManager = FileManager.default
        let currentURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        var mediaLiteDir: URL?
        var candidate = currentURL
        for _ in 0..<5 {
            let potential = candidate.appendingPathComponent("MediaLite")
            if fileManager.fileExists(atPath: potential.path) {
                mediaLiteDir = potential
                break
            }
            candidate = candidate.deletingLastPathComponent()
        }

        guard let sourceDir = mediaLiteDir else {
            throw XCTSkip("Production source directory 'MediaLite' not accessible in current sandbox runner environment")
        }

        let jaStringsURL = sourceDir.appendingPathComponent("Resources/ja.lproj/Localizable.strings")
        let jaContent = try String(contentsOf: jaStringsURL, encoding: .utf8)

        // Verify Core Tab Titles are localized to Japanese
        XCTAssertTrue(jaContent.contains("\"Home\" = \"ホーム\";"), "Japanese translation for Home tab required")
        XCTAssertTrue(jaContent.contains("\"Photos\" = \"写真\";"), "Japanese translation for Photos tab required")
        XCTAssertTrue(jaContent.contains("\"Videos\" = \"動画\";"), "Japanese translation for Videos tab required")
        XCTAssertTrue(jaContent.contains("\"Compress\" = \"圧縮\";"), "Japanese translation for Compress required")
        XCTAssertTrue(jaContent.contains("\"Convert\" = \"変換\";"), "Japanese translation for Convert required")
        XCTAssertTrue(jaContent.contains("\"History\" = \"履歴\";"), "Japanese translation for History tab required")
        XCTAssertTrue(jaContent.contains("\"Settings\" = \"設定\";"), "Japanese translation for Settings tab required")

        // Verify Key Action and Hero Strings
        XCTAssertTrue(jaContent.contains("\"LIFETIME SAVINGS\" = \"合計削減容量\";"))
        XCTAssertTrue(jaContent.contains("\"Quick Actions\" = \"クイック操作\";"))
        XCTAssertTrue(jaContent.contains("\"Start Video Compression\" = \"動画圧縮を開始\";"))
        XCTAssertTrue(jaContent.contains("\"BATCH COMPRESSION COMPLETE\" = \"一括圧縮が完了しました\";"))
        XCTAssertTrue(jaContent.contains("\"CONVERSION COMPLETE\" = \"変換完了\";"))
        XCTAssertTrue(jaContent.contains("\"Clear All History\" = \"すべての履歴を消去\";"))
        XCTAssertTrue(jaContent.contains("\"100% On-Device Processing\" = \"完全オンデバイス処理\";"))
    }

    func testAppLanguageEnumerationAndDisplayNames() {
        let languages = AppLanguage.allCases
        XCTAssertEqual(languages, [.system, .japanese, .english])

        XCTAssertEqual(AppLanguage.system.displayName, "System Default")
        XCTAssertEqual(AppLanguage.japanese.displayName, "日本語")
        XCTAssertEqual(AppLanguage.english.displayName, "English")
    }

    func testInfoPlistJapaneseAddUsageDescription() throws {
        let fileManager = FileManager.default
        let currentURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        var mediaLiteDir: URL?
        var candidate = currentURL
        for _ in 0..<5 {
            let potential = candidate.appendingPathComponent("MediaLite")
            if fileManager.fileExists(atPath: potential.path) {
                mediaLiteDir = potential
                break
            }
            candidate = candidate.deletingLastPathComponent()
        }

        guard let sourceDir = mediaLiteDir else {
            throw XCTSkip("Production source directory 'MediaLite' not accessible in current sandbox runner environment")
        }

        let jaInfoPlistURL = sourceDir.appendingPathComponent("Resources/ja.lproj/InfoPlist.strings")
        let content = try String(contentsOf: jaInfoPlistURL, encoding: .utf8)

        XCTAssertTrue(content.contains("NSPhotoLibraryAddUsageDescription"), "InfoPlist.strings must localize Photo Library Add-Only permission")
        XCTAssertTrue(content.contains("写真ライブラリ"), "InfoPlist.strings must contain Japanese explanation")
    }
}
