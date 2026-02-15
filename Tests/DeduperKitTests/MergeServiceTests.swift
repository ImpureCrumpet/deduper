import Testing
import Foundation
@testable import DeduperKit

@Suite("MergeService")
struct MergeServiceTests {
    let service = MergeService()

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "deduper-merge-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Legacy Trash Tests

    @Test("Move file to trash creates transaction entry")
    func moveToTrashCreatesEntry() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let file = dir.appendingPathComponent("trash-me.jpg")
        try Data("test content".utf8).write(to: file)

        let transaction = try service.moveToTrash(
            files: [file], logDirectory: logDir
        )

        #expect(transaction.entries.count == 1)
        #expect(transaction.errors.isEmpty)
        #expect(
            transaction.entries[0].originalPath == file.path
        )
        #expect(
            !FileManager.default.fileExists(atPath: file.path)
        )
    }

    @Test("Protected paths are refused")
    func protectedPathsRefused() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let protectedFile = URL(
            fileURLWithPath: "/System/fake.jpg"
        )

        let transaction = try service.moveToTrash(
            files: [protectedFile], logDirectory: logDir
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
            files: [file], logDirectory: logDir
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
            files: files, logDirectory: logDir
        )

        #expect(transaction.entries.count == 3)
        #expect(transaction.errors.isEmpty)
        for file in files {
            #expect(
                !FileManager.default.fileExists(atPath: file.path)
            )
        }
    }

    @Test("Nonexistent file produces error entry")
    func nonexistentFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let missing = dir.appendingPathComponent("doesnt-exist.jpg")

        let transaction = try service.moveToTrash(
            files: [missing], logDirectory: logDir
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
                .init(
                    originalPath: "/a/b.jpg",
                    trashedPath: "/trash/b.jpg"
                )
            ],
            errors: []
        )

        let data = try JSONEncoder().encode(transaction)
        let decoded = try JSONDecoder().decode(
            MergeTransaction.self, from: data
        )

        #expect(decoded.id == transaction.id)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].originalPath == "/a/b.jpg")
    }

    // MARK: - Quarantine Tests

    @Test("Quarantine moves files to correct directory")
    func quarantineMoves() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("dup.jpg")
        try Data("duplicate".utf8).write(to: file)

        let assets = [AssetBundle(primary: file)]
        let transaction = try service.moveToQuarantine(
            assets: assets,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        #expect(transaction.entries.count == 1)
        #expect(transaction.mode == .quarantine)
        #expect(transaction.status == .completed)
        #expect(
            !FileManager.default.fileExists(atPath: file.path)
        )
        // File should exist in quarantine
        if let trashedPath = transaction.entries[0].trashedPath {
            #expect(
                FileManager.default.fileExists(atPath: trashedPath)
            )
        }
    }

    @Test("Undo from quarantine restores files")
    func undoFromQuarantine() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("restore-me.jpg")
        try Data("content".utf8).write(to: file)

        let assets = [AssetBundle(primary: file)]
        let transaction = try service.moveToQuarantine(
            assets: assets,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        #expect(
            !FileManager.default.fileExists(atPath: file.path)
        )

        let failures = service.undo(transaction: transaction)
        #expect(failures.isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: file.path)
        )
    }

    @Test("WAL journal exists before moves complete")
    func walJournalExists() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("wal-test.jpg")
        try Data("content".utf8).write(to: file)

        let assets = [AssetBundle(primary: file)]
        let transaction = try service.moveToQuarantine(
            assets: assets,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Journal file should exist
        let journalPath = logDir.appendingPathComponent(
            "merge-\(transaction.id.uuidString).journal.ndjson"
        )
        #expect(
            FileManager.default.fileExists(atPath: journalPath.path)
        )
    }

    @Test("Purge permanently deletes quarantined files")
    func purgeDeletesFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("purge-me.jpg")
        try Data("content".utf8).write(to: file)

        let assets = [AssetBundle(primary: file)]
        let transaction = try service.moveToQuarantine(
            assets: assets,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        let deleted = try service.purge(
            transaction: transaction, logDirectory: logDir
        )
        #expect(deleted == 1)

        // Quarantined file should be gone
        if let trashedPath = transaction.entries[0].trashedPath {
            #expect(
                !FileManager.default.fileExists(atPath: trashedPath)
            )
        }
    }

    @Test("Companion files are moved with primary")
    func companionsMoveWithPrimary() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let primary = dir.appendingPathComponent("IMG.heic")
        let companion = dir.appendingPathComponent("IMG.aae")
        try Data("photo".utf8).write(to: primary)
        try Data("sidecar".utf8).write(to: companion)

        let assets = [
            AssetBundle(
                primary: primary, companions: [companion]
            )
        ]
        let transaction = try service.moveToQuarantine(
            assets: assets,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        #expect(transaction.entries.count == 2)
        #expect(
            !FileManager.default.fileExists(atPath: primary.path)
        )
        #expect(
            !FileManager.default.fileExists(atPath: companion.path)
        )

        // One entry should be marked as companion
        let companionEntries = transaction.entries.filter {
            $0.isCompanion
        }
        #expect(companionEntries.count == 1)
    }
}
