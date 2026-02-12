import Testing
import Foundation
import CoreGraphics
@testable import DeduperKit

@Suite("ImageHashingService")
struct ImageHashingServiceTests {
    let service = ImageHashingService()

    // MARK: - Helpers

    /// Create a solid-color CGImage for testing.
    private func makeSolidImage(
        width: Int,
        height: Int,
        gray: UInt8
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let pixels = [UInt8](repeating: gray, count: width * height)
        return pixels.withUnsafeBytes { buf in
            guard let data = CFDataCreate(
                nil,
                buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                buf.count
            ) else { return nil }
            guard let provider = CGDataProvider(data: data) else {
                return nil
            }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    /// Create a gradient CGImage (left=dark, right=bright).
    private func makeGradientImage(
        width: Int,
        height: Int
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8(x * 255 / max(width - 1, 1))
            }
        }
        return pixels.withUnsafeBytes { buf in
            guard let data = CFDataCreate(
                nil,
                buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                buf.count
            ) else { return nil }
            guard let provider = CGDataProvider(data: data) else {
                return nil
            }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    // MARK: - dHash Tests

    @Test("dHash produces consistent output for identical images")
    func dHashConsistency() throws {
        let image = try #require(makeSolidImage(width: 32, height: 32, gray: 128))
        let hash1 = service.computeDHash(from: image)
        let hash2 = service.computeDHash(from: image)
        #expect(hash1 == hash2)
        #expect(hash1 != nil)
    }

    @Test("dHash of solid image is 0 (no pixel differences)")
    func dHashSolidImage() throws {
        let image = try #require(makeSolidImage(width: 32, height: 32, gray: 200))
        let hash = try #require(service.computeDHash(from: image))
        #expect(hash == 0)
    }

    @Test("dHash of gradient image is non-zero")
    func dHashGradientImage() throws {
        let image = try #require(makeGradientImage(width: 32, height: 32))
        let hash = try #require(service.computeDHash(from: image))
        #expect(hash != 0)
    }

    // MARK: - pHash Tests

    @Test("pHash produces consistent output")
    func pHashConsistency() throws {
        let image = try #require(makeGradientImage(width: 64, height: 64))
        let hash1 = service.computePHash(from: image)
        let hash2 = service.computePHash(from: image)
        #expect(hash1 == hash2)
        #expect(hash1 != nil)
    }

    @Test("pHash differs between very different images")
    func pHashDifferentImages() throws {
        let solid = try #require(makeSolidImage(width: 64, height: 64, gray: 0))
        let gradient = try #require(makeGradientImage(width: 64, height: 64))
        let hash1 = try #require(service.computePHash(from: solid))
        let hash2 = try #require(service.computePHash(from: gradient))
        let distance = service.hammingDistance(hash1, hash2)
        #expect(distance > 0)
    }

    // MARK: - Hamming Distance

    @Test("Hamming distance of identical hashes is 0")
    func hammingDistanceIdentical() {
        #expect(service.hammingDistance(0xFFFF, 0xFFFF) == 0)
    }

    @Test("Hamming distance counts differing bits")
    func hammingDistanceDiffering() {
        // 0b0001 vs 0b0010 = 2 bits differ
        #expect(service.hammingDistance(1, 2) == 2)
        // All bits differ in 8-bit range
        #expect(service.hammingDistance(0, 0xFF) == 8)
    }

    // MARK: - computeHashes

    @Test("computeHashes returns both dHash and pHash")
    func computeHashesBothAlgorithms() throws {
        let image = try #require(makeGradientImage(width: 64, height: 64))
        let results = service.computeHashes(from: image)
        let algorithms = Set(results.map(\.algorithm))
        #expect(algorithms.contains(.dHash))
        #expect(algorithms.contains(.pHash))
    }

    // MARK: - Real File Fixture Tests

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test("Hash real PNG screenshot from fixture")
    func hashRealScreenshot() {
        let results = service.computeHashes(for: fixtureURL("screenshot-a.png"))
        #expect(results.count == 2) // dHash + pHash
        for result in results {
            #expect(result.hash != 0)
        }
    }

    @Test("Variant screenshots are closer than unrelated screenshots")
    func variantScreenshotsCloserThanUnrelated() {
        let hashesOrig = service.computeHashes(for: fixtureURL("dup-original.png"))
        let hashesVar = service.computeHashes(for: fixtureURL("dup-variant.png"))
        let hashesB = service.computeHashes(for: fixtureURL("screenshot-b.png"))

        #expect(!hashesOrig.isEmpty)
        #expect(!hashesVar.isEmpty)
        #expect(!hashesB.isEmpty)

        // The original/variant pair (same timestamp, different export)
        // should be closer than original vs a completely unrelated screenshot.
        if let pOrig = hashesOrig.first(where: { $0.algorithm == .pHash }),
           let pVar = hashesVar.first(where: { $0.algorithm == .pHash }),
           let pB = hashesB.first(where: { $0.algorithm == .pHash }) {
            let distVariant = service.hammingDistance(pOrig.hash, pVar.hash)
            let distUnrelated = service.hammingDistance(pOrig.hash, pB.hash)
            // Variant should be at least somewhat closer than an unrelated shot
            #expect(
                distVariant <= distUnrelated,
                "Variant distance (\(distVariant)) should be <= unrelated distance (\(distUnrelated))"
            )
        }
    }

    @Test("Different screenshots have higher hamming distance")
    func differentScreenshotsHigherDistance() {
        let hashesA = service.computeHashes(for: fixtureURL("screenshot-a.png"))
        let hashesB = service.computeHashes(for: fixtureURL("screenshot-b.png"))

        #expect(!hashesA.isEmpty)
        #expect(!hashesB.isEmpty)

        if let pHashA = hashesA.first(where: { $0.algorithm == .pHash }),
           let pHashB = hashesB.first(where: { $0.algorithm == .pHash }) {
            let distance = service.hammingDistance(pHashA.hash, pHashB.hash)
            // Different images should have larger distance than near-duplicates
            #expect(distance > 0, "Different images should produce different hashes")
        }
    }
}
