import Testing
import Foundation
@testable import DeduperKit

@Suite("FileIdentity")
struct FileIdentityTests {

    private func makeTempDir() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(
            ".deduper-fileid-test-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    @Test("samePhysicalFile returns true for hard links")
    func hardLinkReturnsTrue() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("original.txt")
        try Data("test content".utf8).write(to: original)

        let hardLink = dir.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: original, to: hardLink)

        let result = FileIdentity.samePhysicalFile(original, hardLink)
        #expect(result == true)
    }

    @Test("samePhysicalFile returns false for same-content different files")
    func sameContentReturnsFalse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = Data("identical content".utf8)
        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        try content.write(to: fileA)
        try content.write(to: fileB)

        let result = FileIdentity.samePhysicalFile(fileA, fileB)
        #expect(result == false)
    }

    @Test("samePhysicalFile returns nil for missing file")
    func missingFileReturnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = dir.appendingPathComponent("exists.txt")
        try Data("data".utf8).write(to: existing)

        let missing = dir.appendingPathComponent("does-not-exist.txt")

        let result = FileIdentity.samePhysicalFile(existing, missing)
        #expect(result == nil)
    }

    @Test("samePhysicalFile returns true through symlink to same file")
    func symlinkReturnsTrue() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("original.txt")
        try Data("symlink test".utf8).write(to: original)

        let symlink = dir.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: original
        )

        let result = FileIdentity.samePhysicalFile(original, symlink)
        #expect(result == true)
    }

    @Test("resolve returns nil for nonexistent path")
    func resolveNilForMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent/path/file.txt")
        let result = FileIdentity.resolve(missing)
        #expect(result == nil)
    }

    @Test("same() compares pre-resolved identities correctly")
    func preResolvedComparison() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)

        let hardLink = dir.appendingPathComponent("a-link.txt")
        try FileManager.default.linkItem(at: fileA, to: hardLink)

        let idA = try #require(FileIdentity.resolve(fileA))
        let idB = try #require(FileIdentity.resolve(fileB))
        let idLink = try #require(FileIdentity.resolve(hardLink))

        #expect(FileIdentity.same(idA, idLink) == true)
        #expect(FileIdentity.same(idA, idB) == false)
    }
}
