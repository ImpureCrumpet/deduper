import Foundation
import AppKit
import DeduperKit
import QuickLookThumbnailing
import os

/// Async thumbnail service with memory + disk cache.
/// Keyed by file path + size for cache hits. Fingerprints computed lazily.
/// Actor-isolated to prevent concurrent cache corruption.
public actor ThumbnailService {
    private static let logger = Logger(
        subsystem: "app.deduper.ui", category: "thumbnail"
    )

    public struct ThumbnailSize: Sendable, Hashable {
        public let width: CGFloat
        public let height: CGFloat

        public static let list = ThumbnailSize(width: 80, height: 80)
        public static let detail = ThumbnailSize(
            width: 300, height: 300
        )
        public static let compare = ThumbnailSize(
            width: 600, height: 600
        )
    }

    /// Memory cache (evicts under pressure).
    private let memoryCache = NSCache<NSString, NSImage>()

    /// Disk cache directory.
    private let diskCacheURL: URL

    /// In-flight request deduplication.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    public init() {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        self.diskCacheURL = caches
            .appendingPathComponent("Deduper")
            .appendingPathComponent("thumbnails")

        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 100 * 1024 * 1024

        try? FileManager.default.createDirectory(
            at: diskCacheURL, withIntermediateDirectories: true
        )
    }

    /// Get a thumbnail for a file path.
    /// Returns nil if the file doesn't exist or generation fails.
    public func thumbnail(
        for filePath: String,
        size: ThumbnailSize
    ) async -> NSImage? {
        let key = cacheKey(path: filePath, size: size)

        // 1. Memory cache
        if let cached = memoryCache.object(
            forKey: key as NSString
        ) {
            return cached
        }

        // 2. Disk cache
        if let diskImage = loadFromDisk(key: key) {
            memoryCache.setObject(
                diskImage, forKey: key as NSString
            )
            return diskImage
        }

        // 3. Deduplicate in-flight requests
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> {
            let image = await generateThumbnail(
                path: filePath, size: size
            )
            if let image {
                memoryCache.setObject(
                    image, forKey: key as NSString
                )
                saveToDisk(image: image, key: key)
            }
            return image
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    /// Clear all caches.
    public func clearCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(
            at: diskCacheURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Private

    private func cacheKey(
        path: String, size: ThumbnailSize
    ) -> String {
        let canonical = PathIdentity.canonical(path)
        return "\(canonical)_\(Int(size.width))x\(Int(size.height))"
    }

    private func diskPath(for key: String) -> URL {
        // Hash the key to get a safe filename
        let data = Data(key.utf8)
        var hash: UInt64 = 5381
        for byte in data {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        let filename = String(hash, radix: 16)
        return diskCacheURL
            .appendingPathComponent(filename)
            .appendingPathExtension("png")
    }

    private func loadFromDisk(key: String) -> NSImage? {
        let path = diskPath(for: key)
        guard FileManager.default.fileExists(
            atPath: path.path
        ) else {
            return nil
        }
        return NSImage(contentsOf: path)
    }

    private func saveToDisk(image: NSImage, key: String) {
        let path = diskPath(for: key)
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let png = rep.representation(
                  using: .png, properties: [:]
              )
        else { return }
        try? png.write(to: path)
    }

    private func generateThumbnail(
        path: String, size: ThumbnailSize
    ) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(
                width: size.width, height: size.height
            ),
            scale: 2.0,
            representationTypes: .thumbnail
        )

        do {
            let thumbnail = try await QLThumbnailGenerator
                .shared
                .generateBestRepresentation(for: request)
            return thumbnail.nsImage
        } catch {
            Self.logger.debug(
                "Thumbnail failed for \(url.lastPathComponent): \(error.localizedDescription)"
            )
            return nil
        }
    }
}
