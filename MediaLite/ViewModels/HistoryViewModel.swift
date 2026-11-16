//
//  HistoryViewModel.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  ViewModel managing the processing history archive, category filtering,
//  dynamic aggregate statistics, item deletion, and clearing.
//

import Foundation
import SwiftUI

public enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    public var id: String { rawValue }
}

@MainActor
public final class HistoryViewModel: ObservableObject {
    @Published public private(set) var allItems: [CompressionHistoryItem] = []
    @Published public var selectedFilter: HistoryFilter = .all
    @Published public private(set) var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var showClearAllConfirmation: Bool = false
    
    private let historyStore: any HistoryStorageProtocol
    
    public init(historyStore: any HistoryStorageProtocol = HistoryStore()) {
        self.historyStore = historyStore
    }
    
    public var filteredItems: [CompressionHistoryItem] {
        switch selectedFilter {
        case .all:
            return allItems
        case .photos:
            return allItems.filter { $0.mediaType.lowercased() == "photo" }
        case .videos:
            return allItems.filter { $0.mediaType.lowercased() == "video" }
        }
    }
    
    public var filteredStats: LifetimeStats {
        let items = filteredItems
        let orig = items.reduce(Int64(0)) { $0 + $1.originalByteSize }
        let comp = items.reduce(Int64(0)) { $0 + $1.compressedByteSize }
        let saved = orig - comp
        let pct = orig > 0 ? (Double(saved) / Double(orig)) * 100.0 : 0.0
        let photos = items.filter { $0.mediaType.lowercased() == "photo" }.count
        let videos = items.filter { $0.mediaType.lowercased() == "video" }.count
        return LifetimeStats(
            totalOriginalBytes: orig,
            totalCompressedBytes: comp,
            totalSavedBytes: saved,
            reductionPercentage: pct,
            photoCount: photos,
            videoCount: videos
        )
    }
    
    public func loadHistory() async {
        isLoading = true
        defer { isLoading = false }
        do {
            self.allItems = try await historyStore.loadHistory()
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    public func deleteItem(id: UUID) async {
        do {
            try await historyStore.deleteItem(id: id)
            allItems.removeAll { $0.id == id }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    public func deleteItem(at offsets: IndexSet) async {
        let items = filteredItems
        let targets: [CompressionHistoryItem] = offsets.compactMap { (index: Int) -> CompressionHistoryItem? in
            guard index >= 0 && index < items.count else { return nil }
            return items[index]
        }
        for item in targets {
            await deleteItem(id: item.id)
        }
    }
    
    public func clearAllHistory() async {
        do {
            try await historyStore.clearAllHistory()
            allItems.removeAll()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
