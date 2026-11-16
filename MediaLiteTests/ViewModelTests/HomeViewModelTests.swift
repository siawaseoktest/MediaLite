//
//  HomeViewModelTests.swift
//  MediaLiteTests
//
//  Unit tests for HomeViewModel covering dashboard aggregates calculation,
//  recent items prefix limiting, empty history handling, and refresh flow.
//

import XCTest
@testable import MediaLite

final class HomeViewModelTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var historyFileURL: URL!
    private var historyStore: HistoryStorageService!

    override func setUp() {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.medialite.tests.homeviewmodel.\(uniqueID)")
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        historyFileURL = tempDirectoryURL.appendingPathComponent("history.json")
        historyStore = HistoryStorageService(storageURL: historyFileURL)
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        historyFileURL = nil
        historyStore = nil
        super.tearDown()
    }

    @MainActor
    func testHomeViewModelInitialState() {
        let viewModel = HomeViewModel(historyStore: historyStore)
        XCTAssertEqual(viewModel.stats.totalOriginalBytes, 0)
        XCTAssertEqual(viewModel.stats.totalCompressedBytes, 0)
        XCTAssertEqual(viewModel.stats.totalSavedBytes, 0)
        XCTAssertEqual(viewModel.stats.reductionPercentage, 0.0)
        XCTAssertEqual(viewModel.stats.photoCount, 0)
        XCTAssertEqual(viewModel.stats.videoCount, 0)
        XCTAssertTrue(viewModel.recentItems.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testHomeViewModelLoadsAggregatesAndRecents() async throws {
        // Seed 2 photos and 1 video
        let item1 = CompressionHistoryItem(
            fileName: "photo1.jpg",
            mediaType: "photo",
            sourceFormat: "public.jpeg",
            targetFormat: "public.jpeg",
            originalByteSize: 10_000_000,
            compressedByteSize: 4_000_000,
            compressionStrength: .medium
        )
        let item2 = CompressionHistoryItem(
            fileName: "photo2.heic",
            mediaType: "photo",
            sourceFormat: "public.heic",
            targetFormat: "public.heic",
            originalByteSize: 8_000_000,
            compressedByteSize: 2_000_000,
            compressionStrength: .high
        )
        let item3 = CompressionHistoryItem(
            fileName: "video1.mov",
            mediaType: "video",
            sourceFormat: "com.apple.quicktime-movie",
            targetFormat: "public.mpeg-4",
            originalByteSize: 50_000_000,
            compressedByteSize: 20_000_000,
            compressionStrength: .medium,
            durationSeconds: 15.0
        )

        try await historyStore.addItem(item1)
        try await historyStore.addItem(item2)
        try await historyStore.addItem(item3)

        let viewModel = HomeViewModel(historyStore: historyStore)
        await viewModel.loadDashboardData()

        XCTAssertEqual(viewModel.recentItems.count, 3)
        XCTAssertEqual(viewModel.stats.photoCount, 2)
        XCTAssertEqual(viewModel.stats.videoCount, 1)
        XCTAssertEqual(viewModel.stats.totalOriginalBytes, 68_000_000)
        XCTAssertEqual(viewModel.stats.totalCompressedBytes, 26_000_000)
        XCTAssertEqual(viewModel.stats.totalSavedBytes, 42_000_000)

        let expectedPercentage = (42_000_000.0 / 68_000_000.0) * 100.0
        XCTAssertEqual(viewModel.stats.reductionPercentage, expectedPercentage, accuracy: 0.01)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testHomeViewModelRecentItemsPrefixLimiting() async throws {
        // Seed 8 items
        for i in 1...8 {
            let item = CompressionHistoryItem(
                fileName: "item\(i).jpg",
                mediaType: "photo",
                sourceFormat: "public.jpeg",
                targetFormat: "public.jpeg",
                originalByteSize: 1_000_000,
                compressedByteSize: 500_000,
                compressionStrength: .low
            )
            try await historyStore.addItem(item)
        }

        let viewModel = HomeViewModel(historyStore: historyStore)
        await viewModel.loadDashboardData()

        // Should be limited to top 5 items
        XCTAssertEqual(viewModel.recentItems.count, 5)
        XCTAssertEqual(viewModel.stats.photoCount, 8)
        XCTAssertEqual(viewModel.stats.totalOriginalBytes, 8_000_000)
    }

    @MainActor
    func testHomeViewModelEmptyHistoryHandling() async {
        let viewModel = HomeViewModel(historyStore: historyStore)
        await viewModel.loadDashboardData()

        XCTAssertTrue(viewModel.recentItems.isEmpty)
        XCTAssertEqual(viewModel.stats.totalSavedBytes, 0)
        XCTAssertEqual(viewModel.stats.reductionPercentage, 0.0)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testHomeViewModelRefresh() async throws {
        let viewModel = HomeViewModel(historyStore: historyStore)
        await viewModel.loadDashboardData()
        XCTAssertEqual(viewModel.recentItems.count, 0)

        let newItem = CompressionHistoryItem(
            fileName: "refreshed.jpg",
            mediaType: "photo",
            sourceFormat: "public.jpeg",
            targetFormat: "public.jpeg",
            originalByteSize: 2_000_000,
            compressedByteSize: 1_000_000,
            compressionStrength: .medium
        )
        try await historyStore.addItem(newItem)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.recentItems.count, 1)
        XCTAssertEqual(viewModel.stats.totalSavedBytes, 1_000_000)
    }
}
