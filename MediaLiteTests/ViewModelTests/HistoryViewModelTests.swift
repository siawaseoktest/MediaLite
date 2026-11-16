//
//  HistoryViewModelTests.swift
//  MediaLiteTests
//
//  Unit tests for HistoryViewModel covering category filtering,
//  dynamic aggregate calculations, individual item deletion, index-offset deletion,
//  and full history clearing.
//

import XCTest
@testable import MediaLite

final class HistoryViewModelTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var historyFileURL: URL!
    private var historyStore: HistoryStorageService!

    override func setUp() {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.medialite.tests.historyvm.\(uniqueID)")
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
    func testHistoryViewModelInitialState() {
        let viewModel = HistoryViewModel(historyStore: historyStore)

        XCTAssertEqual(viewModel.selectedFilter, .all)
        XCTAssertTrue(viewModel.allItems.isEmpty)
        XCTAssertTrue(viewModel.filteredItems.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.showClearAllConfirmation)
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, 0)
    }

    @MainActor
    func testHistoryViewModelFilterPhotosAndVideos() async throws {
        let p1 = CompressionHistoryItem(fileName: "p1.jpg", mediaType: "photo", sourceFormat: "JPEG", targetFormat: "JPEG", originalByteSize: 1_000, compressedByteSize: 500, compressionStrength: .medium)
        let p2 = CompressionHistoryItem(fileName: "p2.heic", mediaType: "photo", sourceFormat: "HEIC", targetFormat: "HEIC", originalByteSize: 2_000, compressedByteSize: 800, compressionStrength: .high)
        let p3 = CompressionHistoryItem(fileName: "p3.png", mediaType: "photo", sourceFormat: "PNG", targetFormat: "PNG", originalByteSize: 3_000, compressedByteSize: 1_200, compressionStrength: .low)
        let v1 = CompressionHistoryItem(fileName: "v1.mov", mediaType: "video", sourceFormat: "MOV", targetFormat: "MP4", originalByteSize: 10_000, compressedByteSize: 4_000, compressionStrength: .medium, durationSeconds: 5.0)
        let v2 = CompressionHistoryItem(fileName: "v2.mp4", mediaType: "video", sourceFormat: "MP4", targetFormat: "MP4", originalByteSize: 20_000, compressedByteSize: 8_000, compressionStrength: .high, durationSeconds: 12.0)

        try await historyStore.addItem(p1)
        try await historyStore.addItem(p2)
        try await historyStore.addItem(p3)
        try await historyStore.addItem(v1)
        try await historyStore.addItem(v2)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()

        // Filter: All
        viewModel.selectedFilter = .all
        XCTAssertEqual(viewModel.filteredItems.count, 5)

        // Filter: Photos
        viewModel.selectedFilter = .photos
        XCTAssertEqual(viewModel.filteredItems.count, 3)
        XCTAssertTrue(viewModel.filteredItems.allSatisfy { $0.mediaType == "photo" })

        // Filter: Videos
        viewModel.selectedFilter = .videos
        XCTAssertEqual(viewModel.filteredItems.count, 2)
        XCTAssertTrue(viewModel.filteredItems.allSatisfy { $0.mediaType == "video" })
    }

    @MainActor
    func testHistoryViewModelFilteredStats() async throws {
        let p1 = CompressionHistoryItem(fileName: "p1.jpg", mediaType: "photo", sourceFormat: "JPEG", targetFormat: "JPEG", originalByteSize: 10_000, compressedByteSize: 4_000, compressionStrength: .medium)
        let v1 = CompressionHistoryItem(fileName: "v1.mov", mediaType: "video", sourceFormat: "MOV", targetFormat: "MP4", originalByteSize: 50_000, compressedByteSize: 20_000, compressionStrength: .medium, durationSeconds: 5.0)

        try await historyStore.addItem(p1)
        try await historyStore.addItem(v1)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()

        // All Stats
        viewModel.selectedFilter = .all
        XCTAssertEqual(viewModel.filteredStats.totalOriginalBytes, 60_000)
        XCTAssertEqual(viewModel.filteredStats.totalCompressedBytes, 24_000)
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, 36_000)
        XCTAssertEqual(viewModel.filteredStats.photoCount, 1)
        XCTAssertEqual(viewModel.filteredStats.videoCount, 1)

        // Photos Stats
        viewModel.selectedFilter = .photos
        XCTAssertEqual(viewModel.filteredStats.totalOriginalBytes, 10_000)
        XCTAssertEqual(viewModel.filteredStats.totalCompressedBytes, 4_000)
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, 6_000)
        XCTAssertEqual(viewModel.filteredStats.photoCount, 1)
        XCTAssertEqual(viewModel.filteredStats.videoCount, 0)

        // Videos Stats
        viewModel.selectedFilter = .videos
        XCTAssertEqual(viewModel.filteredStats.totalOriginalBytes, 50_000)
        XCTAssertEqual(viewModel.filteredStats.totalCompressedBytes, 20_000)
        XCTAssertEqual(viewModel.filteredStats.totalSavedBytes, 30_000)
        XCTAssertEqual(viewModel.filteredStats.photoCount, 0)
        XCTAssertEqual(viewModel.filteredStats.videoCount, 1)
    }

    @MainActor
    func testHistoryViewModelDeleteItem() async throws {
        let id1 = UUID()
        let id2 = UUID()
        let item1 = CompressionHistoryItem(id: id1, fileName: "item1.jpg", mediaType: "photo", sourceFormat: "JPEG", targetFormat: "JPEG", originalByteSize: 1_000, compressedByteSize: 500, compressionStrength: .low)
        let item2 = CompressionHistoryItem(id: id2, fileName: "item2.jpg", mediaType: "photo", sourceFormat: "JPEG", targetFormat: "JPEG", originalByteSize: 2_000, compressedByteSize: 1_000, compressionStrength: .low)

        try await historyStore.addItem(item1)
        try await historyStore.addItem(item2)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.allItems.count, 2)

        await viewModel.deleteItem(id: id1)
        XCTAssertEqual(viewModel.allItems.count, 1)
        XCTAssertEqual(viewModel.allItems.first?.id, id2)

        // Check persisted state
        let persisted = try await historyStore.loadHistory()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.id, id2)
    }

    @MainActor
    func testHistoryViewModelDeleteOffsets() async throws {
        let item1 = CompressionHistoryItem(fileName: "item1.jpg", mediaType: "photo", sourceFormat: "JPEG", targetFormat: "JPEG", originalByteSize: 1_000, compressedByteSize: 500, compressionStrength: .low)
        let item2 = CompressionHistoryItem(fileName: "item2.jpg", mediaType: "photo", sourceFormat: "JPEG", targetFormat: "JPEG", originalByteSize: 2_000, compressedByteSize: 1_000, compressionStrength: .low)

        try await historyStore.addItem(item1)
        try await historyStore.addItem(item2)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.filteredItems.count, 2)

        await viewModel.deleteItem(at: IndexSet(integer: 0))
        XCTAssertEqual(viewModel.filteredItems.count, 1)
    }

    @MainActor
    func testHistoryViewModelDeleteOutOfBoundsOffsets() async throws {
        let item1 = CompressionHistoryItem(fileName: "item1.jpg", mediaType: "photo", sourceFormat: "JPEG", targetFormat: "JPEG", originalByteSize: 1_000, compressedByteSize: 500, compressionStrength: .low)
        try await historyStore.addItem(item1)
        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.filteredItems.count, 1)

        // Should safely ignore out-of-bounds indices without throwing or crashing
        await viewModel.deleteItem(at: IndexSet([1, 10, 99]))
        XCTAssertEqual(viewModel.filteredItems.count, 1)
    }

    @MainActor
    func testHistoryViewModelClearAllHistory() async throws {
        let item1 = CompressionHistoryItem(fileName: "item1.jpg", mediaType: "photo", sourceFormat: "JPEG", targetFormat: "JPEG", originalByteSize: 1_000, compressedByteSize: 500, compressionStrength: .low)
        try await historyStore.addItem(item1)

        let viewModel = HistoryViewModel(historyStore: historyStore)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.allItems.count, 1)

        await viewModel.clearAllHistory()
        XCTAssertTrue(viewModel.allItems.isEmpty)

        let persisted = try await historyStore.loadHistory()
        XCTAssertTrue(persisted.isEmpty)
    }
}
