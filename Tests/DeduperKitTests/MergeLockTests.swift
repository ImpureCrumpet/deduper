import Testing
import Foundation
@testable import DeduperKit

@Suite("MergeLock")
struct MergeLockTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".deduper-test-lock-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Basic acquire/release

    @Test("Acquire creates lock file, release removes it")
    func acquireAndRelease() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let lock = MergeLock(logDirectory: dir)

        try lock.acquire(owner: "test", sessionId: UUID())
        #expect(
            FileManager.default.fileExists(atPath: lock.lockURL.path)
        )

        lock.release()
        #expect(
            !FileManager.default.fileExists(atPath: lock.lockURL.path)
        )
    }

    @Test("isHeld true while lock held, false after release")
    func isHeldReflectsState() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let lock = MergeLock(logDirectory: dir)

        #expect(!lock.isHeld)
        try lock.acquire(owner: "test", sessionId: UUID())
        #expect(lock.isHeld)
        lock.release()
        #expect(!lock.isHeld)
    }

    // MARK: - Contention

    @Test("Second acquire while first held throws lockHeld")
    func concurrentAcquireThrows() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let lock = MergeLock(logDirectory: dir)

        try lock.acquire(owner: "first", sessionId: UUID())
        defer { lock.release() }

        #expect(throws: MergeError.self) {
            try lock.acquire(owner: "second", sessionId: UUID())
        }
    }

    @Test("lockHeld error message contains owner and PID")
    func lockHeldErrorMessage() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let lock = MergeLock(logDirectory: dir)

        try lock.acquire(owner: "ui", sessionId: UUID())
        defer { lock.release() }

        do {
            try lock.acquire(owner: "cli", sessionId: UUID())
            Issue.record("Expected throw")
        } catch let err as MergeError {
            if case .lockHeld(let owner, let pid, _) = err {
                #expect(owner == "ui")
                #expect(pid == ProcessInfo.processInfo.processIdentifier)
            } else {
                Issue.record("Wrong error case: \(err)")
            }
        }
    }

    // MARK: - Stale lock detection

    @Test("Stale lock (dead PID) is overridden automatically")
    func staleLockOverridden() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let lock = MergeLock(logDirectory: dir)

        // Write a lock file with PID 1 (init/launchd — always alive)
        // and with PID Int32.max which will never be a live process.
        // We can't safely kill a real process in tests, so write a
        // deliberately invalid PID file manually.
        let stalePayload = """
        {"pid":2147483647,"startedAt":"2020-01-01T00:00:00Z","owner":"zombie","sessionId":"00000000-0000-0000-0000-000000000000"}
        """
        try stalePayload.write(
            to: lock.lockURL, atomically: true, encoding: .utf8
        )

        // PID Int32.max is almost certainly dead; acquire should succeed.
        // (If the test machine has a process with PID 2^31-1, this
        // test will fail, which is the correct behavior.)
        try lock.acquire(owner: "test", sessionId: UUID())
        defer { lock.release() }
        #expect(lock.isHeld)
    }

    // MARK: - Integration: moveToQuarantine respects lock

    @Test("moveToQuarantine throws lockHeld when lock already held")
    func moveToQuarantineRespectsLock() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true
        )

        // Hold the lock externally
        let lock = MergeLock(logDirectory: logDir)
        try lock.acquire(owner: "external", sessionId: UUID())
        defer { lock.release() }

        let service = MergeService()
        #expect(throws: MergeError.self) {
            try service.moveToQuarantine(
                assets: [],
                logDirectory: logDir
            )
        }
    }

    @Test("undo returns lockHeld failure when lock held")
    func undoRespectsLock() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let logDir = dir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true
        )

        let lock = MergeLock(logDirectory: logDir)
        try lock.acquire(owner: "external", sessionId: UUID())
        defer { lock.release() }

        let tx = MergeTransaction(
            id: UUID(),
            date: Date(),
            entries: [],
            errors: [],
            mode: .quarantine,
            status: .completed,
            sessionId: UUID(),
            groupIds: [UUID()]
        )

        let service = MergeService()
        let failures = service.undo(
            transaction: tx, logDirectory: logDir
        )
        #expect(!failures.isEmpty)
        #expect(failures[0].contains("in progress"))
    }
}
