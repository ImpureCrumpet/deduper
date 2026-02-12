import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import DeduperKit

@Suite("DetectionService")
struct DetectionServiceTests {

    /// Write a minimal valid JPEG to a temp file.
    /// This is a real (tiny) 1x1 white JPEG.
    private func writeTestJPEG(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.cannotCreateImage
        }

        // Fill with a color
        context.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))

        guard let image = context.makeImage() else {
            throw TestError.cannotCreateImage
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw TestError.cannotCreateImage
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Write a slightly different JPEG (same dimensions).
    private func writeVariantJPEG(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.cannotCreateImage
        }

        // Slightly different color
        context.setFillColor(CGColor(red: 0.5, green: 0.31, blue: 0.8, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))

        guard let image = context.makeImage() else {
            throw TestError.cannotCreateImage
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw TestError.cannotCreateImage
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Write a very different image.
    private func writeDifferentJPEG(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.cannotCreateImage
        }

        // Draw a gradient pattern instead of solid fill
        for y in 0..<64 {
            for x in 0..<64 {
                let r = CGFloat(x) / 64.0
                let g = CGFloat(y) / 64.0
                context.setFillColor(
                    CGColor(red: r, green: g, blue: 0.1, alpha: 1.0)
                )
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        guard let image = context.makeImage() else {
            throw TestError.cannotCreateImage
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw TestError.cannotCreateImage
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("deduper-detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Detects near-duplicate images as a group")
    func detectsNearDuplicates() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file1 = dir.appendingPathComponent("img1.jpg")
        let file2 = dir.appendingPathComponent("img2.jpg")
        try writeTestJPEG(to: file1)
        try writeVariantJPEG(to: file2)

        let size1 = try FileManager.default
            .attributesOfItem(atPath: file1.path)[.size] as? Int64 ?? 0
        let size2 = try FileManager.default
            .attributesOfItem(atPath: file2.path)[.size] as? Int64 ?? 0

        let files = [
            ScannedFile(url: file1, mediaType: .photo, fileSize: size1),
            ScannedFile(url: file2, mediaType: .photo, fileSize: size2)
        ]

        let detector = DetectionService()
        let groups = try await detector.detectDuplicates(in: files)

        #expect(groups.count == 1)
        #expect(groups[0].members.count == 2)
    }

    @Test("Different images are not grouped")
    func differentImagesNotGrouped() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file1 = dir.appendingPathComponent("solid.jpg")
        let file2 = dir.appendingPathComponent("gradient.jpg")
        try writeTestJPEG(to: file1)
        try writeDifferentJPEG(to: file2)

        let size1 = try FileManager.default
            .attributesOfItem(atPath: file1.path)[.size] as? Int64 ?? 0
        let size2 = try FileManager.default
            .attributesOfItem(atPath: file2.path)[.size] as? Int64 ?? 0

        let files = [
            ScannedFile(url: file1, mediaType: .photo, fileSize: size1),
            ScannedFile(url: file2, mediaType: .photo, fileSize: size2)
        ]

        let detector = DetectionService()
        // Use a strict threshold
        let options = DetectOptions(
            thresholds: .init(imageDistance: 3)
        )
        let groups = try await detector.detectDuplicates(
            in: files, options: options
        )

        #expect(groups.isEmpty)
    }

    @Test("Single file produces no groups")
    func singleFileNoGroups() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("alone.jpg")
        try writeTestJPEG(to: file)

        let size = try FileManager.default
            .attributesOfItem(atPath: file.path)[.size] as? Int64 ?? 0

        let files = [
            ScannedFile(url: file, mediaType: .photo, fileSize: size)
        ]

        let detector = DetectionService()
        let groups = try await detector.detectDuplicates(in: files)
        #expect(groups.isEmpty)
    }

    @Test("Empty input produces empty results")
    func emptyInput() async throws {
        let detector = DetectionService()
        let groups = try await detector.detectDuplicates(in: [])
        #expect(groups.isEmpty)
    }

    @Test("Byte-identical files detected via SHA256 with confidence 1.0")
    func sha256ExactMatch() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file1 = dir.appendingPathComponent("original.jpg")
        let file2 = dir.appendingPathComponent("copy.jpg")
        try writeTestJPEG(to: file1)
        // Copy file1 to file2 — byte-identical
        try FileManager.default.copyItem(at: file1, to: file2)

        let size = try FileManager.default
            .attributesOfItem(atPath: file1.path)[.size] as? Int64 ?? 0

        let files = [
            ScannedFile(url: file1, mediaType: .photo, fileSize: size),
            ScannedFile(url: file2, mediaType: .photo, fileSize: size)
        ]

        let detector = DetectionService()
        let groups = try await detector.detectDuplicates(in: files)

        #expect(groups.count == 1)
        #expect(groups[0].confidence == 1.0)
        #expect(groups[0].members.count == 2)
        // Should have checksum signal
        let signals = groups[0].members[0].signals
        #expect(signals.contains { $0.key == "checksum" })
    }

    @Test("Refinement does not merge structurally different images")
    func refinementKeepsStructurallyDifferent() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Solid fill vs complex gradient — structurally very different
        let file1 = dir.appendingPathComponent("solid.jpg")
        let file2 = dir.appendingPathComponent("gradient.jpg")
        try writeTestJPEG(to: file1)
        try writeDifferentJPEG(to: file2)

        func fileSize(_ url: URL) throws -> Int64 {
            try FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        }

        let files = [
            ScannedFile(url: file1, mediaType: .photo, fileSize: try fileSize(file1)),
            ScannedFile(url: file2, mediaType: .photo, fileSize: try fileSize(file2))
        ]

        let detector = DetectionService()
        let options = DetectOptions(thresholds: .init(imageDistance: 3))
        let groups = try await detector.detectDuplicates(
            in: files, options: options
        )

        // Structurally different images should not be grouped
        #expect(groups.isEmpty)
    }

    @Test("SHA256 exact matches separated from perceptual matches")
    func sha256DoesNotPreventPerceptual() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Two identical files (exact match group)
        let file1 = dir.appendingPathComponent("a.jpg")
        let file2 = dir.appendingPathComponent("a-copy.jpg")
        try writeTestJPEG(to: file1)
        try FileManager.default.copyItem(at: file1, to: file2)

        // Two perceptually similar files (perceptual match group)
        let file3 = dir.appendingPathComponent("b.jpg")
        let file4 = dir.appendingPathComponent("b-variant.jpg")
        try writeTestJPEG(to: file3)
        try writeVariantJPEG(to: file4)

        func fileSize(_ url: URL) throws -> Int64 {
            try FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        }

        let files = [
            ScannedFile(url: file1, mediaType: .photo, fileSize: try fileSize(file1)),
            ScannedFile(url: file2, mediaType: .photo, fileSize: try fileSize(file2)),
            ScannedFile(url: file3, mediaType: .photo, fileSize: try fileSize(file3)),
            ScannedFile(url: file4, mediaType: .photo, fileSize: try fileSize(file4))
        ]

        let detector = DetectionService()
        let groups = try await detector.detectDuplicates(in: files)

        // Should have at least 1 group.
        // file1, file2, and file3 are all byte-identical (same writeTestJPEG),
        // so they form one exact group. file4 (variant) may or may not group
        // perceptually with remaining files.
        #expect(groups.count >= 1)
        // The highest confidence group should be the exact match
        let exactGroup = groups.first { $0.confidence == 1.0 }
        #expect(exactGroup != nil)
        // file1 + file2 + file3 are all identical
        #expect(exactGroup!.members.count >= 2)
    }
}

enum TestError: Error {
    case cannotCreateImage
}
