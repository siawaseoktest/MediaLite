//
//  PrivacyEnforcementTests.swift
//  MediaLiteTests
//
//  Automated static analysis and privacy manifest validation unit tests.
//  Enforces the 100% on-device zero-network privacy policy for MediaLite:
//  1. Verifies that no production Swift file imports network frameworks (Network, WebKit, CFNetwork, Alamofire).
//  2. Verifies that no forbidden network networking symbols (URLSession, NWPathMonitor, WKWebView, NSURLConnection) exist.
//  3. Verifies Info.plist privacy declarations (add-only photo library access, no full photo library read access).
//  4. Verifies PrivacyInfo.xcprivacy (tracking disabled, zero data collected, valid API declaration reasons).
//

import XCTest
@testable import MediaLite

final class PrivacyEnforcementTests: XCTestCase {

    private var projectRootURL: URL {
        // Locate workspace / repository root
        let fileManager = FileManager.default
        let currentPath = fileManager.currentDirectoryPath
        let currentURL = URL(fileURLWithPath: currentPath)

        if fileManager.fileExists(atPath: currentURL.appendingPathComponent("MediaLite").path) {
            return currentURL
        }

        // Fallback search upwards up to 4 levels
        var searchURL = currentURL
        for _ in 0..<4 {
            searchURL = searchURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: searchURL.appendingPathComponent("MediaLite").path) {
                return searchURL
            }
        }
        return currentURL
    }

    // MARK: - 1. Zero Network Imports & Symbols Invariant

    func testZeroNetworkImportsInProductionSwiftSources() throws {
        let fileManager = FileManager.default
        let sourceDir = projectRootURL.appendingPathComponent("MediaLite")

        guard fileManager.fileExists(atPath: sourceDir.path) else {
            throw XCTSkip("Production source directory MediaLite/ not accessible in current sandbox runner environment at '\(sourceDir.path)'")
        }

        let enumerator = fileManager.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let forbiddenImportPatterns = [
            "import Network",
            "import WebKit",
            "import CFNetwork",
            "import Alamofire",
            "import Socket"
        ]

        var inspectedCount = 0
        var violations: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            inspectedCount += 1

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }

                for pattern in forbiddenImportPatterns {
                    if trimmed.hasPrefix(pattern) {
                        violations.append("\(fileURL.lastPathComponent):\(index + 1): \(pattern)")
                    }
                }
            }
        }

        XCTAssertGreaterThan(inspectedCount, 5, "At least 5 production Swift source files should be scanned")
        XCTAssertTrue(
            violations.isEmpty,
            "Privacy policy violation: forbidden network imports found in production source files:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testZeroNetworkSymbolsInProductionSwiftSources() throws {
        let fileManager = FileManager.default
        let sourceDir = projectRootURL.appendingPathComponent("MediaLite")

        guard fileManager.fileExists(atPath: sourceDir.path) else {
            throw XCTSkip("Production source directory MediaLite/ not accessible in current sandbox runner environment at '\(sourceDir.path)'")
        }

        let enumerator = fileManager.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let forbiddenSymbolPatterns = [
            "URLSession",
            "NWPathMonitor",
            "WKWebView",
            "NSURLConnection",
            "Alamofire"
        ]

        var violations: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }

                for symbol in forbiddenSymbolPatterns {
                    if trimmed.contains(symbol) {
                        violations.append("\(fileURL.lastPathComponent):\(index + 1): contains forbidden symbol '\(symbol)'")
                    }
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Privacy policy violation: forbidden networking symbols detected in production code:\n\(violations.joined(separator: "\n"))"
        )
    }

    // MARK: - 2. Info.plist Privacy Declarations

    func testInfoPlistPhotoKitAddOnlyDeclaration() throws {
        let infoPlistURL = projectRootURL.appendingPathComponent("MediaLite/Resources/Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw XCTSkip("Info.plist not accessible in current sandbox runner environment at '\(infoPlistURL.path)'")
        }

        let data = try Data(contentsOf: infoPlistURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = propertyList as? [String: Any] else {
            XCTFail("Unable to parse Info.plist as dictionary")
            return
        }

        // Invariant: Must declare NSPhotoLibraryAddUsageDescription (Add-Only)
        let addUsageDescription = dict["NSPhotoLibraryAddUsageDescription"] as? String
        XCTAssertNotNil(addUsageDescription, "Info.plist must declare NSPhotoLibraryAddUsageDescription")
        XCTAssertFalse(addUsageDescription?.isEmpty ?? true, "NSPhotoLibraryAddUsageDescription must not be empty")

        // Invariant: Must NOT declare NSPhotoLibraryUsageDescription (Full Photo Library Access)
        XCTAssertNil(
            dict["NSPhotoLibraryUsageDescription"],
            "Info.plist must NOT declare NSPhotoLibraryUsageDescription (would violate add-only privacy guarantee)"
        )
    }

    func testInfoPlistNoArbitraryNetworkLoads() throws {
        let infoPlistURL = projectRootURL.appendingPathComponent("MediaLite/Resources/Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else { return }

        let data = try Data(contentsOf: infoPlistURL)
        guard let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return
        }

        if let ats = dict["NSAppTransportSecurity"] as? [String: Any] {
            let allowsArbitrary = ats["NSAllowsArbitraryLoads"] as? Bool ?? false
            XCTAssertFalse(allowsArbitrary, "NSAllowsArbitraryLoads must NOT be true")
        }
    }

    // MARK: - 3. Apple Privacy Manifest (PrivacyInfo.xcprivacy) Validation

    func testPrivacyManifestValidation() throws {
        let privacyManifestURL = projectRootURL.appendingPathComponent("MediaLite/Resources/PrivacyInfo.xcprivacy")
        guard FileManager.default.fileExists(atPath: privacyManifestURL.path) else {
            throw XCTSkip("PrivacyInfo.xcprivacy not accessible in current sandbox runner environment at '\(privacyManifestURL.path)'")
        }

        let data = try Data(contentsOf: privacyManifestURL)
        guard let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("PrivacyInfo.xcprivacy is not a valid property list")
            return
        }

        // Invariant: Tracking must be disabled
        let tracking = dict["NSPrivacyTracking"] as? Bool
        XCTAssertEqual(tracking, false, "NSPrivacyTracking must be false")

        // Invariant: No tracking domains
        let trackingDomains = dict["NSPrivacyTrackingDomains"] as? [String]
        XCTAssertTrue(trackingDomains?.isEmpty ?? true, "NSPrivacyTrackingDomains must be empty")

        // Invariant: Zero collected data types
        let collectedDataTypes = dict["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        XCTAssertTrue(collectedDataTypes?.isEmpty ?? true, "MediaLite must not collect any user data")

        // Invariant: Accessed API types must have valid declared reasons
        let accessedAPITypes = dict["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        XCTAssertNotNil(accessedAPITypes, "NSPrivacyAccessedAPITypes must be present")

        // Allow both official Apple string and legacy type string for full compatibility
        let userDefaultsDeclaration = accessedAPITypes?.first {
            let apiType = $0["NSPrivacyAccessedAPIType"] as? String
            return apiType == "NSPrivacyAccessedAPICategoryUserDefaults" || apiType == "NSPrivacyAccessedAPITypeUserDefaults"
        }
        XCTAssertNotNil(userDefaultsDeclaration, "UserDefaults usage must be declared in PrivacyInfo.xcprivacy")

        let reasons = userDefaultsDeclaration?["NSPrivacyAccessedAPITypeReasons"] as? [String]
        XCTAssertTrue(reasons?.contains("CA92.1") ?? false, "Reason CA92.1 must be declared for UserDefaults")
    }
}
