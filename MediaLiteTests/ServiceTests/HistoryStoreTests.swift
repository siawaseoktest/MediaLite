//
//  HistoryStoreTests.swift
//  MediaLiteTests
//
//  Unit tests for HistoryStore actor.
//  Covers CRUD operations (add, query, delete single, clear all, update),
//  actor concurrency stress testing, corrupt JSON recovery, aggregate calculations,
//  and disk persistence guarantees across separate actor instances.
//

import XCTest
@testable import MediaLite

final class HistoryStoreTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var historyFileURL: URL!

    override func setUp() {
        super.setUp()
        let uniqueID = UUID().uuidString
        tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.medialite.tests.historystore.\(uniqueID)")
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        historyFileURL = tempDirectoryURL.appendingPathComponent("history.json")
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        historyFileURL = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeSampleItem(
        id: UUID = UUID(),
        fileName: String = "photo.jpg",
        mediaType: String = "photo",
        sourceFormat: String = "public.jpeg",
        targetFormat: String = "public.jpeg",
        originalSize: Int64 = 5_000_000,
        compressedSize: Int64 = 2_000_000,
        strength: CompressionStrength = .medium,
        isSaved: Bool = false
    ) -> CompressionHistoryItem {
        CompressionHistoryItem(
            id: id,
            timestamp: Date(),
            fileName: fileName,
            mediaType: mediaType,
            sourceFormat: sourceFormat,
            targetFormat: targetFormat,
            originalByteSize: originalSize,
            compressedByteSize: compressedSize,
            compressionStrength: strength,
            durationSeconds: mediaType == "video" ? 15.0 : nil,
            isSavedToLibrary: isSaved
        )
    }

    // MARK: - 1. Empty & Non-Existent File Tests

    func testLoadHistoryWhenFileDoesNotExistReturnsEmpty() async throws {
        let store = HistoryStore(storageURL: historyFileURL)
        let items = try await store.loadHistory()
        XCTAssertTrue(items.isEmpty, "Non-existent storage should yield empty history list")
    }

    func testLoadHistoryWhenFileIsEmptyReturnsEmpty() async throws {
        try "".write(to: historyFileURL, atomically: true, encoding: .utf8)
        let store = HistoryStore(storageURL: historyFileURL)
        let items = try await store.loadHistory()
        XCTAssertTrue(items.isEmpty, "Empty file should yield empty history list")
    }

    // MARK: - 2. CRUD Operations

    func testAddItemAndQueryHistory() async throws {
        let store = HistoryStore(storageURL: historyFileURL)

        let item1 = makeSampleItem(fileName: "image1.jpg", originalSize: 4_000_000, compressedSize: 1_500_000)
        let item2 = makeSampleItem(fileName: "image2.png", originalSize: 8_000_000, compressedSize: 3_000_000)

        try await store.addItem(item1)
        try await store.addItem(item2)

        let items = try await store.loadHistory()
        XCTAssertEqual(items.count, 2)
        // Most recently added item should be at the head of the list
        XCTAssertEqual(items[0].id, item2.id)
        XCTAssertEqual(items[1].id, item1.id)
    }

    func testDeleteSingleItem() async throws {
        let store = HistoryStore(storageURL: historyFileURL)

        let item1 = makeSampleItem(fileName: "item1.jpg")
        let item2 = makeSampleItem(fileName: "item2.jpg")
        let item3 = makeSampleItem(fileName: "item3.jpg")

        try await store.addItem(item1)
        try await store.addItem(item2)
        try await store.addItem(item3)

        // Delete middle item
        try await store.deleteItem(id: item2.id)

        let remaining = try await store.loadHistory()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains { $0.id == item2.id })
        XCTAssertTrue(remaining.contains { $0.id == item1.id })
        XCTAssertTrue(remaining.contains { $0.id == item3.id })
    }

    func testDeleteBatchItems() async throws {
        let store = HistoryStore(storageURL: historyFileURL)

        let item1 = makeSampleItem(fileName: "item1.jpg")
        let item2 = makeSampleItem(fileName: "item2.jpg")
        let item3 = makeSampleItem(fileName: "item3.jpg")

        try await store.addItem(item1)
        try await store.addItem(item2)
        try await store.addItem(item3)

        try await store.deleteItems(ids: [item1.id, item3.id])

        let remaining = try await store.loadHistory()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, item2.id)
    }

    func testClearAllHistory() async throws {
        let store = HistoryStore(storageURL: historyFileURL)

        try await store.addItem(makeSampleItem(fileName: "item1.jpg"))
        try await store.addItem(makeSampleItem(fileName: "item2.jpg"))

        var items = try await store.loadHistory()
        XCTAssertEqual(items.count, 2)

        try await store.clearAllHistory()

        items = try await store.loadHistory()
        XCTAssertTrue(items.isEmpty, "Clear all should wipe all records")
    }

    func testUpdateItem() async throws {
        let store = HistoryStore(storageURL: historyFileURL)

        var item = makeSampleItem(fileName: "photo.heic", isSaved: false)
        try await store.addItem(item)

        item.isSavedToLibrary = true
        try await store.updateItem(item)

        let updated = try await store.loadHistory()
        XCTAssertEqual(updated.count, 1)
        XCTAssertTrue(updated.first?.isSavedToLibrary ?? false)
    }

    // MARK: - 3. Persistence Across Separate Actor Instances

    func testDiskPersistenceAcrossFreshInstances() async throws {
        let item = makeSampleItem(fileName: "persistent.jpg", originalSize: 10_000_000, compressedSize: 4_000_000)

        // Store item using first actor instance
        let store1 = HistoryStore(storageURL: historyFileURL)
        try await store1.addItem(item)

        // Re-read with a completely separate actor instance pointing to the same file
        let store2 = HistoryStore(fileURL: historyFileURL)
        let items = try await store2.loadHistory()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, item.id)
        XCTAssertEqual(items.first?.fileName, "persistent.jpg")
        XCTAssertEqual(items.first?.originalByteSize, 10_000_000)
        XCTAssertEqual(items.first?.compressedByteSize, 4_000_000)
    }

    // MARK: - 4. Corrupt JSON Recovery

    func testCorruptJSONRecoveryReturnsEmptyWithoutCrash() async throws {
        // Write invalid corrupted bytes to history.json
        let corruptedBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0xFE, 0xFD, 0x7B, 0x30])
        try corruptedBytes.write(to: historyFileURL)

        let store = HistoryStore(storageURL: historyFileURL)
        let items = try await store.loadHistory()

        XCTAssertTrue(items.isEmpty, "Corrupt backing file should gracefully fall back to empty array without crashing")

        // Store should be able to write new items cleanly over the corrupted file
        let newItem = makeSampleItem(fileName: "recovered.jpg")
        try await store.addItem(newItem)

        let reloaded = try await store.loadHistory()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, newItem.id)
    }

    // MARK: - 5. Actor Concurrency Stress Testing

    func testActorConcurrencyStressWriteTasks() async throws {
        let store = HistoryStore(storageURL: historyFileURL)
        let taskCount = 50

        // Launch concurrent tasks simultaneously writing to the store
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    let item = CompressionHistoryItem(
                        id: UUID(),
                        timestamp: Date(),
                        fileName: "stress_\(i).jpg",
                        mediaType: "photo",
                        sourceFormat: "public.jpeg",
                        targetFormat: "public.jpeg",
                        originalByteSize: Int64(1_000_000 + i * 1_000),
                        compressedByteSize: Int64(500_000 + i * 500),
                        compressionStrength: .high
                    )
                    try? await store.addItem(item)
                }
            }
        }

        let items = try await store.loadHistory()
        XCTAssertEqual(items.count, taskCount, "All \(taskCount) concurrent writes must be safely persisted without data loss or race conditions")
    }

    // MARK: - 6. Aggregate Savings Calculation

    func testAggregateCalculations() async throws {
        let store = HistoryStore(storageURL: historyFileURL)

        let photo1 = makeSampleItem(mediaType: "photo", originalSize: 10_000_000, compressedSize: 4_000_000)
        let photo2 = makeSampleItem(mediaType: "photo", originalSize: 6_000_000, compressedSize: 2_000_000)
        let video1 = makeSampleItem(mediaType: "video", originalSize: 20_000_000, compressedSize: 10_000_000)

        try await store.addItem(photo1)
        try await store.addItem(photo2)
        try await store.addItem(video1)

        let aggregates = await store.calculateAggregates()

        XCTAssertEqual(aggregates.totalOriginalBytes, 36_000_000)
        XCTAssertEqual(aggregates.totalCompressedBytes, 16_000_000)
        XCTAssertEqual(aggregates.totalSavedBytes, 20_000_000)
        XCTAssertEqual(aggregates.photoCount, 2)
        XCTAssertEqual(aggregates.videoCount, 1)

        let expectedPercentage = (Double(20_000_000) / Double(36_000_000)) * 100.0
        XCTAssertEqual(aggregates.reductionPercentage, expectedPercentage, accuracy: 0.001)
    }

    func testAggregatesWithEmptyStore() async {
        let store = HistoryStore(storageURL: historyFileURL)
        let aggregates = await store.calculateAggregates()

        XCTAssertEqual(aggregates.totalOriginalBytes, 0)
        XCTAssertEqual(aggregates.totalCompressedBytes, 0)
        XCTAssertEqual(aggregates.totalSavedBytes, 0)
        XCTAssertEqual(aggregates.reductionPercentage, 0.0)
        XCTAssertEqual(aggregates.photoCount, 0)
        XCTAssertEqual(aggregates.videoCount, 0)
    }

    // MARK: - 7. Typealias and Default URL Verification

    func testTypealiasAndDefaultURL() {
        XCTAssertTrue(HistoryStorageService.self == HistoryStore.self, "HistoryStorageService should be a typealias for HistoryStore")
        let defaultURL = HistoryStore.defaultStorageURL
        XCTAssertTrue(defaultURL.path.contains("MediaLite/history.json"), "Default URL should point to MediaLite/history.json")
    }

    // MARK: - 8. Edge Case Tests

    func testDeleteNonExistentIDIsSafeNoOp() async throws {
        let store = HistoryStore(storageURL: historyFileURL)
        let item = makeSampleItem(fileName: "existing.jpg")
        try await store.addItem(item)

        // Deleting non-existent UUID should succeed without altering existing record
        try await store.deleteItem(id: UUID())

        let items = try await store.loadHistory()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, item.id)
    }

    func testUpdateNonExistentItemIsSafeNoOp() async throws {
        let store = HistoryStore(storageURL: historyFileURL)
        let item = makeSampleItem(fileName: "existing.jpg")
        try await store.addItem(item)

        let unlistedItem = makeSampleItem(id: UUID(), fileName: "unlisted.jpg")
        try await store.updateItem(unlistedItem)

        let items = try await store.loadHistory()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, item.id)
    }

    func testDeepNestedDirectoryAutoCreation() async throws {
        let deepURL = tempDirectoryURL
            .appendingPathComponent("nested1")
            .appendingPathComponent("nested2")
            .appendingPathComponent("deep_history.json")

        let store = HistoryStore(fileURL: deepURL)
        let item = makeSampleItem(fileName: "deep.jpg")
        try await store.addItem(item)

        XCTAssertTrue(FileManager.default.fileExists(atPath: deepURL.path))
        let items = try await store.loadHistory()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, item.id)
    }

    func testProtocolPolymorphicUsage() async throws {
        let polymorphicStore: any HistoryStorageProtocol = HistoryStorageService(fileURL: historyFileURL)
        let item = makeSampleItem(fileName: "poly.jpg")

        try await polymorphicStore.addItem(item)
        let loaded = try await polymorphicStore.loadHistory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, item.id)

        try await polymorphicStore.deleteItem(id: item.id)
        let empty = try await polymorphicStore.loadHistory()
        XCTAssertTrue(empty.isEmpty)

        try await polymorphicStore.addItem(item)
        try await polymorphicStore.clearAllHistory()
        let cleared = try await polymorphicStore.loadHistory()
        XCTAssertTrue(cleared.isEmpty)
    }
}
