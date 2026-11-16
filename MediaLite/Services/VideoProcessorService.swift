//
//  VideoProcessorService.swift
//  MediaLite
//
//  Production-grade AVFoundation video processing and transcoding engine.
//  Implements VideoProcessorProtocol with support for:
//  - Mode 1: Reduce Size (bitrate compression preserving source codec & container)
//  - Mode 2: Universal Compatibility (transcode to H.264/AAC/MP4)
//  - Mode 3: Compress & Convert (H.264/AAC/MP4 with dimension & bitrate downscaling)
//  - HDR detection & Rec. 709 SDR tone mapping via AVVideoComposition
//  - Aspect ratio and orientation transform preservation via preferredTransform
//  - Silent video protection (safe handling of videos without audio tracks)
//  - Live progress reporting via AsyncStream
//  - Cooperative cancellation and temp file cleanup
//  - Video inspection metadata helper
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - VideoProcessingError

/// Strongly typed error representation for video processing failures.
public enum VideoProcessingError: LocalizedError, Sendable, Equatable {
    case fileNotFound(URL)
    case zeroByteFile(URL)
    case unreadableAsset(String)
    case zeroDuration(URL)
    case trackNotFound(String)
    case noVideoTrack(URL)
    case corruptVideo(String)
    case destinationCreationFailed(URL)
    case compositionFailed(String)
    case exportFailed(String)
    case transcodeFailed(String)
    case exportCancelled
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Source video file not found at '\(url.path)'."
        case .zeroByteFile(let url):
            return "Source video file at '\(url.path)' is empty (0 bytes)."
        case .unreadableAsset(let reason):
            return "Video asset is unreadable: \(reason)."
        case .zeroDuration(let url):
            return "Video asset at '\(url.path)' has zero or invalid duration."
        case .trackNotFound(let reason):
            return "Required media track not found: \(reason)."
        case .noVideoTrack(let url):
            return "No video track found in asset at '\(url.path)'."
        case .corruptVideo(let reason):
            return "Corrupted or unreadable video file: \(reason)."
        case .destinationCreationFailed(let url):
            return "Failed to initialize destination video writer at '\(url.path)'."
        case .compositionFailed(let reason):
            return "Failed to build video composition: \(reason)."
        case .exportFailed(let reason):
            return "Video export failed: \(reason)."
        case .transcodeFailed(let reason):
            return "Video transcoding failed: \(reason)."
        case .exportCancelled, .cancelled:
            return "Video processing operation was cancelled."
        }
    }
}

// MARK: - VideoMetadata

/// Inspected metadata of a video asset.
public struct VideoMetadata: Sendable, Equatable {
    public let duration: Double
    public let naturalSize: CGSize
    public let preferredTransform: CGAffineTransform
    public let isHDR: Bool
    public let hasAudio: Bool
    public let codec: String

    public init(
        duration: Double,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        isHDR: Bool,
        hasAudio: Bool,
        codec: String
    ) {
        self.duration = duration
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.isHDR = isHDR
        self.hasAudio = hasAudio
        self.codec = codec
    }
}

// MARK: - VideoProcessorService

/// Production implementation of VideoProcessorProtocol using AVFoundation reader/writer pipelines.
public final class VideoProcessorService: VideoProcessorProtocol, @unchecked Sendable {

    public init() {}

    // MARK: - VideoProcessorProtocol

    public func processVideo(
        at sourceURL: URL,
        mode: VideoProcessingMode,
        strength: CompressionStrength,
        destinationURL: URL
    ) -> (stream: AsyncStream<VideoProcessingProgress>, task: Task<VideoProcessingResult, Error>) {

        var continuation: AsyncStream<VideoProcessingProgress>.Continuation?
        let stream = AsyncStream<VideoProcessingProgress> { cont in
            continuation = cont
        }

        let task = Task<VideoProcessingResult, Error> {
            do {
                let result = try await self.executeProcessing(
                    sourceURL: sourceURL,
                    mode: mode,
                    strength: strength,
                    destinationURL: destinationURL,
                    continuation: continuation
                )
                continuation?.finish()
                return result
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destinationURL)
                continuation?.finish()
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                continuation?.finish()
                throw error
            }
        }

        return (stream: stream, task: task)
    }

    // MARK: - Video Inspection

    /// Inspects the video at `sourceURL` and returns comprehensive metadata.
    public func inspectVideo(at sourceURL: URL) async throws -> VideoMetadata {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VideoProcessingError.fileNotFound(sourceURL)
        }
        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let originalByteSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        guard originalByteSize > 0 else {
            throw VideoProcessingError.zeroByteFile(sourceURL)
        }

        let asset = AVURLAsset(url: sourceURL)

        // 1. Check video tracks first: audio-only containers fail fast with .noVideoTrack
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw VideoProcessingError.noVideoTrack(sourceURL)
        }

        // 2. Check duration on video assets: zero duration videos fail with .zeroDuration
        let durationTime = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(durationTime)
        guard durationSeconds > 0, !durationSeconds.isNaN else {
            throw VideoProcessingError.zeroDuration(sourceURL)
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let isHDR = await Self.isHDRVideo(track: videoTrack)

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let hasAudio = !audioTracks.isEmpty

        var codecName = "H.264"
        if let formatDescriptions = try? await videoTrack.load(.formatDescriptions) {
            for desc in formatDescriptions {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                if subType == kCMVideoCodecType_HEVC {
                    codecName = "HEVC"
                    break
                } else if subType == kCMVideoCodecType_H264 {
                    codecName = "H.264"
                    break
                }
            }
        }

        return VideoMetadata(
            duration: durationSeconds,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            isHDR: isHDR,
            hasAudio: hasAudio,
            codec: codecName
        )
    }

    // MARK: - HDR Detection

    /// Detects whether an AVAssetTrack contains High Dynamic Range (HDR) content.
    /// Checks track.hasMediaCharacteristic(.containsHDRVideo) first, then falls back
    /// to inspecting CMFormatDescription extensions for HDR color primaries and transfer functions.
    public static func isHDRVideo(track: AVAssetTrack) async -> Bool {
        // 1. Primary check: AVMediaCharacteristic.containsHDRVideo
        if track.hasMediaCharacteristic(.containsHDRVideo) {
            return true
        }

        // 2. Fallback check: CMFormatDescription extensions
        guard let descriptions = try? await track.load(.formatDescriptions) else {
            return false
        }

        for desc in descriptions {
            guard let extensions = CMFormatDescriptionGetExtensions(desc) as? [CFString: Any] else {
                continue
            }

            // Transfer functions indicating HDR (HLG or PQ / SMPTE ST 2084)
            if let transfer = extensions[kCVImageBufferTransferFunctionKey] as? String {
                if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) ||
                   transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) ||
                   transfer.contains("2100") ||
                   transfer.contains("2084") ||
                   transfer.contains("HLG") ||
                   transfer.contains("PQ") {
                    return true
                }
            }

            // Color primaries indicating wide gamut / HDR (ITU-R 2020 / 2100)
            if let primaries = extensions[kCVImageBufferColorPrimariesKey] as? String {
                if primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) ||
                   primaries.contains("2020") {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - SDR Tone Mapping Composition

    /// Builds an AVMutableVideoComposition configured with ITU-R 709 SDR tone mapping parameters.
    public static func buildSDRVideoComposition(
        for asset: AVAsset,
        track: AVAssetTrack,
        renderSize: CGSize? = nil
    ) async throws -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let naturalSize = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        composition.renderSize = renderSize ?? naturalSize

        let nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 30.0
        let fps = nominalFrameRate > 0 ? Int32(round(nominalFrameRate)) : 30
        composition.frameDuration = CMTime(value: 1, timescale: max(1, fps))

        let durationTime = (try? await asset.load(.duration)) ?? CMTime(value: 1, timescale: 1)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: durationTime)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // Scale appropriately if renderSize differs from naturalSize while preserving upright orientation
        let sx = naturalSize.width > 0 ? composition.renderSize.width / naturalSize.width : 1.0
        let sy = naturalSize.height > 0 ? composition.renderSize.height / naturalSize.height : 1.0
        layerInstruction.setTransform(CGAffineTransform(scaleX: sx, y: sy), at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        return composition
    }

    // MARK: - Private Pipeline Execution

    private func executeProcessing(
        sourceURL: URL,
        mode: VideoProcessingMode,
        strength: CompressionStrength,
        destinationURL: URL,
        continuation: AsyncStream<VideoProcessingProgress>.Continuation?
    ) async throws -> VideoProcessingResult {

        // 1. Validate file existence
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VideoProcessingError.fileNotFound(sourceURL)
        }

        // 2. Validate non-zero file size
        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let originalByteSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? 0
        guard originalByteSize > 0 else {
            throw VideoProcessingError.zeroByteFile(sourceURL)
        }

        try Task.checkCancellation()
        continuation?.yield(VideoProcessingProgress(fractionCompleted: 0.05, description: "Inspecting video tracks"))

        // 3. Load asset and tracks
        let asset = AVURLAsset(url: sourceURL)

        // Check video tracks first: audio-only containers fail fast with .noVideoTrack
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw VideoProcessingError.corruptVideo(error.localizedDescription)
        }
        guard let videoTrack = videoTracks.first else {
            throw VideoProcessingError.noVideoTrack(sourceURL)
        }

        // Check duration on video assets: zero duration videos fail with .zeroDuration
        let durationTime: CMTime
        do {
            durationTime = try await asset.load(.duration)
        } catch {
            throw VideoProcessingError.corruptVideo(error.localizedDescription)
        }
        let durationSeconds = CMTimeGetSeconds(durationTime)
        guard durationSeconds > 0, !durationSeconds.isNaN else {
            throw VideoProcessingError.zeroDuration(sourceURL)
        }

        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        guard naturalSize.width > 0 && naturalSize.height > 0 else {
            throw VideoProcessingError.corruptVideo("Invalid video dimensions")
        }

        let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let isHDR = await Self.isHDRVideo(track: videoTrack)

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let hasAudio = !audioTracks.isEmpty

        try Task.checkCancellation()
        continuation?.yield(VideoProcessingProgress(fractionCompleted: 0.15, description: "Configuring transcode pipeline"))

        // 4. Prepare destination directory & purge prior destination
        let destinationFolder = destinationURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: destinationFolder.path) {
            do {
                try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            } catch {
                throw VideoProcessingError.destinationCreationFailed(destinationURL)
            }
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        // 5. Determine target file type
        let destExt = destinationURL.pathExtension.lowercased()
        let outputFileType: AVFileType
        switch destExt {
        case "mov":
            outputFileType = .mov
        case "m4v":
            outputFileType = .m4v
        default:
            outputFileType = .mp4
        }

        // Determine source video codec
        var sourceCodec: AVVideoCodecType = .h264
        if let descriptions = try? await videoTrack.load(.formatDescriptions) {
            for desc in descriptions {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                if subType == kCMVideoCodecType_HEVC {
                    sourceCodec = .hevc
                    break
                } else if subType == kCMVideoCodecType_H264 {
                    sourceCodec = .h264
                    break
                }
            }
        }

        // Target codec selection:
        // - Mode 1 (.reduceSize): preserves source codec
        // - Mode 2 (.improveCompatibility): transcode universally to H.264
        // - Mode 3 (.compressAndConvert): transcode to H.264 with dimension & bitrate scaling
        let targetCodec: AVVideoCodecType
        switch mode {
        case .reduceSize:
            targetCodec = sourceCodec
        case .improveCompatibility, .compressAndConvert:
            targetCodec = .h264
        }

        // 6. Calculate dimensions and bitrate based on Mode and CompressionStrength
        let dimensionScale: CGFloat = (mode == .compressAndConvert) ? strength.dimensionScale : 1.0
        let targetWidth = max(2, Int(round(naturalSize.width * dimensionScale)) / 2 * 2)
        let targetHeight = max(2, Int(round(naturalSize.height * dimensionScale)) / 2 * 2)

        let bitrateFactor: Double = {
            switch strength {
            case .low: return 0.90
            case .medium: return 0.75
            case .high: return 0.55
            }
        }()
        let baseBitrate = Int(Double(targetWidth * targetHeight) * 1.2)
        var targetBitrate = max(250_000, Int(Double(baseBitrate) * bitrateFactor))

        // Cap target bitrate based on source bitrate if duration > 0 to guarantee compression savings
        if durationSeconds > 0 {
            let sourceBitrate = Double(originalByteSize * 8) / durationSeconds
            if sourceBitrate > 100_000 {
                let maxAllowedBitrate = max(250_000, Int(sourceBitrate * bitrateFactor))
                targetBitrate = min(targetBitrate, maxAllowedBitrate)
            }
        }

        // 7. Configure AVAssetWriter
        guard let writer = try? AVAssetWriter(outputURL: destinationURL, fileType: outputFileType) else {
            throw VideoProcessingError.destinationCreationFailed(destinationURL)
        }

        // Video compression settings: Rec. 709 SDR tone mapping
        var compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate,
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            AVVideoMaxKeyFrameIntervalKey: 30,
            AVVideoExpectedSourceFrameRateKey: 30
        ]

        if targetCodec == .h264 {
            compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: targetCodec,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Preserve orientation / rotation transform
        videoInput.transform = preferredTransform

        guard writer.canAdd(videoInput) else {
            throw VideoProcessingError.destinationCreationFailed(destinationURL)
        }
        writer.add(videoInput)

        // Audio compression settings: AAC-LC 128kbps stereo 44.1kHz (only if source has audio)
        var audioInput: AVAssetWriterInput?
        if hasAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: 128000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioInput = aInput
            }
        }

        try Task.checkCancellation()
        continuation?.yield(VideoProcessingProgress(fractionCompleted: 0.25, description: "Initializing reader and writer"))

        guard writer.startWriting() else {
            let errorMsg = writer.error?.localizedDescription ?? "Failed to start writing"
            throw VideoProcessingError.exportFailed(errorMsg)
        }
        writer.startSession(atSourceTime: .zero)

        // 8. Configure AVAssetReader
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw VideoProcessingError.corruptVideo("Failed to initialize AVAssetReader")
        }

        let readerVideoOutput: AVAssetReaderOutput
        if isHDR {
            let composition = try await Self.buildSDRVideoComposition(
                for: asset,
                track: videoTrack,
                renderSize: CGSize(width: targetWidth, height: targetHeight)
            )
            let compOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            )
            compOutput.videoComposition = composition
            readerVideoOutput = compOutput
        } else {
            readerVideoOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            )
        }

        guard reader.canAdd(readerVideoOutput) else {
            throw VideoProcessingError.corruptVideo("Cannot add reader video output")
        }
        reader.add(readerVideoOutput)

        var readerAudioOutput: AVAssetReaderTrackOutput?
        if hasAudio, let audioTrack = audioTracks.first, audioInput != nil {
            let aOutput = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            if reader.canAdd(aOutput) {
                reader.add(aOutput)
                readerAudioOutput = aOutput
            }
        }

        guard reader.startReading() else {
            throw VideoProcessingError.corruptVideo(reader.error?.localizedDescription ?? "Reader failed to start")
        }

        // 9. Transfer video & audio samples in an interleaved fashion to prevent muxer backpressure deadlocks
        continuation?.yield(VideoProcessingProgress(fractionCompleted: 0.35, description: "Encoding media streams"))

        var videoFinished = false
        var audioFinished = (audioInput == nil || readerAudioOutput == nil)
        var lastReportedFraction = 0.35

        while !videoFinished || !audioFinished {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destinationURL)
                throw CancellationError()
            }

            var madeProgress = false

            // Process video frame if writer input is ready
            if !videoFinished && videoInput.isReadyForMoreMediaData {
                if let sampleBuffer = readerVideoOutput.copyNextSampleBuffer() {
                    videoInput.append(sampleBuffer)
                    madeProgress = true

                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let currentSec = CMTimeGetSeconds(pts)
                    if currentSec > 0 && durationSeconds > 0 {
                        let progress = 0.35 + 0.40 * min(1.0, currentSec / durationSeconds)
                        if progress - lastReportedFraction >= 0.10 {
                            lastReportedFraction = progress
                            continuation?.yield(VideoProcessingProgress(fractionCompleted: progress, description: "Encoding video stream"))
                        }
                    }
                } else {
                    videoInput.markAsFinished()
                    videoFinished = true
                    madeProgress = true
                }
            }

            // Process audio frame if writer input is ready
            if !audioFinished, let aInput = audioInput, let rOutput = readerAudioOutput, aInput.isReadyForMoreMediaData {
                if let audioBuffer = rOutput.copyNextSampleBuffer() {
                    aInput.append(audioBuffer)
                    madeProgress = true

                    let pts = CMSampleBufferGetPresentationTimeStamp(audioBuffer)
                    let currentSec = CMTimeGetSeconds(pts)
                    if currentSec > 0 && durationSeconds > 0 {
                        let progress = 0.75 + 0.15 * min(1.0, currentSec / durationSeconds)
                        if progress - lastReportedFraction >= 0.10 {
                            lastReportedFraction = progress
                            continuation?.yield(VideoProcessingProgress(fractionCompleted: progress, description: "Encoding audio stream"))
                        }
                    }
                } else {
                    aInput.markAsFinished()
                    audioFinished = true
                    madeProgress = true
                }
            }

            if reader.status == .failed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destinationURL)
                throw VideoProcessingError.corruptVideo(reader.error?.localizedDescription ?? "Reader failed during video processing")
            }

            if writer.status == .failed || writer.status == .cancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destinationURL)
                throw VideoProcessingError.exportFailed(writer.error?.localizedDescription ?? "Writer failed during processing")
            }

            if !madeProgress {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        if Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destinationURL)
            throw CancellationError()
        }

        // 11. Finalize writer
        continuation?.yield(VideoProcessingProgress(fractionCompleted: 0.92, description: "Finalizing container"))

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                c.resume()
            }
        }

        if writer.status == .failed || writer.status == .cancelled {
            try? FileManager.default.removeItem(at: destinationURL)
            if Task.isCancelled {
                throw CancellationError()
            }
            let errorMsg = writer.error?.localizedDescription ?? "Writer failed"
            throw VideoProcessingError.exportFailed(errorMsg)
        }

        continuation?.yield(VideoProcessingProgress(fractionCompleted: 1.0, description: "Transcoding complete"))

        // 12. Build and return result
        let processedAttrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let processedByteSize = (processedAttrs[.size] as? NSNumber)?.int64Value ?? 0

        return VideoProcessingResult(
            originalURL: sourceURL,
            processedURL: destinationURL,
            originalSize: originalByteSize,
            processedSize: processedByteSize,
            duration: durationSeconds
        )
    }
}
