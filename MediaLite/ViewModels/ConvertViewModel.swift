//
//  ConvertViewModel.swift
//  MediaLite
//
//  Created for MediaLite Milestone 5.
//  ViewModel managing video selection, AVAsset inspection, mode selection,
//  live conversion progress, cancellation, AVPlayer preview, and library export.
//

import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers

// MARK: - MovieTransferable

public struct MovieTransferable: Transferable {
    public let url: URL
    
    public init(url: URL) {
        self.url = url
    }
    
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let tempURL = TempFileManager.shared.createTempFileURL(extension: ext)
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return MovieTransferable(url: tempURL)
        }
    }
}

// MARK: - ConvertViewModel

@MainActor
public final class ConvertViewModel: ObservableObject {
    // MARK: - Dependencies
    private let videoProcessor: VideoProcessorProtocol
    private let historyStorage: HistoryStorageProtocol
    private let photoLibrary: PhotoLibraryProtocol
    private let tempFileManager: TempFileManager
    private let appSettings: AppSettings
    
    // MARK: - Selection & Inspection
    @Published public var selectedPickerItem: PhotosPickerItem? = nil {
        didSet {
            if let item = selectedPickerItem {
                Task { [weak self] in
                    guard let self = self else { return }
                    await self.loadSelectedPickerItem(item)
                }
            }
        }
    }
    @Published public var selectedVideoURL: URL? = nil
    @Published public var sourceFileName: String = ""
    @Published public var sourceFileSize: Int64 = 0
    @Published public var videoMetadata: VideoMetadata? = nil
    @Published public var isLoadingVideo: Bool = false
    
    // MARK: - Configuration
    @Published public var selectedMode: VideoProcessingMode
    @Published public var selectedStrength: CompressionStrength
    
    // MARK: - Live Progress
    @Published public var isConverting: Bool = false
    @Published public var conversionProgress: Double = 0.0
    @Published public var progressDescription: String = ""
    
    // MARK: - Results & Player
    @Published public var conversionResult: VideoProcessingResult? = nil
    @Published public var isCompleted: Bool = false
    @Published public var isSavedToLibrary: Bool = false
    @Published public var avPlayer: AVPlayer? = nil
    
    // MARK: - Errors & Alerts
    @Published public var errorMessage: String? = nil
    @Published public var showErrorAlert: Bool = false
    @Published public var saveSuccessMessage: String? = nil
    
    private var activeProcessingTask: Task<VideoProcessingResult, Error>? = nil
    private var progressDrainTask: Task<Void, Never>? = nil
    private var completionTask: Task<Void, Never>? = nil
    
    // MARK: - Initialization
    public init(
        videoProcessor: VideoProcessorProtocol = VideoProcessorService(),
        historyStorage: HistoryStorageProtocol = HistoryStorageService(),
        photoLibrary: PhotoLibraryProtocol = PhotoLibraryService(),
        tempFileManager: TempFileManager = .shared,
        appSettings: AppSettings = .load()
    ) {
        self.videoProcessor = videoProcessor
        self.historyStorage = historyStorage
        self.photoLibrary = photoLibrary
        self.tempFileManager = tempFileManager
        self.appSettings = appSettings
        self.selectedMode = appSettings.defaultVideoMode
        self.selectedStrength = appSettings.defaultCompressionStrength
    }
    
    // MARK: - Video Loading & Inspection
    
    public func loadSelectedPickerItem(_ item: PhotosPickerItem) async {
        isLoadingVideo = true
        defer { isLoadingVideo = false }
        
        do {
            if let movie = try await item.loadTransferable(type: MovieTransferable.self) {
                try await loadVideo(from: movie.url)
            }
        } catch {
            self.errorMessage = "Failed to load video: \(error.localizedDescription)"
            self.showErrorAlert = true
        }
    }
    
    public func loadVideo(from fileURL: URL) async throws {
        self.selectedVideoURL = fileURL
        self.sourceFileName = fileURL.lastPathComponent
        
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber {
            self.sourceFileSize = size.int64Value
        }
        
        if let service = videoProcessor as? VideoProcessorService {
            do {
                self.videoMetadata = try await service.inspectVideo(at: fileURL)
            } catch {
                self.videoMetadata = nil
            }
        } else {
            // Default metadata fallback when mock is used
            let asset = AVURLAsset(url: fileURL)
            let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0.0
            self.videoMetadata = VideoMetadata(
                duration: durationSeconds,
                naturalSize: CGSize(width: 1920, height: 1080),
                preferredTransform: .identity,
                isHDR: false,
                hasAudio: true,
                codec: "avc1"
            )
        }
    }
    
    // MARK: - Conversion
    
    public func startConversion() {
        guard let sourceURL = selectedVideoURL, !isConverting else { return }
        
        isConverting = true
        isCompleted = false
        conversionProgress = 0.0
        progressDescription = "Preparing conversion..."
        conversionResult = nil
        avPlayer = nil
        
        let destinationExt: String
        switch selectedMode {
        case .reduceSize:
            destinationExt = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        case .improveCompatibility, .compressAndConvert:
            destinationExt = "mp4"
        }
        
        let destinationURL = tempFileManager.createTempFileURL(extension: destinationExt)
        
        let (stream, task) = videoProcessor.processVideo(
            at: sourceURL,
            mode: selectedMode,
            strength: selectedStrength,
            destinationURL: destinationURL
        )
        
        activeProcessingTask = task
        
        // Progress drain task
        progressDrainTask = Task { [weak self] in
            for await update in stream {
                guard let self = self, !Task.isCancelled else { break }
                self.conversionProgress = update.fractionCompleted
                self.progressDescription = update.description
            }
        }
        
        // Completion task
        completionTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await task.value
                self.conversionResult = result
                self.conversionProgress = 1.0
                self.progressDescription = "Complete"
                self.avPlayer = AVPlayer(url: result.processedURL)
                self.isCompleted = true
                
                // History log
                let historyItem = CompressionHistoryItem(
                    fileName: self.sourceFileName,
                    mediaType: "video",
                    sourceFormat: sourceURL.pathExtension.uppercased(),
                    targetFormat: result.processedURL.pathExtension.uppercased(),
                    originalByteSize: result.originalSize,
                    compressedByteSize: result.processedSize,
                    compressionStrength: self.selectedStrength,
                    durationSeconds: result.duration,
                    isSavedToLibrary: false
                )
                try? await self.historyStorage.addItem(historyItem)
                
                // Auto-save if enabled
                if self.appSettings.autoSaveToLibrary {
                    _ = try? await self.photoLibrary.saveVideo(at: result.processedURL)
                    self.isSavedToLibrary = true
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) && (error as? VideoProcessingError) != .cancelled && (error as? VideoProcessingError) != .exportCancelled {
                    self.errorMessage = "Video conversion failed: \(error.localizedDescription)"
                    self.showErrorAlert = true
                }
            }
            if !Task.isCancelled {
                self.isConverting = false
            }
        }
    }
    
    public func cancelConversion() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        progressDrainTask?.cancel()
        progressDrainTask = nil
        completionTask?.cancel()
        completionTask = nil
        isConverting = false
        conversionProgress = 0.0
        progressDescription = "Cancelled"
    }
    
    public func saveToPhotoLibrary() async {
        guard let result = conversionResult else { return }
        do {
            _ = try await photoLibrary.saveVideo(at: result.processedURL)
            self.isSavedToLibrary = true
            self.saveSuccessMessage = "Video saved to Photo Library"
        } catch {
            self.errorMessage = "Failed to save video: \(error.localizedDescription)"
            self.showErrorAlert = true
        }
    }
    
    public func resetSelection() {
        cancelConversion()
        if let url = selectedVideoURL {
            try? tempFileManager.cleanupTempFile(at: url)
        }
        if let result = conversionResult {
            try? tempFileManager.cleanupTempFile(at: result.processedURL)
        }
        
        selectedPickerItem = nil
        selectedVideoURL = nil
        sourceFileName = ""
        sourceFileSize = 0
        videoMetadata = nil
        conversionResult = nil
        avPlayer = nil
        isCompleted = false
        isSavedToLibrary = false
        conversionProgress = 0.0
        progressDescription = ""
        errorMessage = nil
        showErrorAlert = false
    }
}
