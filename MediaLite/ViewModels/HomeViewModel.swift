//
//  HomeViewModel.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  ViewModel powering the Home Dashboard view, aggregating lifetime savings
//  and presenting recent processing history.
//

import Foundation
import SwiftUI

@MainActor
public final class HomeViewModel: ObservableObject {
    @Published public private(set) var stats: LifetimeStats = LifetimeStats()
    @Published public private(set) var recentItems: [CompressionHistoryItem] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    
    private let historyStore: any HistoryStorageProtocol
    
    public init(historyStore: any HistoryStorageProtocol = HistoryStore()) {
        self.historyStore = historyStore
    }
    
    public func loadDashboardData() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let items = try await historyStore.loadHistory()
            self.recentItems = Array(items.prefix(5))
            
            let totalOriginal = items.reduce(Int64(0)) { $0 + $1.originalByteSize }
            let totalCompressed = items.reduce(Int64(0)) { $0 + $1.compressedByteSize }
            let totalSaved = totalOriginal - totalCompressed
            let percentage = totalOriginal > 0 ? (Double(totalSaved) / Double(totalOriginal)) * 100.0 : 0.0
            let photos = items.filter { $0.mediaType.lowercased() == "photo" }.count
            let videos = items.filter { $0.mediaType.lowercased() == "video" }.count
            
            self.stats = LifetimeStats(
                totalOriginalBytes: totalOriginal,
                totalCompressedBytes: totalCompressed,
                totalSavedBytes: totalSaved,
                reductionPercentage: percentage,
                photoCount: photos,
                videoCount: videos
            )
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    public func refresh() async {
        await loadDashboardData()
    }
}
