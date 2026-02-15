import Testing
import Foundation
@testable import DeduperKit

@Suite("CompanionResolver")
struct CompanionResolverTests {
    let resolver = CompanionResolver()

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "deduper-companion-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("AAE sidecar detected for HEIC file")
    func aaeDetected() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let heic = dir.appendingPathComponent("IMG_001.heic")
        let aae = dir.appendingPathComponent("IMG_001.aae")
        try Data("photo".utf8).write(to: heic)
        try Data("adjustments".utf8).write(to: aae)

        let result = resolver.resolve(for: heic)

        #expect(result.hasCompanions)
        #expect(result.companions.count == 1)
        #expect(result.companions[0].url == aae)
        if case .sidecar(let ext) = result.companions[0].relationship {
            #expect(ext == "aae")
        } else {
            Issue.record("Expected sidecar relationship")
        }
    }

    @Test("Keeper's companions are preserved")
    func keeperCompanionsPreserved() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let keeper = dir.appendingPathComponent("IMG_001.heic")
        let keeperAAE = dir.appendingPathComponent("IMG_001.aae")
        try Data("keeper".utf8).write(to: keeper)
        try Data("adjustments".utf8).write(to: keeperAAE)

        let result = resolver.resolve(for: keeper)

        // Companions exist for the keeper
        #expect(result.hasCompanions)
        // All URLs include primary + companions
        #expect(result.allURLs.count == 2)
    }

    @Test("Live Photo pair detected by stem match")
    func livePhotoPairDetected() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let heic = dir.appendingPathComponent("IMG_002.heic")
        let mov = dir.appendingPathComponent("IMG_002.mov")
        try Data("photo".utf8).write(to: heic)
        try Data("video".utf8).write(to: mov)

        let result = resolver.resolve(for: heic)

        #expect(result.hasCompanions)
        let liveVideoCompanion = result.companions.first {
            $0.relationship == .livePhotoVideo
        }
        #expect(liveVideoCompanion != nil)
        #expect(liveVideoCompanion?.url == mov)
    }

    @Test("XMP sidecar detected")
    func xmpDetected() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let raw = dir.appendingPathComponent("DSC_1234.nef")
        let xmp = dir.appendingPathComponent("DSC_1234.xmp")
        try Data("raw".utf8).write(to: raw)
        try Data("metadata".utf8).write(to: xmp)

        let result = resolver.resolve(for: raw)

        #expect(result.hasCompanions)
        #expect(
            result.companions.contains { $0.url == xmp }
        )
    }

    @Test("No companions for isolated file")
    func noCompanions() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("alone.jpg")
        try Data("photo".utf8).write(to: file)

        let result = resolver.resolve(for: file)

        #expect(!result.hasCompanions)
        #expect(result.companions.isEmpty)
    }

    @Test("Multiple sidecars detected")
    func multipleSidecars() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let heic = dir.appendingPathComponent("IMG_003.heic")
        let aae = dir.appendingPathComponent("IMG_003.aae")
        let mov = dir.appendingPathComponent("IMG_003.mov")
        try Data("photo".utf8).write(to: heic)
        try Data("adj".utf8).write(to: aae)
        try Data("video".utf8).write(to: mov)

        let result = resolver.resolve(for: heic)

        #expect(result.companions.count == 2)
        #expect(result.allURLs.count == 3)
    }
}
