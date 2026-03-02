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
            fileURLWithPath: "/System/Library/fake.jpg"
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

        let failures = service.undo(
            transaction: transaction, logDirectory: logDir
        )
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

    @Test("Transaction stores sessionId when provided")
    func transactionStoresSessionId() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("session-test.jpg")
        try Data("content".utf8).write(to: file)
        let sessionId = UUID()

        let transaction = try service.moveToQuarantine(
            assets: [AssetBundle(primary: file)],
            sessionId: sessionId,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        #expect(transaction.sessionId == sessionId)

        // Persisted log also has sessionId
        let loaded = try service.listTransactions(
            logDirectory: logDir
        )
        #expect(loaded.count == 1)
        #expect(loaded[0].sessionId == sessionId)
    }

    @Test("Transaction without sessionId decodes as nil")
    func transactionWithoutSessionIdDecodesNil() throws {
        let transaction = MergeTransaction(
            id: UUID(),
            date: Date(),
            entries: [],
            errors: []
        )
        let data = try JSONEncoder().encode(transaction)
        let decoded = try JSONDecoder().decode(
            MergeTransaction.self, from: data
        )
        #expect(decoded.sessionId == nil)
    }

    @Test("markUndone rewrites transaction with undone status")
    func markUndoneRewritesStatus() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("undo-mark.jpg")
        try Data("content".utf8).write(to: file)

        let transaction = try service.moveToQuarantine(
            assets: [AssetBundle(primary: file)],
            logDirectory: logDir,
            quarantineRoot: qDir
        )
        #expect(transaction.status == .completed)

        try service.markUndone(
            transaction: transaction,
            logDirectory: logDir
        )

        // Re-read from disk
        let all = try service.listTransactions(
            logDirectory: logDir
        )
        let updated = all.first { $0.id == transaction.id }
        #expect(updated?.status == .undone)
        // Entries preserved for audit
        #expect(updated?.entries.count == transaction.entries.count)
    }

    @Test("Transaction stores groupIds when provided")
    func transactionStoresGroupIds() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("groups-test.jpg")
        try Data("content".utf8).write(to: file)
        let groupIds = [UUID(), UUID()]

        let transaction = try service.moveToQuarantine(
            assets: [AssetBundle(primary: file)],
            groupIds: groupIds,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        #expect(transaction.groupIds == groupIds)

        // Persisted log also has groupIds
        let loaded = try service.listTransactions(
            logDirectory: logDir
        )
        #expect(loaded.first?.groupIds == groupIds)
    }

    @Test("Forward-compatible decoding: unknown status")
    func forwardCompatibleDecoding() throws {
        // Simulate a transaction log from a future version with
        // an unknown status value
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "date": 0,
            "entries": [],
            "errors": [],
            "mode": "quarantine",
            "status": "archived"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(
            MergeTransaction.self, from: json
        )

        // Should decode as .unknown, not throw
        if case .unknown(let raw) = decoded.status {
            #expect(raw == "archived")
        } else {
            Issue.record(
                "Expected .unknown, got \(decoded.status)"
            )
        }

        // Round-trip preserves the raw value
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(
            MergeTransaction.self, from: reEncoded
        )
        if case .unknown(let raw) = reDecoded.status {
            #expect(raw == "archived")
        } else {
            Issue.record("Round-trip lost unknown status")
        }
    }

    @Test("markUndone preserves groupIds in rewritten log")
    func markUndonePreservesGroupIds() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("preserve-ids.jpg")
        try Data("content".utf8).write(to: file)
        let groupIds = [UUID(), UUID()]

        let transaction = try service.moveToQuarantine(
            assets: [AssetBundle(primary: file)],
            groupIds: groupIds,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        try service.markUndone(
            transaction: transaction, logDirectory: logDir
        )

        let all = try service.listTransactions(logDirectory: logDir)
        let updated = all.first { $0.id == transaction.id }
        #expect(updated?.status == .undone)
        #expect(updated?.groupIds == groupIds)
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

    // MARK: - TransactionStatus.isStatusUndoEligible

    @Test("isStatusUndoEligible: completed is true")
    func isStatusUndoEligibleCompleted() {
        #expect(TransactionStatus.completed.isStatusUndoEligible)
    }

    @Test("isStatusUndoEligible: unknown is true")
    func isStatusUndoEligibleUnknown() {
        #expect(
            TransactionStatus.unknown("future").isStatusUndoEligible
        )
    }

    @Test("isStatusUndoEligible: undone is false")
    func isStatusUndoEligibleUndone() {
        #expect(!TransactionStatus.undone.isStatusUndoEligible)
    }

    @Test("isStatusUndoEligible: purged is false")
    func isStatusUndoEligiblePurged() {
        #expect(!TransactionStatus.purged.isStatusUndoEligible)
    }

    // MARK: - markPurged + purge guards

    @Test("markPurged writes purged status to disk")
    func markPurgedWritesStatus() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("purge-status.jpg")
        try Data("content".utf8).write(to: file)

        let transaction = try service.moveToQuarantine(
            assets: [AssetBundle(primary: file)],
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        try service.markPurged(
            transaction: transaction, logDirectory: logDir
        )

        let all = try service.listTransactions(
            logDirectory: logDir
        )
        let updated = all.first { $0.id == transaction.id }
        #expect(updated?.status == .purged)
    }

    @Test("Purged status round-trips through Codable")
    func purgedRoundTrips() throws {
        let transaction = MergeTransaction(
            id: UUID(),
            date: Date(),
            entries: [],
            errors: [],
            status: .purged
        )

        let data = try JSONEncoder().encode(transaction)
        let decoded = try JSONDecoder().decode(
            MergeTransaction.self, from: data
        )
        #expect(decoded.status == .purged)
    }

    @Test("Purge refuses undone transaction")
    func purgeRefusesUndone() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("refuse-test.jpg")
        try Data("content".utf8).write(to: file)

        let transaction = try service.moveToQuarantine(
            assets: [AssetBundle(primary: file)],
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Mark as undone
        try service.markUndone(
            transaction: transaction, logDirectory: logDir
        )

        // Re-read the undone transaction
        let all = try service.listTransactions(
            logDirectory: logDir
        )
        let undone = all.first { $0.id == transaction.id }!

        // Purge should throw
        #expect(throws: MergeError.self) {
            _ = try service.purge(
                transaction: undone, logDirectory: logDir
            )
        }
    }

    // MARK: - Protected Path Regression

    @Test("Temp directory files are not classified as protected")
    func tempDirNotProtected() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        let file = dir.appendingPathComponent("safe-file.jpg")
        try Data("content".utf8).write(to: file)

        let asset = AssetBundle(primary: file, companions: [])
        // Should succeed — temp dir is not a protected path.
        let tx = try service.moveToQuarantine(
            assets: [asset],
            logDirectory: logDir,
            quarantineRoot: qDir
        )
        #expect(tx.entries.count == 1)
        #expect(tx.errors.isEmpty)
    }

    @Test("Home directory files are not classified as protected")
    func homeDirNotProtected() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(
            ".deduper-test-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { cleanup(dir) }
        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        let file = dir.appendingPathComponent("safe-file.jpg")
        try Data("content".utf8).write(to: file)

        let asset = AssetBundle(primary: file, companions: [])
        let tx = try service.moveToQuarantine(
            assets: [asset],
            logDirectory: logDir,
            quarantineRoot: qDir
        )
        #expect(tx.entries.count == 1)
        #expect(tx.errors.isEmpty)
    }

    // MARK: - Rename Entry Tests

    @Test("Rename entry in transaction renames file on disk")
    func renameEntryRenamesFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("keeper.heic")
        try Data("keeper content".utf8).write(to: file)
        let target = dir.appendingPathComponent("Best_keeper.heic")

        let rename = KeeperRenameRequest(
            from: file, to: target
        )
        let transaction = try service.moveToQuarantine(
            assets: [],
            renames: [rename],
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // File renamed on disk
        #expect(
            !FileManager.default.fileExists(atPath: file.path)
        )
        #expect(
            FileManager.default.fileExists(atPath: target.path)
        )

        // Entry has correct operation and renamedFrom
        let renameEntries = transaction.entries.filter {
            $0.operation == .rename
        }
        #expect(renameEntries.count == 1)
        #expect(renameEntries[0].renamedFrom == file.path)
        #expect(renameEntries[0].originalPath == target.path)
        #expect(renameEntries[0].trashedPath == nil)
    }

    @Test("Undo reverses rename back to original name")
    func undoReversesRename() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("keeper.heic")
        try Data("keeper content".utf8).write(to: file)
        let target = dir.appendingPathComponent("Best_keeper.heic")

        let rename = KeeperRenameRequest(
            from: file, to: target
        )
        let transaction = try service.moveToQuarantine(
            assets: [],
            renames: [rename],
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Undo should reverse the rename
        let failures = service.undo(
            transaction: transaction, logDirectory: logDir
        )
        #expect(failures.isEmpty)

        // Original name restored
        #expect(
            FileManager.default.fileExists(atPath: file.path)
        )
        #expect(
            !FileManager.default.fileExists(atPath: target.path)
        )
    }

    @Test("Purge skips rename entries without error")
    func purgeSkipsRenameEntries() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        // Create a file to quarantine and a keeper to rename
        let nonKeeper = dir.appendingPathComponent("dup.heic")
        try Data("duplicate".utf8).write(to: nonKeeper)
        let keeper = dir.appendingPathComponent("keeper.heic")
        try Data("keeper".utf8).write(to: keeper)
        let renamedKeeper = dir.appendingPathComponent(
            "Best_keeper.heic"
        )

        let assets = [AssetBundle(primary: nonKeeper)]
        let renames = [
            KeeperRenameRequest(from: keeper, to: renamedKeeper)
        ]
        let transaction = try service.moveToQuarantine(
            assets: assets,
            renames: renames,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Should have both move and rename entries
        let moveCount = transaction.entries.filter {
            $0.operation == .move
        }.count
        let renameCount = transaction.entries.filter {
            $0.operation == .rename
        }.count
        #expect(moveCount == 1)
        #expect(renameCount == 1)

        // Purge should only delete the quarantined file
        let deleted = try service.purge(
            transaction: transaction, logDirectory: logDir
        )
        #expect(deleted == 1)

        // Renamed keeper still exists at new name
        #expect(
            FileManager.default.fileExists(
                atPath: renamedKeeper.path
            )
        )
    }

    @Test("Backward compat: entry without operation decodes as .move")
    func entryWithoutOperationDecodesAsMove() throws {
        // Simulate a pre-rename transaction log entry
        let json = """
        {
            "originalPath": "/a/b.jpg",
            "trashedPath": "/quarantine/b.jpg",
            "isCompanion": false,
            "status": "completed"
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(
            MergeTransaction.Entry.self, from: json
        )

        #expect(entry.operation == .move)
        #expect(entry.renamedFrom == nil)
    }

    @Test("Forward compat: unknown operation decodes and round-trips")
    func unknownOperationRoundTrips() throws {
        let json = """
        {
            "originalPath": "/a/b.jpg",
            "trashedPath": null,
            "isCompanion": false,
            "status": "completed",
            "operation": "hardlink"
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(
            MergeTransaction.Entry.self, from: json
        )

        if case .unknown(let raw) = entry.operation {
            #expect(raw == "hardlink")
        } else {
            Issue.record(
                "Expected .unknown, got \(entry.operation)"
            )
        }

        // Round-trip preserves the raw value
        let reEncoded = try JSONEncoder().encode(entry)
        let reDecoded = try JSONDecoder().decode(
            MergeTransaction.Entry.self, from: reEncoded
        )
        if case .unknown(let raw) = reDecoded.operation {
            #expect(raw == "hardlink")
        } else {
            Issue.record("Round-trip lost unknown operation")
        }
    }

    @Test("Companion rename entries are marked as companion")
    func companionRenameMarkedAsCompanion() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let keeper = dir.appendingPathComponent("IMG.heic")
        let sidecar = dir.appendingPathComponent("IMG.aae")
        try Data("photo".utf8).write(to: keeper)
        try Data("sidecar".utf8).write(to: sidecar)

        let renamedKeeper = dir.appendingPathComponent(
            "Best_IMG.heic"
        )
        let renamedSidecar = dir.appendingPathComponent(
            "Best_IMG.aae"
        )

        let renames = [
            KeeperRenameRequest(
                from: keeper, to: renamedKeeper
            ),
            KeeperRenameRequest(
                from: sidecar, to: renamedSidecar,
                isCompanion: true
            )
        ]
        let transaction = try service.moveToQuarantine(
            assets: [],
            renames: renames,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        let renameEntries = transaction.entries.filter {
            $0.operation == .rename
        }
        #expect(renameEntries.count == 2)

        let primaryRename = renameEntries.first {
            !$0.isCompanion
        }
        let companionRename = renameEntries.first {
            $0.isCompanion
        }
        #expect(primaryRename != nil)
        #expect(companionRename != nil)
        #expect(
            companionRename?.renamedFrom == sidecar.path
        )

        // Both files renamed on disk
        #expect(
            FileManager.default.fileExists(
                atPath: renamedKeeper.path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: renamedSidecar.path
            )
        )
    }

    @Test("Rename error tagged with .rename operation")
    func renameErrorTaggedCorrectly() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        // Create a file, then create the target so rename fails
        let keeper = dir.appendingPathComponent("keeper.heic")
        try Data("keeper".utf8).write(to: keeper)
        let target = dir.appendingPathComponent("target.heic")
        try Data("blocker".utf8).write(to: target)

        let renames = [
            KeeperRenameRequest(from: keeper, to: target)
        ]
        let transaction = try service.moveToQuarantine(
            assets: [],
            renames: renames,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Should have rename error, not move error
        #expect(transaction.errorCount == 1)
        #expect(transaction.moveErrorCount == 0)
        #expect(transaction.renameErrorCount == 1)
        #expect(transaction.errors[0].operation == .rename)
    }

    @Test("Companion rename failure rolls back keeper rename")
    func companionFailureRollsBackKeeper() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")

        // Create keeper file
        let keeper = dir.appendingPathComponent("keeper.heic")
        try Data("keeper".utf8).write(to: keeper)

        // Create a blocker at the companion's target path
        let compTarget = dir.appendingPathComponent(
            "Renamed.aae"
        )
        try Data("blocker".utf8).write(to: compTarget)

        // Keeper rename + companion rename (companion will fail
        // because target already exists)
        let keeperTarget = dir.appendingPathComponent(
            "Renamed.heic"
        )
        let companion = dir.appendingPathComponent("keeper.aae")
        try Data("sidecar".utf8).write(to: companion)

        let renames = [
            KeeperRenameRequest(
                from: keeper, to: keeperTarget
            ),
            KeeperRenameRequest(
                from: companion, to: compTarget,
                isCompanion: true
            ),
        ]
        let transaction = try service.moveToQuarantine(
            assets: [],
            renames: renames,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Keeper rename should have been rolled back
        #expect(
            FileManager.default.fileExists(atPath: keeper.path),
            "Keeper should be restored to original name"
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: keeperTarget.path
            ),
            "Keeper target should not exist after rollback"
        )
        // Companion original should still exist (rename failed)
        #expect(
            FileManager.default.fileExists(
                atPath: companion.path
            )
        )
        // No rename entries should be in the transaction
        // (rollback succeeded, so they aren't recorded)
        let renameEntries = transaction.entries.filter {
            $0.operation == .rename
        }
        #expect(renameEntries.isEmpty)
        // Should have one rename error for the companion
        #expect(transaction.renameErrorCount == 1)
    }

    @Test("Move error defaults to .move operation")
    func moveErrorDefaultsToMove() throws {
        // Backward compat: error without operation decodes as .move
        let json = """
        {
            "originalPath": "/a/b.jpg",
            "reason": "File not found"
        }
        """.data(using: .utf8)!

        let error = try JSONDecoder().decode(
            MergeTransaction.Error.self, from: json
        )
        #expect(error.operation == .move)
    }

    @Test("Rename entries in WAL planned log before execution")
    func renameInWalPlannedLog() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qDir = dir.appendingPathComponent("quarantine")
        let file = dir.appendingPathComponent("keeper.heic")
        try Data("content".utf8).write(to: file)
        let target = dir.appendingPathComponent("Renamed.heic")

        let renames = [
            KeeperRenameRequest(from: file, to: target)
        ]
        let transaction = try service.moveToQuarantine(
            assets: [],
            renames: renames,
            logDirectory: logDir,
            quarantineRoot: qDir
        )

        // Read journal to verify "planned" preceded "renamed"
        let journalPath = logDir.appendingPathComponent(
            "merge-\(transaction.id.uuidString).journal.ndjson"
        )
        let journal = try String(
            contentsOf: journalPath, encoding: .utf8
        )
        let lines = journal.components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        // First line: planned, then renamed, then completed
        #expect(lines[0].contains("planned"))
        #expect(lines[1].contains("renamed:"))
        #expect(lines[2].contains("completed"))
    }
}
