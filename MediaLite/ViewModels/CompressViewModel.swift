//
//  CompressViewModel.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  ViewModel managing photo multi-selection, compression settings,
//  sequential batch compression, cancellation, history logging, and library export.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
public final class CompressViewModel: ObservableObject {
    // MARK: - Dependencies
    private let compressor: PhotoCompressorProtocol
    private let historyStorage: HistoryStorageProtocol
    private let photoLibrary: PhotoLibraryProtocol
    private let tempFileManager: TempFileManager
    private let appSettings: AppSettings
    
    // MARK: - Configuration & Selection
    @Published public var selectedQuality: CompressionStrength
    @Published public var selectedPickerItems: [PhotosPickerItem] = [] {
        didSet {
            if !selectedPickerItems.isEmpty {
                Task { [weak self] in
                    guard let self = self else { return }
                    await self.loadSelectedPickerItems(self.selectedPickerItems)
                }
            }
        }
    }
    @Published public var selectedItems: [MediaItem] = []
    
    // MARK: - Batch Progress
    @Published public var isProcessing: Bool = false
    @Published public var overallProgress: Double = 0.0
    @Published public var currentProcessingIndex: Int = 0
    @Published public var currentProcessingFileName: String = ""
    
    // MARK: - Results
    @Published public var compressionResults: [PhotoCompressionResult] = []
    @Published public var isCompleted: Bool = false
    @Published public var isSavedToLibrary: Bool = false
    
    // MARK: - Errors & Alerts
    @Published public var errorMessage: String? = nil
    @Published public var showErrorAlert: Bool = false
    @Published public var saveSuccessMessage: String? = nil
    
    private var activeTask: Task<Void, Never>? = nil
    private var processedPickerItems: Set<PhotosPickerItem> = []
    private var pickerItemMap: [UUID: PhotosPickerItem] = [:]
    public var hasUserCustomizedQuality: Bool = false
    
    // MARK: - Initialization
    public init(
        compressor: PhotoCompressorProtocol = PhotoCompressorService(),
        historyStorage: HistoryStorageProtocol = HistoryStorageService(),
        photoLibrary: PhotoLibraryProtocol = PhotoLibraryService(),
        tempFileManager: TempFileManager = .shared,
        appSettings: AppSettings = .load()
    ) {
        self.compressor = compressor
        self.historyStorage = historyStorage
        self.photoLibrary = photoLibrary
        self.tempFileManager = tempFileManager
        self.appSettings = appSettings
        self.selectedQuality = appSettings.defaultCompressionStrength
    }
    
    /// Synchronizes quality with current settings if no active batch and not explicitly overridden.
    public func syncWithDefaultSettingsIfIdle() {
        guard !hasUserCustomizedQuality && !isProcessing && !isCompleted && selectedItems.isEmpty else { return }
        let currentSettings = AppSettings.load()
        self.selectedQuality = currentSettings.defaultCompressionStrength
    }
    
    // MARK: - Computed Statistics
    
    public var totalOriginalSize: Int64 {
        compressionResults.reduce(Int64(0)) { $0 + $1.originalSize }
    }
    
    public var totalCompressedSize: Int64 {
        compressionResults.reduce(Int64(0)) { $0 + $1.compressedSize }
    }
    
    public var totalSavedBytes: Int64 {
        totalOriginalSize - totalCompressedSize
    }
    
    public var totalReductionPercentage: Double {
        guard totalOriginalSize > 0 else { return 0.0 }
        return (Double(totalSavedBytes) / Double(totalOriginalSize)) * 100.0
    }
    
    /// True if total compressed size is strictly larger than total original size.
    public var isSizeIncreased: Bool {
        totalCompressedSize > totalOriginalSize
    }
    
    // MARK: - Item Loading & Management
    
    public func loadSelectedPickerItems(_ items: [PhotosPickerItem]) async {
        let newItems = items.filter { !processedPickerItems.contains($0) }
        guard !newItems.isEmpty else { return }
        
        isProcessing = true
        defer { isProcessing = false }
        
        for item in newItems {
            processedPickerItems.insert(item)
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let inferredFormat = ExifHelper.detectFormat(from: data)
                    let ext = inferredFormat.preferredFilenameExtension ?? "jpg"
                    let tempURL = tempFileManager.createTempFileURL(extension: ext)
                    try data.write(to: tempURL, options: .atomic)
                    
                    var dimensions = CGSize.zero
                    if let meta = try? ExifHelper.extractMetadata(from: data) {
                        dimensions = meta.pixelDimensions
                    }
                    
                    let mediaItem = MediaItem(
                        url: tempURL,
                        data: nil,
                        format: inferredFormat,
                        originalDimensions: dimensions,
                        byteSize: Int64(data.count),
                        state: .queued,
                        thumbnailData: data.count < 500_000 ? data : nil
                    )
                    pickerItemMap[mediaItem.id] = item
                    selectedItems.append(mediaItem)
                }
            } catch {
                self.errorMessage = "Failed to load photo: \(error.localizedDescription)"
                self.showErrorAlert = true
            }
        }
    }
    
    public func addMediaItem(at url: URL, originalFormat: UTType? = nil, data: Data? = nil) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? Int64(data?.count ?? 0)
        let format: UTType
        if let f = originalFormat {
            format = f
        } else if let d = data {
            format = ExifHelper.detectFormat(from: d)
        } else if let detected = UTType(filenameExtension: url.pathExtension) {
            format = detected
        } else {
            format = .jpeg
        }
        
        var dimensions = CGSize.zero
        if let d = data, let meta = try? ExifHelper.extractMetadata(from: d) {
            dimensions = meta.pixelDimensions
        } else if let meta = try? ExifHelper.extractMetadata(from: url) {
            dimensions = meta.pixelDimensions
        }
        
        let mediaItem = MediaItem(
            url: url,
            data: data,
            format: format,
            originalDimensions: dimensions,
            byteSize: size,
            state: .queued,
            thumbnailData: nil
        )
        selectedItems.append(mediaItem)
    }
    
    public func removeItem(at index: Int) {
        guard index >= 0 && index < selectedItems.count else { return }
        let item = selectedItems.remove(at: index)
        if let pickerItem = pickerItemMap.removeValue(forKey: item.id) {
            processedPickerItems.remove(pickerItem)
            selectedPickerItems.removeAll { $0 == pickerItem }
        }
        if let url = item.url {
            try? tempFileManager.cleanupTempFile(at: url)
        }
    }
    
    public func clearSelection() {
        activeTask?.cancel()
        activeTask = nil
        
        for item in selectedItems {
            if let url = item.url {
                try? tempFileManager.cleanupTempFile(at: url)
            }
        }
        for res in compressionResults {
            try? tempFileManager.cleanupTempFile(at: res.compressedURL)
        }
        
        selectedPickerItems.removeAll()
        processedPickerItems.removeAll()
        pickerItemMap.removeAll()
        selectedItems.removeAll()
        compressionResults.removeAll()
        isProcessing = false
        overallProgress = 0.0
        currentProcessingIndex = 0
        currentProcessingFileName = ""
        isCompleted = false
        isSavedToLibrary = false
        errorMessage = nil
        showErrorAlert = false
    }
    
    // MARK: - Batch Compression
    
    public func startCompression() {
        guard !selectedItems.isEmpty && !isProcessing else { return }
        
        isProcessing = true
        isCompleted = false
        for res in compressionResults {
            try? tempFileManager.cleanupTempFile(at: res.compressedURL)
        }
        compressionResults.removeAll()
        overallProgress = 0.0
        currentProcessingIndex = 0
        
        activeTask = Task { [weak self] in
            guard let self = self else { return }
            let total = self.selectedItems.count
            
            for (idx, item) in self.selectedItems.enumerated() {
                if Task.isCancelled { break }
                
                self.currentProcessingIndex = idx
                self.currentProcessingFileName = item.suggestedFileName
                self.overallProgress = Double(idx) / Double(total)
                
                guard let sourceURL = item.url else { continue }
                let ext = item.format.preferredFilenameExtension ?? "jpg"
                let destURL = self.tempFileManager.createTempFileURL(extension: ext)
                
                do {
                    let result = try await self.compressor.compressPhoto(
                        at: sourceURL,
                        strength: self.selectedQuality,
                        destinationURL: destURL
                    )
                    
                    if Task.isCancelled {
                        try? self.tempFileManager.cleanupTempFile(at: destURL)
                        break
                    }
                    
                    self.compressionResults.append(result)
                    
                    // Log to history
                    let historyItem = CompressionHistoryItem(
                        fileName: item.suggestedFileName,
                        mediaType: "photo",
                        sourceFormat: item.format.identifier,
                        targetFormat: result.format.identifier,
                        originalByteSize: result.originalSize,
                        compressedByteSize: result.compressedSize,
                        compressionStrength: self.selectedQuality,
                        isSavedToLibrary: false
                    )
                    try? await self.historyStorage.addItem(historyItem)
                    
                    // Auto-save if enabled
                    if self.appSettings.autoSaveToLibrary {
                        _ = try? await self.photoLibrary.saveImage(at: result.compressedURL)
                    }
                } catch {
                    try? self.tempFileManager.cleanupTempFile(at: destURL)
                    if !Task.isCancelled && !(error is CancellationError) {
                        self.errorMessage = "Failed to compress \(item.suggestedFileName): \(error.localizedDescription)"
                        self.showErrorAlert = true
                    }
                }
            }
            
            if !Task.isCancelled {
                self.overallProgress = 1.0
                self.isCompleted = true
                if self.appSettings.autoSaveToLibrary {
                    self.isSavedToLibrary = true
                }
                self.isProcessing = false
            }
        }
    }
    
    public func cancelCompression() {
        activeTask?.cancel()
        activeTask = nil
        isProcessing = false
        for res in compressionResults {
            try? tempFileManager.cleanupTempFile(at: res.compressedURL)
        }
        compressionResults.removeAll()
    }
    
    public func saveAllToLibrary() async {
        guard !compressionResults.isEmpty else { return }
        
        var savedCount = 0
        for result in compressionResults {
            do {
                _ = try await photoLibrary.saveImage(at: result.compressedURL)
                savedCount += 1
            } catch {
                self.errorMessage = "Error saving to library: \(error.localizedDescription)"
                self.showErrorAlert = true
            }
        }
        
        if savedCount > 0 {
            self.isSavedToLibrary = true
            self.saveSuccessMessage = "Saved \(savedCount) photo\(savedCount == 1 ? "" : "s") to Photo Library"
        }
    }
}
