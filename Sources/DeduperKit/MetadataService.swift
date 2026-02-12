import Foundation
import ImageIO
import AVFoundation
import CoreMedia
import os

public struct MetadataService: Sendable {
    private let logger = Logger(subsystem: "app.deduper", category: "metadata")

    public init() {}

    /// Extract metadata from a media file URL.
    public func extractMetadata(from url: URL) async -> MediaMetadata {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let createdAt = attributes?[.creationDate] as? Date
        let modifiedAt = attributes?[.modificationDate] as? Date

        let ext = url.pathExtension.lowercased()
        let mediaType = classifyExtension(ext)

        var metadata = MediaMetadata(
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            mediaType: mediaType,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            inferredUTType: ext
        )

        switch mediaType {
        case .photo:
            metadata = enrichImageMetadata(metadata, url: url)
        case .video:
            metadata = await enrichVideoMetadata(metadata, url: url)
        case .audio:
            metadata = await enrichAudioMetadata(metadata, url: url)
        }

        return metadata
    }

    // MARK: - Image Metadata

    private func enrichImageMetadata(
        _ base: MediaMetadata,
        url: URL
    ) -> MediaMetadata {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            return base
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source, 0, nil
        ) as? [CFString: Any] else {
            return base
        }

        var result = base

        // Dimensions
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            result = MediaMetadata(
                fileName: result.fileName,
                fileSize: result.fileSize,
                mediaType: result.mediaType,
                createdAt: result.createdAt,
                modifiedAt: result.modifiedAt,
                dimensions: (width, height),
                captureDate: result.captureDate,
                cameraModel: result.cameraModel,
                gpsLat: result.gpsLat,
                gpsLon: result.gpsLon,
                durationSec: result.durationSec,
                keywords: result.keywords,
                tags: result.tags,
                inferredUTType: result.inferredUTType
            )
        }

        // EXIF data
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            let captureDate = dateStr.flatMap { parseExifDate($0) }

            result = MediaMetadata(
                fileName: result.fileName,
                fileSize: result.fileSize,
                mediaType: result.mediaType,
                createdAt: result.createdAt,
                modifiedAt: result.modifiedAt,
                dimensions: result.dimensions,
                captureDate: captureDate ?? result.captureDate,
                cameraModel: result.cameraModel,
                gpsLat: result.gpsLat,
                gpsLon: result.gpsLon,
                durationSec: result.durationSec,
                keywords: result.keywords,
                tags: result.tags,
                inferredUTType: result.inferredUTType
            )
        }

        // TIFF (camera model)
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            result = MediaMetadata(
                fileName: result.fileName,
                fileSize: result.fileSize,
                mediaType: result.mediaType,
                createdAt: result.createdAt,
                modifiedAt: result.modifiedAt,
                dimensions: result.dimensions,
                captureDate: result.captureDate,
                cameraModel: model ?? result.cameraModel,
                gpsLat: result.gpsLat,
                gpsLon: result.gpsLon,
                durationSec: result.durationSec,
                keywords: result.keywords,
                tags: result.tags,
                inferredUTType: result.inferredUTType
            )
        }

        // GPS
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            let lat = gps[kCGImagePropertyGPSLatitude] as? Double
            let lon = gps[kCGImagePropertyGPSLongitude] as? Double
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String

            var finalLat = lat
            var finalLon = lon
            if latRef == "S", let l = finalLat { finalLat = -l }
            if lonRef == "W", let l = finalLon { finalLon = -l }

            result = MediaMetadata(
                fileName: result.fileName,
                fileSize: result.fileSize,
                mediaType: result.mediaType,
                createdAt: result.createdAt,
                modifiedAt: result.modifiedAt,
                dimensions: result.dimensions,
                captureDate: result.captureDate,
                cameraModel: result.cameraModel,
                gpsLat: finalLat ?? result.gpsLat,
                gpsLon: finalLon ?? result.gpsLon,
                durationSec: result.durationSec,
                keywords: result.keywords,
                tags: result.tags,
                inferredUTType: result.inferredUTType
            )
        }

        return result
    }

    // MARK: - Video Metadata

    private func enrichVideoMetadata(
        _ base: MediaMetadata,
        url: URL
    ) async -> MediaMetadata {
        let asset = AVAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let durationSec = CMTimeGetSeconds(duration)

            var width = 0
            var height = 0
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let size = try await track.load(.naturalSize)
                width = Int(size.width)
                height = Int(size.height)
            }

            let creationDate = try? await asset.load(.creationDate)
            let captureDate = try? await creationDate?.load(.dateValue)

            return MediaMetadata(
                fileName: base.fileName,
                fileSize: base.fileSize,
                mediaType: base.mediaType,
                createdAt: base.createdAt,
                modifiedAt: base.modifiedAt,
                dimensions: width > 0 ? (width, height) : nil,
                captureDate: captureDate,
                cameraModel: base.cameraModel,
                gpsLat: base.gpsLat,
                gpsLon: base.gpsLon,
                durationSec: durationSec.isFinite ? durationSec : nil,
                keywords: base.keywords,
                tags: base.tags,
                inferredUTType: base.inferredUTType
            )
        } catch {
            logger.warning(
                "Failed to extract video metadata: \(error.localizedDescription)"
            )
            return base
        }
    }

    // MARK: - Audio Metadata

    private func enrichAudioMetadata(
        _ base: MediaMetadata,
        url: URL
    ) async -> MediaMetadata {
        let asset = AVAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let durationSec = CMTimeGetSeconds(duration)

            return MediaMetadata(
                fileName: base.fileName,
                fileSize: base.fileSize,
                mediaType: base.mediaType,
                createdAt: base.createdAt,
                modifiedAt: base.modifiedAt,
                dimensions: nil,
                captureDate: base.captureDate,
                cameraModel: base.cameraModel,
                gpsLat: base.gpsLat,
                gpsLon: base.gpsLon,
                durationSec: durationSec.isFinite ? durationSec : nil,
                keywords: base.keywords,
                tags: base.tags,
                inferredUTType: base.inferredUTType
            )
        } catch {
            return base
        }
    }

    // MARK: - Helpers

    private func classifyExtension(_ ext: String) -> MediaType {
        for mediaType in MediaType.allCases {
            if mediaType.commonExtensions.contains(ext) {
                return mediaType
            }
        }
        return .photo
    }

    private func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }
}
