import Testing
import Foundation
@testable import DeduperKit

@Suite("MergeLifecycle")
struct MergeLifecycleTests {
    let service = MergeService()

    private func makeTempDir() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(
            ".deduper-lifecycle-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeTestFile(
        in dir: URL, name: String = "test.jpg"
    ) throws -> URL {
        let file = dir.appendingPathComponent(name)
        try Data("content-\(name)".utf8).write(to: file)
        return file
    }

    /// Read journal entries, splitting each line on the first space
    /// to separate timestamp from entry. Returns entry portions only.
    private func readJournalEntries(
        txId: UUID, logDir: URL
    ) throws -> [String] {
        let path = logDir.appendingPathComponent(
            "merge-\(txId.uuidString).journal.ndjson"
        )
        let text = try String(contentsOf: path, encoding: .utf8)
        return text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let spaceIdx = line.firstIndex(of: " ") else {
                    return nil
                }
                return String(line[line.index(after: spaceIdx)...])
            }
    }

    // MARK: - merge → purge

    @Test("merge then purge: files deleted, status becomes purged")
    func mergeThenPurge() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        let file = try makeTestFile(in: dir)
        let asset = AssetBundle(primary: file, companions: [])

        let tx = try service.moveToQuarantine(
            assets: [asset],
            logDirectory: logDir,
            quarantineRoot: qDir
        )
        #expect(tx.status == .completed)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let deleted = try service.purge(
            transaction: tx, logDirectory: logDir
        )
        #expect(deleted == 1)

        try service.markPurged(
            transaction: tx, logDirectory: logDir
        )

        let all = try service.listTransactions(logDirectory: logDir)
        let reloaded = try #require(all.first { $0.id == tx.id })
        #expect(reloaded.status == .purged)

        // Quarantined file should be gone
        if let trashedPath = tx.entries.first?.trashedPath {
            #expect(!FileManager.default.fileExists(atPath: trashedPath))
        }
    }

    // MARK: - merge → undo

    @Test("merge then undo: files restored, status becomes undone")
    func mergeThenUndo() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        let file = try makeTestFile(in: dir, name: "photo.jpg")
        let originalContent = try Data(contentsOf: file)
        let asset = AssetBundle(primary: file, companions: [])

        let tx = try service.moveToQuarantine(
            assets: [asset],
            logDirectory: logDir,
            quarantineRoot: qDir
        )
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let failures = service.undo(transaction: tx)
        #expect(failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Content integrity
        let restored = try Data(contentsOf: file)
        #expect(restored == originalContent)

        try service.markUndone(
            transaction: tx, logDirectory: logDir
        )

        let all = try service.listTransactions(logDirectory: logDir)
        let reloaded = try #require(all.first { $0.id == tx.id })
        #expect(reloaded.status == .undone)
    }

    // MARK: - undo → purge rejected

    @Test("purge on undone transaction is rejected")
    func undoThenPurgeRejected() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        let file = try makeTestFile(in: dir)
        let asset = AssetBundle(primary: file, companions: [])

        let tx = try service.moveToQuarantine(
            assets: [asset],
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        let failures = service.undo(transaction: tx)
        #expect(failures.isEmpty)
        try service.markUndone(
            transaction: tx, logDirectory: logDir
        )

        // Re-read the undone transaction from disk
        let all = try service.listTransactions(logDirectory: logDir)
        let undone = try #require(all.first { $0.id == tx.id })
        #expect(undone.status == .undone)

        // Purge should throw
        #expect(throws: MergeError.self) {
            _ = try service.purge(
                transaction: undone, logDirectory: logDir
            )
        }
    }

    // MARK: - undo → re-merge

    @Test("undo then re-merge creates a new transaction")
    func undoThenReMerge() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        let file = try makeTestFile(in: dir)
        let asset = AssetBundle(primary: file, companions: [])

        let tx1 = try service.moveToQuarantine(
            assets: [asset],
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Undo
        let failures = service.undo(transaction: tx1)
        #expect(failures.isEmpty)
        try service.markUndone(
            transaction: tx1, logDirectory: logDir
        )
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Re-merge the same file
        let asset2 = AssetBundle(primary: file, companions: [])
        let tx2 = try service.moveToQuarantine(
            assets: [asset2],
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        #expect(tx2.id != tx1.id)
        #expect(tx2.status == .completed)

        let all = try service.listTransactions(logDirectory: logDir)
        #expect(all.count == 2)

        let statuses = all.map { $0.status }
        #expect(statuses.contains(TransactionStatus.undone))
        #expect(statuses.contains(TransactionStatus.completed))
    }

    // MARK: - Journal content verification

    @Test("Journal records lifecycle transitions in order")
    func journalContentVerification() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        // Use a filename with spaces to validate parsing
        let file = try makeTestFile(
            in: dir, name: "my vacation photo.jpg"
        )
        let asset = AssetBundle(primary: file, companions: [])

        let tx = try service.moveToQuarantine(
            assets: [asset],
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Undo
        _ = service.undo(transaction: tx)
        try service.markUndone(
            transaction: tx, logDirectory: logDir
        )

        let entries = try readJournalEntries(
            txId: tx.id, logDir: logDir
        )

        // Expect: planned, moved:..., completed, undone
        #expect(entries.count == 4)
        #expect(entries[0] == "planned")
        #expect(entries[1].hasPrefix("moved:"))
        #expect(entries[1].contains("my vacation photo.jpg"))
        #expect(entries[2] == "completed")
        #expect(entries[3] == "undone")
    }
}
