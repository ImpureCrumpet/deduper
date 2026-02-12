import Testing
import Foundation
@testable import DeduperKit

@Suite("MergeService")
struct MergeServiceTests {
    let service = MergeService()

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("deduper-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Move file to trash creates transaction entry")
    func moveToTrashCreatesEntry() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let file = dir.appendingPathComponent("trash-me.jpg")
        try Data("test content".utf8).write(to: file)

        let transaction = try service.moveToTrash(
            files: [file],
            logDirectory: logDir
        )

        #expect(transaction.entries.count == 1)
        #expect(transaction.errors.isEmpty)
        #expect(transaction.entries[0].originalPath == file.path)

        // File should no longer exist at original path
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Protected paths are refused")
    func protectedPathsRefused() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let protectedFile = URL(fileURLWithPath: "/System/fake.jpg")

        let transaction = try service.moveToTrash(
            files: [protectedFile],
            logDirectory: logDir
        )

        #expect(transaction.entries.isEmpty)
        #expect(transaction.errors.count == 1)
        #expect(
            transaction.errors[0].reason.contains("Protected")
        )
    }

    @Test("Transaction log is persisted as JSON")
    func transactionLogPersisted() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let file = dir.appendingPathComponent("logtest.jpg")
        try Data("data".utf8).write(to: file)

        _ = try service.moveToTrash(
            files: [file],
            logDirectory: logDir
        )

        let transactions = try service.listTransactions(
            logDirectory: logDir
        )
        #expect(transactions.count == 1)
        #expect(transactions[0].entries.count == 1)
    }

    @Test("Multiple files in one transaction")
    func multipleFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        var files: [URL] = []
        for i in 0..<3 {
            let file = dir.appendingPathComponent("file\(i).jpg")
            try Data("content \(i)".utf8).write(to: file)
            files.append(file)
        }

        let transaction = try service.moveToTrash(
            files: files,
            logDirectory: logDir
        )

        #expect(transaction.entries.count == 3)
        #expect(transaction.errors.isEmpty)

        for file in files {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("Nonexistent file produces error entry")
    func nonexistentFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let missing = dir.appendingPathComponent("doesnt-exist.jpg")

        let transaction = try service.moveToTrash(
            files: [missing],
            logDirectory: logDir
        )

        #expect(transaction.entries.isEmpty)
        #expect(transaction.errors.count == 1)
    }

    @Test("MergeTransaction is Codable")
    func transactionCodable() throws {
        let transaction = MergeTransaction(
            id: UUID(),
            date: Date(),
            entries: [
                .init(originalPath: "/a/b.jpg", trashedPath: "/trash/b.jpg")
            ],
            errors: []
        )

        let data = try JSONEncoder().encode(transaction)
        let decoded = try JSONDecoder().decode(
            MergeTransaction.self, from: data
        )

        #expect(decoded.id == transaction.id)
        #expect(decoded.entries.count == 1)
        #expect(
            decoded.entries[0].originalPath == "/a/b.jpg"
        )
    }
}
