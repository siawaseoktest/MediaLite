//
//  SyntheticAssetGenerator.swift
//  MediaLiteTests
//
//  Production-grade synthetic media asset generator for unit and end-to-end tests.
//  Dynamically synthesizes valid images, videos, audio streams, and corrupted test files
//  using Apple native frameworks (CoreGraphics, ImageIO, AVFoundation, AudioToolbox).
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox
#if canImport(VideoToolbox)
import VideoToolbox
#endif

// MARK: - Synthetic Asset Errors

public enum SyntheticAssetError: LocalizedError, Sendable {
    case contextCreationFailed
    case imageCreationFailed
    case destinationCreationFailed
    case finalizationFailed
    case writerInitializationFailed(Error)
    case writerConfigurationFailed(String)
    case writerFailed(String)
    case invalidParameters(String)
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "Failed to create CGContext for synthetic asset."
        case .imageCreationFailed:
            return "Failed to create CGImage from context."
        case .destinationCreationFailed:
            return "Failed to create CGImageDestination for output URL."
        case .finalizationFailed:
            return "Failed to finalize CGImageDestination."
        case .writerInitializationFailed(let error):
            return "AVAssetWriter failed to initialize: \(error.localizedDescription)"
        case .writerConfigurationFailed(let reason):
            return "AVAssetWriter input configuration failed: \(reason)"
        case .writerFailed(let reason):
            return "AVAssetWriter failed during export: \(reason)"
        case .invalidParameters(let reason):
            return "Invalid parameters for asset generation: \(reason)"
        case .fileSystemError(let reason):
            return "File system operation failed: \(reason)"
        }
    }
}

// MARK: - SyntheticAssetGenerator

public enum SyntheticAssetGenerator {

    // MARK: - 1. JPEG Image Generation

    /// Synthesizes a valid JPEG image file with configurable dimensions, fill color, and optional EXIF/TIFF metadata.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - color: Background fill color.
    ///   - hasExif: If true, attaches standard EXIF and TIFF metadata tags.
    ///   - destinationURL: Optional custom file URL. If nil, creates a UUID-named file in the temporary directory.
    /// - Returns: File URL of the generated JPEG asset.
    @discardableResult
    public static func createJPEG(
        width: Int = 200,
        height: Int = 200,
        color: CGColor = CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1.0),
        hasExif: Bool = true,
        destinationURL: URL? = nil
    ) throws -> URL {
        let validWidth = max(1, width)
        let validHeight = max(1, height)

        let targetURL = destinationURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_\(UUID().uuidString)")
            .appendingPathExtension("jpg")

        try prepareDestination(at: targetURL)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SyntheticAssetError.contextCreationFailed
        }

        guard let context = CGContext(
            data: nil,
            width: validWidth,
            height: validHeight,
            bitsPerComponent: 8,
            bytesPerRow: validWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw SyntheticAssetError.contextCreationFailed
        }

        // Base color fill
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: validWidth, height: validHeight))

        // High-contrast diagonal line to produce non-trivial frequency content for lossy compression
        context.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        context.setLineWidth(max(1.0, CGFloat(min(validWidth, validHeight)) * 0.05))
        context.strokeLineSegments(between: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: validWidth, y: validHeight)
        ])

        guard let image = context.makeImage() else {
            throw SyntheticAssetError.imageCreationFailed
        }

        guard let destination = CGImageDestinationCreateWithURL(
            targetURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw SyntheticAssetError.destinationCreationFailed
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]

        if hasExif {
            let exifDict: [CFString: Any] = [
                kCGImagePropertyExifColorSpace: 1,
                kCGImagePropertyExifPixelXDimension: validWidth,
                kCGImagePropertyExifPixelYDimension: validHeight,
                kCGImagePropertyExifDateTimeOriginal: "2026:01:01 12:00:00",
                kCGImagePropertyExifUserComment: "Synthetic MediaLite Asset"
            ]
            let tiffDict: [CFString: Any] = [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 15 Pro",
                kCGImagePropertyTIFFSoftware: "MediaLite Synthetic Generator",
                kCGImagePropertyTIFFDateTime: "2026:01:01 12:00:00",
                kCGImagePropertyTIFFOrientation: 1
            ]
            properties[kCGImagePropertyExifDictionary] = exifDict
            properties[kCGImagePropertyTIFFDictionary] = tiffDict
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SyntheticAssetError.finalizationFailed
        }

        return targetURL
    }

    // MARK: - 2. PNG Image Generation

    /// Synthesizes a valid PNG image file with optional alpha channel transparency.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - hasAlpha: If true, generates semi-transparent and transparent pixel regions.
    ///   - destinationURL: Optional custom file URL. If nil, creates a UUID-named file in the temporary directory.
    /// - Returns: File URL of the generated PNG asset.
    @discardableResult
    public static func createPNG(
        width: Int = 200,
        height: Int = 200,
        hasAlpha: Bool = true,
        destinationURL: URL? = nil
    ) throws -> URL {
        let validWidth = max(1, width)
        let validHeight = max(1, height)

        let targetURL = destinationURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_\(UUID().uuidString)")
            .appendingPathExtension("png")

        try prepareDestination(at: targetURL)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SyntheticAssetError.contextCreationFailed
        }

        let bitmapInfo = hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: validWidth,
            height: validHeight,
            bitsPerComponent: 8,
            bytesPerRow: validWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw SyntheticAssetError.contextCreationFailed
        }

        if hasAlpha {
            // Clear entire background to complete transparency
            context.clear(CGRect(x: 0, y: 0, width: validWidth, height: validHeight))

            // Left half: 50% opacity blue
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.5, blue: 0.9, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: validWidth / 2, height: validHeight))

            // Right half: 75% opacity red
            context.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.3, alpha: 0.75))
            context.fill(CGRect(x: validWidth / 2, y: 0, width: validWidth - (validWidth / 2), height: validHeight))

            // Center: 90% opacity white circle
            let radius = CGFloat(min(validWidth, validHeight)) * 0.2
            context.setFillColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.9))
            context.fillEllipse(in: CGRect(
                x: CGFloat(validWidth) / 2.0 - radius,
                y: CGFloat(validHeight) / 2.0 - radius,
                width: radius * 2,
                height: radius * 2
            ))
        } else {
            // Opaque emerald background with amber central block
            context.setFillColor(CGColor(srgbRed: 0.15, green: 0.75, blue: 0.35, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: validWidth, height: validHeight))

            context.setFillColor(CGColor(srgbRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0))
            context.fill(CGRect(
                x: validWidth / 4,
                y: validHeight / 4,
                width: validWidth / 2,
                height: validHeight / 2
            ))
        }

        guard let image = context.makeImage() else {
            throw SyntheticAssetError.imageCreationFailed
        }

        guard let destination = CGImageDestinationCreateWithURL(
            targetURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SyntheticAssetError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SyntheticAssetError.finalizationFailed
        }

        return targetURL
    }

    // MARK: - 3. HEIC Image Generation

    /// Synthesizes a valid HEIC image container with specific EXIF orientation and metadata.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - orientation: Image orientation flag (e.g. .up, .down, .left, .right).
    ///   - destinationURL: Optional custom file URL. If nil, creates a UUID-named file in the temporary directory.
    /// - Returns: File URL of the generated HEIC asset.
    @discardableResult
    public static func createHEIC(
        width: Int = 200,
        height: Int = 200,
        orientation: CGImagePropertyOrientation = .up,
        destinationURL: URL? = nil
    ) throws -> URL {
        let validWidth = max(1, width)
        let validHeight = max(1, height)

        let targetURL = destinationURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_\(UUID().uuidString)")
            .appendingPathExtension("heic")

        try prepareDestination(at: targetURL)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SyntheticAssetError.contextCreationFailed
        }

        guard let context = CGContext(
            data: nil,
            width: validWidth,
            height: validHeight,
            bitsPerComponent: 8,
            bytesPerRow: validWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SyntheticAssetError.contextCreationFailed
        }

        // Violet background
        context.setFillColor(CGColor(srgbRed: 0.4, green: 0.2, blue: 0.7, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: validWidth, height: validHeight))

        // Asymmetric gold indicator in the top-left quadrant to visually verify orientation changes
        context.setFillColor(CGColor(srgbRed: 1.0, green: 0.9, blue: 0.1, alpha: 1.0))
        context.fill(CGRect(
            x: 0,
            y: 0,
            width: max(1, validWidth / 3),
            height: max(1, validHeight / 3)
        ))

        guard let image = context.makeImage() else {
            throw SyntheticAssetError.imageCreationFailed
        }

        guard let destination = CGImageDestinationCreateWithURL(
            targetURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw SyntheticAssetError.destinationCreationFailed
        }

        let exifDict: [CFString: Any] = [
            kCGImagePropertyExifPixelXDimension: validWidth,
            kCGImagePropertyExifPixelYDimension: validHeight,
            kCGImagePropertyExifDateTimeOriginal: "2026:01:01 12:00:00"
        ]

        let tiffDict: [CFString: Any] = [
            kCGImagePropertyTIFFOrientation: orientation.rawValue,
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "iPhone 15 Pro",
            kCGImagePropertyTIFFSoftware: "MediaLite Synthetic Generator"
        ]

        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyExifDictionary: exifDict,
            kCGImagePropertyTIFFDictionary: tiffDict
        ]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SyntheticAssetError.finalizationFailed
        }

        return targetURL
    }

    // MARK: - 4. Synthetic Video Generation

    /// Synthesizes a valid MP4 or MOV video file using AVAssetWriter and CVPixelBufferAdaptor.
    ///
    /// Supports H.264, HEVC 10-bit HLG (HDR), stereo AAC audio, silent video, and custom transform matrices.
    ///
    /// - Parameters:
    ///   - durationSeconds: Total duration of the video.
    ///   - fps: Frames per second.
    ///   - resolution: Pixel dimensions (e.g. 1920x1080).
    ///   - hasAudio: If true, writes a synchronized 44.1kHz AAC stereo audio track. If false, creates a silent video.
    ///   - isHDR: If true, configures 10-bit HLG HEVC with ITU-R 2020 color primaries.
    ///   - transform: Affine transform applied to video track (e.g. 90-degree portrait rotation).
    ///   - destinationURL: Optional custom destination URL. If nil, creates a temporary file.
    /// - Returns: File URL of the generated video asset.
    @discardableResult
    public static func createVideo(
        durationSeconds: Double = 1.0,
        fps: Int32 = 30,
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        hasAudio: Bool = true,
        isHDR: Bool = false,
        transform: CGAffineTransform = .identity,
        destinationURL: URL? = nil
    ) async throws -> URL {
        guard durationSeconds > 0, fps > 0, resolution.width > 0, resolution.height > 0 else {
            throw SyntheticAssetError.invalidParameters("Duration, fps, and resolution dimensions must be positive.")
        }

        let ext = destinationURL?.pathExtension.lowercased() ?? (isHDR ? "mov" : "mp4")
        let targetURL = destinationURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "mp4" : ext)

        try prepareDestination(at: targetURL)

        let fileType: AVFileType = (targetURL.pathExtension.lowercased() == "mov") ? .mov : .mp4

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: targetURL, fileType: fileType)
        } catch {
            throw SyntheticAssetError.writerInitializationFailed(error)
        }

        let videoWidth = Int(resolution.width)
        let videoHeight = Int(resolution.height)

        var compressionProps: [String: Any] = [:]
        if isHDR {
            compressionProps[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_ITU_R_2020
            compressionProps[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_2100_HLG
            compressionProps[AVVideoYCbCrMatrixKey] = AVVideoYCbCrMatrix_ITU_R_2020
            #if canImport(VideoToolbox)
            compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            #endif
        } else {
            compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compressionProps[AVVideoAverageBitRateKey] = max(1_000_000, videoWidth * videoHeight * 3)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: isHDR ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform

        guard writer.canAdd(videoInput) else {
            throw SyntheticAssetError.writerConfigurationFailed("Cannot add video input to AVAssetWriter.")
        }
        writer.add(videoInput)

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

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

        guard writer.startWriting() else {
            throw SyntheticAssetError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // 1. Write Video Frames
        let totalFrames = max(1, Int(ceil(durationSeconds * Double(fps))))
        for frameIndex in 0..<totalFrames {
            let videoWaitStart = Date()
            while !videoInput.isReadyForMoreMediaData {
                if Date().timeIntervalSince(videoWaitStart) > 10.0 {
                    throw SyntheticAssetError.writerFailed("Timed out waiting for video input readiness")
                }
                if writer.status == .failed || writer.status == .cancelled {
                    throw SyntheticAssetError.writerFailed(writer.error?.localizedDescription ?? "Writer failed during video feed")
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            if let pixelBuffer = makePixelBuffer(
                width: videoWidth,
                height: videoHeight,
                frameIndex: frameIndex,
                totalFrames: totalFrames,
                isHDR: isHDR
            ) {
                adaptor.append(pixelBuffer, withPresentationTime: pts)
            }
        }
        videoInput.markAsFinished()

        // 2. Write Audio Buffers (if enabled)
        if let audioInput = audioInput {
            let sampleRate: Double = 44100.0
            let samplesPerBuffer: CMItemCount = 1024
            let totalAudioSamples = Int(durationSeconds * sampleRate)
            var samplesWritten = 0

            while samplesWritten < totalAudioSamples {
                let audioWaitStart = Date()
                while !audioInput.isReadyForMoreMediaData {
                    if Date().timeIntervalSince(audioWaitStart) > 10.0 {
                        throw SyntheticAssetError.writerFailed("Timed out waiting for audio input readiness")
                    }
                    if writer.status == .failed || writer.status == .cancelled {
                        throw SyntheticAssetError.writerFailed(writer.error?.localizedDescription ?? "Writer failed during audio feed")
                    }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }

                let framesToGenerate = min(samplesPerBuffer, CMItemCount(totalAudioSamples - samplesWritten))
                let pts = CMTime(value: CMTimeValue(samplesWritten), timescale: CMTimeScale(sampleRate))
                if let sampleBuffer = makeAudioSampleBuffer(
                    sampleRate: sampleRate,
                    channels: 2,
                    frames: framesToGenerate,
                    presentationTimeStamp: pts
                ) {
                    audioInput.append(sampleBuffer)
                }
                samplesWritten += Int(framesToGenerate)
            }
            audioInput.markAsFinished()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .failed {
            throw SyntheticAssetError.writerFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }

        return targetURL
    }

    /// Convenience overload accepting `duration` instead of `durationSeconds` to match test specifications.
    @discardableResult
    public static func createVideo(
        duration: Double,
        fps: Int32 = 30,
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        hasAudio: Bool = true,
        isHDR: Bool = false,
        transform: CGAffineTransform = .identity,
        destinationURL: URL? = nil
    ) async throws -> URL {
        try await createVideo(
            durationSeconds: duration,
            fps: fps,
            resolution: resolution,
            hasAudio: hasAudio,
            isHDR: isHDR,
            transform: transform,
            destinationURL: destinationURL
        )
    }

    // MARK: - 5. Zero-Byte File Generation

    /// Creates an empty (0 bytes) file with the given extension for boundary and error-handling tests.
    ///
    /// - Parameters:
    ///   - fileExtension: Extension such as "jpg", "mp4", etc.
    ///   - destinationURL: Optional custom destination URL.
    /// - Returns: File URL of the generated zero-byte file.
    @discardableResult
    public static func createZeroByteFile(
        fileExtension: String,
        destinationURL: URL? = nil
    ) throws -> URL {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let targetURL = destinationURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_zerobyte_\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "dat" : ext)

        try prepareDestination(at: targetURL)
        try Data().write(to: targetURL, options: .atomic)
        return targetURL
    }

    /// Convenience overload accepting `extension` parameter name.
    @discardableResult
    public static func createZeroByteFile(
        `extension`: String,
        destinationURL: URL? = nil
    ) throws -> URL {
        try createZeroByteFile(fileExtension: `extension`, destinationURL: destinationURL)
    }

    // MARK: - 6. Corrupted File Generation

    /// Creates a corrupt media file containing invalid headers and junk bytes to test error handling.
    ///
    /// - Parameters:
    ///   - fileExtension: Target format extension ("jpg", "png", "heic", "mp4", "mov").
    ///   - destinationURL: Optional custom destination URL.
    /// - Returns: File URL of the generated corrupted file.
    @discardableResult
    public static func createCorruptedFile(
        fileExtension: String,
        destinationURL: URL? = nil
    ) throws -> URL {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let targetURL = destinationURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic_corrupt_\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "dat" : ext)

        try prepareDestination(at: targetURL)

        var corruptBytes: [UInt8] = []
        switch ext.lowercased() {
        case "jpg", "jpeg":
            // Valid SOI (0xFF, 0xD8) immediately followed by invalid marker and broken segment
            corruptBytes = [0xFF, 0xD8, 0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00]
        case "png":
            // Standard PNG signature followed by truncated and corrupted IHDR chunk
            corruptBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0xDE, 0xAD]
        case "heic":
            // HEIC ftyp header followed by garbage bytes
            corruptBytes = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63, 0xFF, 0xFF, 0xFF, 0xFF]
        case "mp4", "mov":
            // MP4/QuickTime ftyp box with broken size and unparsable atoms
            corruptBytes = [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0xDE, 0xAD, 0xBE, 0xEF]
        default:
            corruptBytes = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03]
        }

        // Append pseudorandom junk bytes
        for index in 0..<128 {
            corruptBytes.append(UInt8((index * 37 + 101) % 256))
        }

        let corruptData = Data(corruptBytes)
        try corruptData.write(to: targetURL, options: .atomic)
        return targetURL
    }

    /// Convenience overload accepting `extension` parameter name.
    @discardableResult
    public static func createCorruptedFile(
        `extension`: String,
        destinationURL: URL? = nil
    ) throws -> URL {
        try createCorruptedFile(fileExtension: `extension`, destinationURL: destinationURL)
    }

    // MARK: - 7. Resource Cleanup Helpers

    /// Deletes the files at the specified URLs, ignoring non-existent paths.
    public static func cleanup(urls: [URL]) {
        let fileManager = FileManager.default
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Deletes a single file at the specified URL.
    public static func cleanup(url: URL) {
        cleanup(urls: [url])
    }

    // MARK: - Private Helpers

    private static func prepareDestination(at url: URL) throws {
        let parentDir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int,
        totalFrames: Int,
        isHDR: Bool
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let options: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            options as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        if isHDR {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let colorSpace: CGColorSpace
        if isHDR, let itur2020 = CGColorSpace(name: CGColorSpace.itur_2020) {
            colorSpace = itur2020
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        // Color dynamic background
        let progress = totalFrames > 1 ? CGFloat(frameIndex) / CGFloat(totalFrames - 1) : 0.0
        let r = 0.2 + 0.6 * progress
        let g = 0.4 + 0.3 * (1.0 - progress)
        let b = 0.7

        context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Moving ball to guarantee motion vectors for video encoders
        let radius = max(10.0, CGFloat(min(width, height)) * 0.1)
        let centerX = radius + (CGFloat(width) - 2 * radius) * progress
        let centerY = CGFloat(height) / 2.0 + sin(Double(progress) * .pi * 2.0) * (CGFloat(height) * 0.2)

        context.setFillColor(CGColor(srgbRed: 1.0, green: 0.9, blue: 0.2, alpha: 1.0))
        context.fillEllipse(in: CGRect(
            x: centerX - radius,
            y: centerY - radius,
            width: radius * 2,
            height: radius * 2
        ))

        return buffer
    }

    private static func makeAudioSampleBuffer(
        sampleRate: Float64,
        channels: UInt32,
        frames: CMItemCount,
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        let formatStatus = withUnsafePointer(to: asbd) { ptr in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: ptr,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
        }
        guard formatStatus == noErr, let format = formatDesc else { return nil }

        let bufferSize = Int(frames) * Int(asbd.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bufferSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bufferSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let buffer = blockBuffer else { return nil }

        // Generate a 440Hz sine wave tone
        let sampleCount = Int(frames) * Int(channels)
        var samples = [Int16](repeating: 0, count: sampleCount)
        let toneFrequency: Double = 440.0
        let twoPi = 2.0 * Double.pi

        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            let wave = sin(twoPi * toneFrequency * t)
            let sampleVal = Int16(clamping: Int(wave * 16384.0))
            for ch in 0..<Int(channels) {
                samples[frame * Int(channels) + ch] = sampleVal
            }
        }

        let replaceStatus = samples.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                writeOffset: 0,
                dataLength: bufferSize
            )
        }
        guard replaceStatus == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            makeDataReadyRefcon: nil,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        return (sampleStatus == noErr) ? sampleBuffer : nil
    }
}
