import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import os

// MARK: - Supporting Types

public enum HashAlgorithm: String, Sendable, CaseIterable, Codable {
    case dHash
    case pHash
}

public struct ImageHashResult: Sendable, Equatable {
    public let algorithm: HashAlgorithm
    public let hash: UInt64

    public init(algorithm: HashAlgorithm, hash: UInt64) {
        self.algorithm = algorithm
        self.hash = hash
    }
}

public struct HashingConfig: Sendable {
    public let algorithms: [HashAlgorithm]
    public let dHashSize: Int
    public let pHashSize: Int
    public let pHashDCTSize: Int

    public init(
        algorithms: [HashAlgorithm] = HashAlgorithm.allCases,
        dHashSize: Int = 9,
        pHashSize: Int = 32,
        pHashDCTSize: Int = 8
    ) {
        self.algorithms = algorithms
        self.dHashSize = dHashSize
        self.pHashSize = pHashSize
        self.pHashDCTSize = pHashDCTSize
    }

    public static let `default` = HashingConfig()
}

// MARK: - ImageHashingService

public struct ImageHashingService: Sendable {
    private let logger = Logger(subsystem: "app.deduper", category: "hash")
    private let config: HashingConfig

    public init(config: HashingConfig = .default) {
        self.config = config
    }

    // MARK: - Public API

    public func computeHashes(for url: URL) -> [ImageHashResult] {
        guard let cgImage = makeThumbnail(url: url, maxSize: config.pHashSize) else {
            logger.warning("Failed to create thumbnail for \(url.lastPathComponent)")
            return []
        }
        return computeHashes(from: cgImage)
    }

    public func computeHashes(from cgImage: CGImage) -> [ImageHashResult] {
        var results: [ImageHashResult] = []
        for algorithm in config.algorithms {
            switch algorithm {
            case .dHash:
                if let hash = computeDHash(from: cgImage) {
                    results.append(ImageHashResult(algorithm: .dHash, hash: hash))
                }
            case .pHash:
                if let hash = computePHash(from: cgImage) {
                    results.append(ImageHashResult(algorithm: .pHash, hash: hash))
                }
            }
        }
        return results
    }

    public func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    // MARK: - dHash

    /// Difference hash: resize to (dHashSize x (dHashSize-1)), compare each pixel
    /// to its right neighbor. Produces a 64-bit hash for the default 9x8 grid.
    public func computeDHash(from cgImage: CGImage) -> UInt64? {
        let width = config.dHashSize
        let height = config.dHashSize - 1

        guard let pixels = createGrayscaleThumbnail(from: cgImage, size: (width, height)) else {
            return nil
        }
        defer { pixels.deallocate() }

        var hash: UInt64 = 0
        var bit = 0

        for y in 0..<height {
            for x in 0..<(width - 1) {
                let leftIndex = y * width + x
                let rightIndex = y * width + x + 1
                if pixels[leftIndex] < pixels[rightIndex] {
                    hash |= 1 << bit
                }
                bit += 1
                if bit >= 64 { break }
            }
            if bit >= 64 { break }
        }

        return hash
    }

    // MARK: - pHash

    /// Perceptual hash: resize to pHashSize x pHashSize grayscale, apply 2D DCT,
    /// take the top-left pHashDCTSize x pHashDCTSize block, compute median, and
    /// produce a 64-bit hash by comparing each coefficient to the median.
    public func computePHash(from cgImage: CGImage) -> UInt64? {
        let size = config.pHashSize
        let dctSize = config.pHashDCTSize

        guard let pixels = createGrayscaleThumbnail(from: cgImage, size: (size, size)) else {
            return nil
        }
        defer { pixels.deallocate() }

        guard let dctResult = apply2DDCT(to: pixels, width: size, height: size) else {
            return nil
        }
        defer { dctResult.deallocate() }

        // Extract top-left dctSize x dctSize block (excluding DC component at [0,0])
        var dctValues: [Float] = []
        for y in 0..<dctSize {
            for x in 0..<dctSize {
                if x == 0 && y == 0 { continue } // skip DC
                dctValues.append(dctResult[y * size + x])
            }
        }

        // Compute median
        let sorted = dctValues.sorted()
        let median: Float
        if sorted.isEmpty {
            return nil
        } else if sorted.count % 2 == 0 {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
        } else {
            median = sorted[sorted.count / 2]
        }

        // Build hash: 1 if value > median, 0 otherwise
        var hash: UInt64 = 0
        for (i, value) in dctValues.enumerated() {
            if i >= 64 { break }
            if value > median {
                hash |= 1 << i
            }
        }

        return hash
    }

    // MARK: - Grayscale Thumbnail

    /// Creates a grayscale pixel buffer by drawing the image into an 8-bit context.
    func createGrayscaleThumbnail(
        from cgImage: CGImage,
        size: (width: Int, height: Int)
    ) -> UnsafeMutablePointer<UInt8>? {
        let width = size.width
        let height = size.height

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = width

        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        pixels.initialize(repeating: 0, count: width * height)

        guard let context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            pixels.deallocate()
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pixels
    }

    // MARK: - 2D DCT

    /// Applies a 2D Discrete Cosine Transform to the grayscale pixel buffer.
    /// Converts UInt8 pixels to Float, then applies DCT row-wise and column-wise
    /// using vDSP.
    func apply2DDCT(
        to pixels: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int
    ) -> UnsafeMutablePointer<Float>? {
        let count = width * height

        // Convert to float
        let floatPixels = UnsafeMutablePointer<Float>.allocate(capacity: count)
        for i in 0..<count {
            floatPixels[i] = Float(pixels[i])
        }

        // Apply DCT row-wise
        guard let setup = vDSP_DCT_CreateSetup(
            nil,
            vDSP_Length(width),
            .II
        ) else {
            floatPixels.deallocate()
            return nil
        }

        let rowBuffer = UnsafeMutablePointer<Float>.allocate(capacity: width)
        let rowResult = UnsafeMutablePointer<Float>.allocate(capacity: width)
        defer {
            rowBuffer.deallocate()
            rowResult.deallocate()
        }

        for y in 0..<height {
            let offset = y * width
            for x in 0..<width {
                rowBuffer[x] = floatPixels[offset + x]
            }
            vDSP_DCT_Execute(setup, rowBuffer, rowResult)
            for x in 0..<width {
                floatPixels[offset + x] = rowResult[x]
            }
        }

        // Apply DCT column-wise
        guard let colSetup = vDSP_DCT_CreateSetup(
            nil,
            vDSP_Length(height),
            .II
        ) else {
            floatPixels.deallocate()
            return nil
        }

        let colBuffer = UnsafeMutablePointer<Float>.allocate(capacity: height)
        let colResult = UnsafeMutablePointer<Float>.allocate(capacity: height)
        defer {
            colBuffer.deallocate()
            colResult.deallocate()
        }

        for x in 0..<width {
            for y in 0..<height {
                colBuffer[y] = floatPixels[y * width + x]
            }
            vDSP_DCT_Execute(colSetup, colBuffer, colResult)
            for y in 0..<height {
                floatPixels[y * width + x] = colResult[y]
            }
        }

        return floatPixels
    }

    // MARK: - Thumbnail from URL

    /// Creates a CGImage thumbnail from a file URL using ImageIO, respecting
    /// the max size constraint for efficient memory usage.
    public func makeThumbnail(url: URL, maxSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true,
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        )
    }
}
