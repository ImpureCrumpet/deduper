import Testing
import Foundation
@testable import DeduperKit

@Suite("ScanService")
struct ScanServiceTests {
    let service = ScanService()

    /// Create a temporary directory with known files for scanning.
    private func makeTempDir(
        files: [String: Data] = [:]
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("deduper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true
        )
        for (name, data) in files {
            let path = tmp.appendingPathComponent(name)
            // Create subdirectories if needed
            let dir = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            try data.write(to: path)
        }
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Scan finds image files")
    func scanFindsImages() async throws {
        let dir = try makeTempDir(files: [
            "photo1.jpg": Data(repeating: 0xFF, count: 100),
            "photo2.png": Data(repeating: 0xAA, count: 200),
            "readme.txt": Data("hello".utf8)
        ])
        defer { cleanup(dir) }

        var files: [ScannedFile] = []
        for try await event in service.scan(directory: dir) {
            if case .item(let file) = event {
                files.append(file)
            }
        }

        #expect(files.count == 2)
        let names = Set(files.map { $0.url.lastPathComponent })
        #expect(names.contains("photo1.jpg"))
        #expect(names.contains("photo2.png"))
    }

    @Test("Scan classifies media types correctly")
    func scanClassifiesTypes() async throws {
        let dir = try makeTempDir(files: [
            "image.heic": Data(count: 50),
            "clip.mp4": Data(count: 50),
            "song.mp3": Data(count: 50)
        ])
        defer { cleanup(dir) }

        var files: [ScannedFile] = []
        for try await event in service.scan(directory: dir) {
            if case .item(let file) = event {
                files.append(file)
            }
        }

        let typeMap = Dictionary(
            uniqueKeysWithValues: files.map {
                ($0.url.lastPathComponent, $0.mediaType)
            }
        )
        #expect(typeMap["image.heic"] == .photo)
        #expect(typeMap["clip.mp4"] == .video)
        #expect(typeMap["song.mp3"] == .audio)
    }

    @Test("Scan excludes hidden files with rule")
    func scanExcludesHidden() async throws {
        let dir = try makeTempDir(files: [
            "visible.jpg": Data(count: 50),
            ".hidden.jpg": Data(count: 50)
        ])
        defer { cleanup(dir) }

        let options = ScanOptions(excludes: [
            ExcludeRule(.isHidden, description: "Skip hidden")
        ])

        var files: [ScannedFile] = []
        for try await event in service.scan(
            directory: dir, options: options
        ) {
            if case .item(let file) = event {
                files.append(file)
            }
        }

        #expect(files.count == 1)
        #expect(files[0].url.lastPathComponent == "visible.jpg")
    }

    @Test("Scan reports metrics in finished event")
    func scanReportsMetrics() async throws {
        let dir = try makeTempDir(files: [
            "a.jpg": Data(count: 10),
            "b.png": Data(count: 10),
            "c.txt": Data(count: 10)
        ])
        defer { cleanup(dir) }

        var metrics: ScanMetrics?
        for try await event in service.scan(directory: dir) {
            if case .finished(let m) = event {
                metrics = m
            }
        }

        let m = try #require(metrics)
        #expect(m.totalFiles == 3)
        #expect(m.mediaFiles == 2)
        #expect(m.duration > 0)
    }

    @Test("Scan recurses into subdirectories")
    func scanRecurses() async throws {
        let dir = try makeTempDir(files: [
            "root.jpg": Data(count: 10),
            "sub/nested.png": Data(count: 10),
            "sub/deep/deeper.heic": Data(count: 10)
        ])
        defer { cleanup(dir) }

        var files: [ScannedFile] = []
        for try await event in service.scan(directory: dir) {
            if case .item(let file) = event {
                files.append(file)
            }
        }

        #expect(files.count == 3)
    }

    @Test("Scan two directories finds files from both")
    func scanMultipleDirectories() async throws {
        let dir1 = try makeTempDir(files: [
            "photo1.jpg": Data(repeating: 0xFF, count: 100)
        ])
        let dir2 = try makeTempDir(files: [
            "photo2.png": Data(repeating: 0xAA, count: 200)
        ])
        defer { cleanup(dir1); cleanup(dir2) }

        var files: [ScannedFile] = []
        for try await event in service.scan(
            directories: [dir1, dir2]
        ) {
            if case .item(let file) = event {
                files.append(file)
            }
        }

        #expect(files.count == 2)
        let names = Set(files.map { $0.url.lastPathComponent })
        #expect(names.contains("photo1.jpg"))
        #expect(names.contains("photo2.png"))
    }

    @Test("Scan records file sizes")
    func scanRecordsFileSizes() async throws {
        let dir = try makeTempDir(files: [
            "sized.jpg": Data(repeating: 0x42, count: 512)
        ])
        defer { cleanup(dir) }

        var files: [ScannedFile] = []
        for try await event in service.scan(directory: dir) {
            if case .item(let file) = event {
                files.append(file)
            }
        }

        #expect(files.count == 1)
        #expect(files[0].fileSize == 512)
    }
}
