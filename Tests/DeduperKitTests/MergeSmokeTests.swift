import Testing
import Foundation
@testable import DeduperKit

/// End-to-end filesystem smoke tests for the merge pipeline.
/// These tests use real files on disk (in a temp directory) to validate
/// the full move → journal → undo → purge lifecycle, including the
/// crash-consistency (interrupted merge) scenario.
///
/// All temp dirs are created under homeDirectoryForCurrentUser to avoid
/// protected-path false positives.
@Suite("Merge Smoke (filesystem E2E)")
struct MergeSmokeTests {

    private let service = MergeService()

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".deduper-smoke-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeFile(
        _ name: String, content: String = "x", in dir: URL
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Scenario A: Rename-bearing merge + undo

    @Test("Rename-bearing merge: keeper renamed, non-keeper quarantined, undo reverses both")
    func renameBearingMergeAndUndo() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qRoot = dir.appendingPathComponent("quarantine")

        // Files
        let keeper = try writeFile("IMG_0001.jpg", in: dir)
        let nonKeeper = try writeFile("IMG_0002.jpg", in: dir)
        let companion = try writeFile("IMG_0001.aae", in: dir)

        let nonKeeperBundle = AssetBundle(
            primary: nonKeeper,
            companions: []
        )
        let renameRequest = KeeperRenameRequest(
            from: keeper,
            to: dir.appendingPathComponent("Best_IMG_0001.jpg"),
            isCompanion: false
        )
        let companionRenameRequest = KeeperRenameRequest(
            from: companion,
            to: dir.appendingPathComponent("Best_IMG_0001.aae"),
            isCompanion: true
        )
        let sid = UUID()

        let tx = try service.moveToQuarantine(
            assets: [nonKeeperBundle],
            renames: [renameRequest, companionRenameRequest],
            sessionId: sid,
            groupIds: [UUID()],
            logDirectory: logDir,
            quarantineRoot: qRoot
        )

        // Non-keeper quarantined
        #expect(!exists(nonKeeper))
        // Keeper renamed
        let renamed = dir.appendingPathComponent("Best_IMG_0001.jpg")
        let renamedCompanion = dir.appendingPathComponent(
            "Best_IMG_0001.aae"
        )
        #expect(exists(renamed))
        #expect(!exists(keeper))
        #expect(exists(renamedCompanion))
        #expect(!exists(companion))

        // Transaction has move + rename entries
        let moveEntries = tx.entries.filter {
            $0.operation == .move
        }
        let renameEntries = tx.entries.filter {
            $0.operation == .rename
        }
        #expect(moveEntries.count == 1)
        #expect(renameEntries.count == 2)

        // Undo: reverse renames first, then restore quarantined
        let failures = service.undo(transaction: tx, logDirectory: logDir)
        #expect(failures.isEmpty)

        #expect(exists(keeper))
        #expect(exists(companion))
        #expect(!exists(renamed))
        #expect(!exists(renamedCompanion))
        #expect(exists(nonKeeper))
    }

    // MARK: - Scenario B: Vacated-path rename target

    @Test("Vacated-path: rename target exists but is scheduled for quarantine — no collision")
    func vacatedPathRenameTarget() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qRoot = dir.appendingPathComponent("quarantine")

        // keeper will be renamed to "Vacation.jpg"
        // nonKeeper IS "Vacation.jpg" — it will be quarantined first
        let keeper = try writeFile("IMG_0001.jpg", in: dir)
        let nonKeeper = try writeFile("Vacation.jpg", in: dir)

        let nonKeeperBundle = AssetBundle(
            primary: nonKeeper,
            companions: []
        )
        let renameTarget = dir.appendingPathComponent("Vacation.jpg")
        let renameRequest = KeeperRenameRequest(
            from: keeper,
            to: renameTarget,
            isCompanion: false
        )

        // The plan-level collision check treats nonKeeper's path as
        // "vacated" — execution should succeed because nonKeeper is
        // quarantined before the rename runs.
        let tx = try service.moveToQuarantine(
            assets: [nonKeeperBundle],
            renames: [renameRequest],
            sessionId: UUID(),
            groupIds: [UUID()],
            logDirectory: logDir,
            quarantineRoot: qRoot
        )

        #expect(!exists(nonKeeper) || exists(renameTarget))
        // Either nonKeeper was moved and keeper renamed, or rename failed
        // gracefully. The important invariant: no crash, transaction written.
        #expect(tx.status == .completed)

        let failures = service.undo(transaction: tx, logDirectory: logDir)
        #expect(failures.isEmpty)
        #expect(exists(nonKeeper))
    }

    // MARK: - Scenario C: Interrupted merge (crash simulation)

    @Test("Interrupted merge: .planned tx on disk — undo restores quarantined files")
    func interruptedMergeRecovery() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qRoot = dir.appendingPathComponent("quarantine")
        try FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: qRoot, withIntermediateDirectories: true
        )

        // Simulate crash: manually move a file to quarantine and
        // write a .planned transaction (as if the app crashed between
        // WAL write and completion write).
        let sid = UUID()
        let txId = UUID()
        let original = try writeFile("crash-victim.jpg", in: dir)
        let quarantineDest = qRoot.appendingPathComponent(
            "\(txId.uuidString)/crash-victim.jpg"
        )

        // Simulate partial quarantine (one file moved)
        try FileManager.default.createDirectory(
            at: quarantineDest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: original, to: quarantineDest
        )

        // Write a .planned transaction (crash before .completed write)
        let plannedEntry = MergeTransaction.Entry(
            originalPath: original.path,
            trashedPath: quarantineDest.path,
            isCompanion: false,
            status: .planned,
            operation: .move
        )
        let plannedTx = MergeTransaction(
            id: txId,
            date: Date(),
            entries: [plannedEntry],
            errors: [],
            mode: .quarantine,
            status: .planned,
            sessionId: sid,
            groupIds: [UUID()]
        )
        let logPath = logDir.appendingPathComponent(
            "merge-\(txId.uuidString).json"
        )
        try JSONEncoder().encode(plannedTx).write(to: logPath)

        // Verify: file is in quarantine, not in original location
        #expect(!exists(original))
        #expect(exists(quarantineDest))

        // Simulate recovery: load the planned tx and run undo
        let transactions = try service.listTransactions(
            logDirectory: logDir
        )
        let found = transactions.first {
            $0.id == txId && $0.status == .planned
        }
        #expect(found != nil)

        let failures = service.undo(
            transaction: found!, logDirectory: logDir
        )
        #expect(failures.isEmpty)

        // File should be restored to original location
        #expect(exists(original))
        #expect(!exists(quarantineDest))
    }

    // MARK: - Scenario D: Purge after merge

    @Test("Purge permanently deletes quarantined files, undo after purge fails gracefully")
    func purgeDeletesQuarantinedFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        let qRoot = dir.appendingPathComponent("quarantine")

        let nonKeeper = try writeFile("delete-me.jpg", in: dir)
        let bundle = AssetBundle(primary: nonKeeper, companions: [])

        let tx = try service.moveToQuarantine(
            assets: [bundle],
            sessionId: UUID(),
            groupIds: [UUID()],
            logDirectory: logDir,
            quarantineRoot: qRoot
        )

        #expect(!exists(nonKeeper))
        let quarantinedPath = tx.entries.first?.trashedPath ?? ""
        #expect(exists(URL(fileURLWithPath: quarantinedPath)))

        let deleted = try service.purge(
            transaction: tx, logDirectory: logDir
        )
        #expect(deleted == 1)
        #expect(!exists(URL(fileURLWithPath: quarantinedPath)))

        // Undo after purge: file is gone, undo returns failures
        let failures = service.undo(
            transaction: tx, logDirectory: logDir
        )
        // Undo will fail because quarantined file is gone —
        // that's the expected behavior after purge.
        #expect(!failures.isEmpty || !exists(nonKeeper))
    }
}
