import AppKit
import ImageIO

/// Loads images downsampled to a max pixel dimension.
/// Uses CGImageSource for efficient partial decode — never loads
/// full-resolution data into memory.
public enum DownsampledImageLoader {
    /// Load an image downsampled so its longest edge is at most
    /// `maxPixelSize` points. Returns nil for non-image files.
    public static func load(
        url: URL,
        maxPixelSize: CGFloat
    ) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, nil
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: cgImage.width,
                height: cgImage.height
            )
        )
    }
}
