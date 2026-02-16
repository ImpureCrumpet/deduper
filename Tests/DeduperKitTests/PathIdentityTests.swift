import Testing
import Foundation
@testable import DeduperKit

@Suite("PathIdentity")
struct PathIdentityTests {
    @Test("Canonical resolves symlinks")
    func canonicalResolvesSymlinks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let realDir = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: realDir, withIntermediateDirectories: true
        )
        let file = realDir.appendingPathComponent("test.jpg")
        FileManager.default.createFile(
            atPath: file.path, contents: Data("x".utf8)
        )

        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: realDir
        )

        let linkFile = link.appendingPathComponent("test.jpg")
        let canonical = PathIdentity.canonical(linkFile)
        let expected = PathIdentity.canonical(file)

        #expect(canonical == expected)
    }

    @Test("Canonical normalizes double dots")
    func canonicalNormalizesDoubleDots() {
        let path = "/Users/test/foo/../bar/image.jpg"
        let canonical = PathIdentity.canonical(path)

        #expect(!canonical.contains(".."))
        #expect(canonical.hasSuffix("/Users/test/bar/image.jpg"))
    }

    @Test("Canonical is idempotent")
    func canonicalIsIdempotent() {
        let path = "/Users/test/Photos/image.jpg"
        let once = PathIdentity.canonical(path)
        let twice = PathIdentity.canonical(once)

        #expect(once == twice)
    }

    @Test("Canonical normalizes trailing slash")
    func canonicalNormalizesTrailingSlash() {
        let withSlash = PathIdentity.canonical("/Users/test/Photos/")
        let without = PathIdentity.canonical("/Users/test/Photos")

        #expect(withSlash == without)
    }

    @Test("canonicalRoot resolves symlinked directory")
    func canonicalRootResolvesSymlink() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let realDir = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: realDir, withIntermediateDirectories: true
        )

        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: realDir
        )

        let canonicalRoot = PathIdentity.canonicalRoot(link)
        let expected = PathIdentity.canonicalRoot(realDir)

        #expect(canonicalRoot == expected)
    }

    @Test("String and URL overloads agree")
    func stringAndURLOverloadsAgree() {
        let path = "/Users/test/foo/../bar/image.jpg"
        let url = URL(fileURLWithPath: path)
        let fromString = PathIdentity.canonical(path)
        let fromURL = PathIdentity.canonical(url)

        #expect(fromString == fromURL)
    }
}
