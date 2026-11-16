//
//  ExifHelper.swift
//  MediaLite
//
//  Production-grade ImageIO metadata inspection, extraction, and parsing utility.
//  Extracts dimensions, EXIF, TIFF, GPS coordinates, orientation, and color space
//  without caching decompressed bitmaps into memory.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - GPSCoordinates

/// Represents decoded geographic coordinate metadata.
public struct GPSCoordinates: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

// MARK: - ExifHelperError

/// Typed error representation for ExifHelper operations.
public enum ExifHelperError: LocalizedError, Sendable, Equatable {
    case fileNotFound(URL)
    case zeroByteFile(URL)
    case invalidSource(String)
    case unreadableProperties(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found at path: '\(url.path)'"
        case .zeroByteFile(let url):
            return "File is empty (0 bytes) at path: '\(url.path)'"
        case .invalidSource(let reason):
            return "Invalid image source: \(reason)"
        case .unreadableProperties(let reason):
            return "Failed to read image properties: \(reason)"
        }
    }
}

// MARK: - ImageMetadata

/// Strongly typed encapsulation of image metadata.
public struct ImageMetadata: @unchecked Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let orientation: CGImagePropertyOrientation
    public let colorSpaceName: String?
    public let cameraMake: String?
    public let cameraModel: String?
    public let software: String?
    public let captureDate: Date?
    public let captureDateString: String?
    public let focalLength: Double?
    public let fNumber: Double?
    public let isoSpeedRatings: [Int]?
    public let exposureTime: Double?
    public let gpsCoordinates: GPSCoordinates?
    public let hasAlphaChannel: Bool
    public let format: UTType?
    public let fileSize: Int64
    public let exifDictionary: [String: Any]?
    public let tiffDictionary: [String: Any]?
    public let gpsDictionary: [String: Any]?
    public let rawProperties: [String: Any]

    public var dimensions: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    public var pixelDimensions: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: CGImagePropertyOrientation,
        colorSpaceName: String?,
        cameraMake: String?,
        cameraModel: String?,
        software: String?,
        captureDate: Date?,
        captureDateString: String?,
        focalLength: Double?,
        fNumber: Double?,
        isoSpeedRatings: [Int]?,
        exposureTime: Double?,
        gpsCoordinates: GPSCoordinates?,
        hasAlphaChannel: Bool,
        format: UTType?,
        fileSize: Int64,
        exifDictionary: [String: Any]?,
        tiffDictionary: [String: Any]?,
        gpsDictionary: [String: Any]?,
        rawProperties: [String: Any]
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.colorSpaceName = colorSpaceName
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.software = software
        self.captureDate = captureDate
        self.captureDateString = captureDateString
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.isoSpeedRatings = isoSpeedRatings
        self.exposureTime = exposureTime
        self.gpsCoordinates = gpsCoordinates
        self.hasAlphaChannel = hasAlphaChannel
        self.format = format
        self.fileSize = fileSize
        self.exifDictionary = exifDictionary
        self.tiffDictionary = tiffDictionary
        self.gpsDictionary = gpsDictionary
        self.rawProperties = rawProperties
    }
}

// MARK: - ExifHelper

/// Production utility providing deep metadata inspection and extraction using Apple ImageIO.
public enum ExifHelper {

    private static let sourceOptions: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldCacheImmediately: false
    ]

    // MARK: - Format Detection

    /// Detects the uniform type identifier (UTType) of an image asset from raw `Data`.
    ///
    /// Uses ImageIO `CGImageSourceGetType` with magic byte fallback (JPEG, PNG, HEIC, TIFF).
    /// - Parameter data: In-memory image data buffer.
    /// - Returns: Detected `UTType`, defaulting to `.jpeg` if format cannot be recognized.
    public static func detectFormat(from data: Data) -> UTType {
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
           let typeCF = CGImageSourceGetType(source),
           let utType = UTType(typeCF as String) {
            return utType
        }

        // Magic byte fallback
        // JPEG: 0xFF, 0xD8
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8 {
            return .jpeg
        }
        // PNG: 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
        if data.count >= 8 && data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        // HEIC/HEIF: offset 4 "ftyp" with brand "heic", "heix", "heim", "heis", "mif1", "msf1"
        if data.count >= 12 {
            let ftyp = data.subdata(in: 4..<8)
            let brand = data.subdata(in: 8..<12)
            if let ftypStr = String(data: ftyp, encoding: .ascii), ftypStr == "ftyp",
               let brandStr = String(data: brand, encoding: .ascii)?.lowercased() {
                let heicBrands = ["heic", "heix", "heim", "heis", "mif1", "msf1"]
                if heicBrands.contains(brandStr) {
                    return .heic
                }
            }
        }
        // TIFF: Little Endian "II*\0" or Big Endian "MM\0*"
        if data.count >= 4 {
            if (data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2A && data[3] == 0x00) ||
               (data[0] == 0x4D && data[1] == 0x4D && data[2] == 0x00 && data[3] == 0x2A) {
                return .tiff
            }
        }

        return .jpeg
    }

    /// Detects the uniform type identifier (UTType) of an image asset from a file URL.
    ///
    /// - Parameter url: File URL of the image asset.
    /// - Returns: Detected `UTType`, defaulting to `.jpeg` if format cannot be recognized.
    public static func detectFormat(from url: URL) -> UTType {
        if let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
           let typeCF = CGImageSourceGetType(source),
           let utType = UTType(typeCF as String) {
            return utType
        }
        if let detected = UTType(filenameExtension: url.pathExtension) {
            return detected
        }
        return .jpeg
    }

    // MARK: - Metadata Extraction

    /// Extracts comprehensive metadata from an image file URL without loading pixel buffers into memory.
    ///
    /// - Parameter url: The file URL of the image asset.
    /// - Returns: Strongly typed `ImageMetadata` instance.
    public static func extractMetadata(from url: URL) throws -> ImageMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExifHelperError.fileNotFound(url)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw ExifHelperError.zeroByteFile(url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            throw ExifHelperError.invalidSource("CGImageSourceCreateWithURL returned nil for \(url.path)")
        }

        return try parseMetadata(from: source, fileSize: fileSize)
    }

    /// Extracts comprehensive metadata from raw image `Data`.
    ///
    /// - Parameter data: The in-memory image data buffer.
    /// - Returns: Strongly typed `ImageMetadata` instance.
    public static func extractMetadata(from data: Data) throws -> ImageMetadata {
        guard !data.isEmpty else {
            throw ExifHelperError.invalidSource("Image data is empty (0 bytes)")
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            throw ExifHelperError.invalidSource("CGImageSourceCreateWithData returned nil")
        }

        return try parseMetadata(from: source, fileSize: Int64(data.count))
    }

    // MARK: - Lightweight Convenience Queries

    /// Reads raw properties dictionary from the primary image index.
    public static func readProperties(from url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any]
    }

    /// Reads the orientation tag from an image URL, defaulting to `.up` (tag 1) if unspecified.
    public static func readOrientation(from url: URL) -> CGImagePropertyOrientation {
        guard let props = readProperties(from: url) else { return .up }
        if let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value {
            return CGImagePropertyOrientation(rawValue: raw) ?? .up
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = (tiff[kCGImagePropertyTIFFOrientation] as? NSNumber)?.uint32Value {
            return CGImagePropertyOrientation(rawValue: raw) ?? .up
        }
        return .up
    }

    /// Reads the pixel dimensions (width and height) of an image file.
    public static func readDimensions(from url: URL) -> CGSize? {
        guard let props = readProperties(from: url) else { return nil }
        guard let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else {
            return nil
        }
        return CGSize(width: w, height: h)
    }

    /// Reads capture date from an image file if available in EXIF or TIFF dictionaries.
    public static func readCaptureDate(from url: URL) -> Date? {
        guard let props = readProperties(from: url) else { return nil }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = parseExifDate(dateStr) {
            return date
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateStr = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = parseExifDate(dateStr) {
            return date
        }
        return nil
    }

    /// Reads camera make and model strings from TIFF metadata.
    public static func readCameraInfo(from url: URL) -> (make: String?, model: String?) {
        guard let props = readProperties(from: url),
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else {
            return (nil, nil)
        }
        let make = tiff[kCGImagePropertyTIFFMake] as? String
        let model = tiff[kCGImagePropertyTIFFModel] as? String
        return (make, model)
    }

    // MARK: - Date Formatting Helpers

    /// Thread-safe parsing of EXIF date strings (e.g. "yyyy:MM:dd HH:mm:ss" or ISO-8601).
    public static func parseExifDate(_ dateString: String) -> Date? {
        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        // Standard EXIF format: "2026:01:01 12:00:00"
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let date = formatter.date(from: trimmed) {
            return date
        }

        // Secondary EXIF format with subseconds: "2026:01:01 12:00:00.SSS"
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss.SSS"
        if let date = formatter.date(from: trimmed) {
            return date
        }

        // ISO-8601 fallback
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: trimmed)
    }

    /// Formats a Date into standard EXIF date string format: "yyyy:MM:dd HH:mm:ss".
    public static func formatExifDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - Private Parser

    private static func parseMetadata(from source: CGImageSource, fileSize: Int64) throws -> ImageMetadata {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw ExifHelperError.invalidSource("Image source contains 0 images")
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [String: Any] else {
            throw ExifHelperError.unreadableProperties("CGImageSourceCopyPropertiesAtIndex returned nil")
        }

        let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0

        guard pixelWidth > 0 && pixelHeight > 0 else {
            throw ExifHelperError.unreadableProperties("Image dimensions are invalid or 0")
        }

        // Orientation
        var orientation: CGImagePropertyOrientation = .up
        if let raw = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value {
            orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        } else if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
                  let raw = (tiff[kCGImagePropertyTIFFOrientation as String] as? NSNumber)?.uint32Value {
            orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        }

        // UTType
        var format: UTType?
        if let typeCF = CGImageSourceGetType(source) {
            format = UTType(typeCF as String)
        }

        // Color Space
        let colorSpaceName = properties[kCGImagePropertyColorModel as String] as? String
            ?? properties[kCGImagePropertyProfileName as String] as? String

        // TIFF
        let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let cameraMake = tiffDict?[kCGImagePropertyTIFFMake as String] as? String
        let cameraModel = tiffDict?[kCGImagePropertyTIFFModel as String] as? String
        let software = tiffDict?[kCGImagePropertyTIFFSoftware as String] as? String

        // EXIF
        let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let captureDateString = exifDict?[kCGImagePropertyExifDateTimeOriginal as String] as? String
            ?? tiffDict?[kCGImagePropertyTIFFDateTime as String] as? String
        let captureDate = captureDateString.flatMap { parseExifDate($0) }

        let focalLength = (exifDict?[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
        let fNumber = (exifDict?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        let exposureTime = (exifDict?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        let isoSpeedRatings = exifDict?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int]

        // GPS
        let gpsDict = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        var gpsCoordinates: GPSCoordinates?
        if let gps = gpsDict,
           let lat = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
           let lon = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
            let finalLat = (latRef.uppercased() == "S") ? -abs(lat) : abs(lat)
            let finalLon = (lonRef.uppercased() == "W") ? -abs(lon) : abs(lon)

            var altitude: Double?
            if let alt = (gps[kCGImagePropertyGPSAltitude as String] as? NSNumber)?.doubleValue {
                let altRef = (gps[kCGImagePropertyGPSAltitudeRef as String] as? NSNumber)?.intValue ?? 0
                altitude = (altRef == 1) ? -abs(alt) : abs(alt)
            }

            gpsCoordinates = GPSCoordinates(latitude: finalLat, longitude: finalLon, altitude: altitude)
        }

        // Alpha channel presence
        let hasAlpha = properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false

        return ImageMetadata(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            orientation: orientation,
            colorSpaceName: colorSpaceName,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            software: software,
            captureDate: captureDate,
            captureDateString: captureDateString,
            focalLength: focalLength,
            fNumber: fNumber,
            isoSpeedRatings: isoSpeedRatings,
            exposureTime: exposureTime,
            gpsCoordinates: gpsCoordinates,
            hasAlphaChannel: hasAlpha,
            format: format,
            fileSize: fileSize,
            exifDictionary: exifDict,
            tiffDictionary: tiffDict,
            gpsDictionary: gpsDict,
            rawProperties: properties
        )
    }
}
