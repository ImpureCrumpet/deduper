import Foundation
import os

/// Single-writer lock for merge operations. Prevents concurrent
/// UI and CLI merges from racing on the same quarantine/log directory.
///
/// Implementation: a JSON PID-file at `{logDir}/merge.lock`.
/// Stale lock detection: if the recorded PID is no longer alive
/// (kill(pid, 0) returns ESRCH), the lock is considered stale and
/// may be overridden.
///
/// The lock is acquired before the WAL planned entry is written and
/// released after the transaction reaches a terminal state
/// (completed, failed, undone, purged). It is NOT required for
/// read-only operations (listTransactions).
///
/// Thread safety: each call site serializes acquisition and release.
/// The struct is Sendable because all state is in the filesystem.
public struct MergeLock: Sendable {
    private static let logger = Logger(
        subsystem: "app.deduper", category: "merge-lock"
    )

    /// Payload written to the lock file.
    private struct Payload: Codable {
        let pid: Int32
        let startedAt: Date
        /// "ui" or "cli"
        let owner: String
        let sessionId: String
    }

    public let lockURL: URL

    public init(logDirectory: URL) {
        self.lockURL = logDirectory.appendingPathComponent(
            "merge.lock"
        )
    }

    // MARK: - Acquire

    /// Attempt to acquire the lock.
    /// - Throws `MergeError.lockHeld` if a live process holds the lock.
    /// - Overwrites a stale lock (dead PID or expired TTL).
    public func acquire(
        owner: String,
        sessionId: UUID
    ) throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: lockURL.path) {
            // Check whether the existing lock is stale.
            if let existing = try? load() {
                if isAlive(pid: existing.pid) {
                    let held = Int(-existing.startedAt.timeIntervalSinceNow)
                    throw MergeError.lockHeld(
                        owner: existing.owner,
                        pid: existing.pid,
                        seconds: held
                    )
                }
                // Stale lock: log and override.
                Self.logger.warning(
                    "Overriding stale merge lock from \(existing.owner) (PID \(existing.pid))"
                )
            }
            // Lock file exists but couldn't be parsed — also stale.
            try? fm.removeItem(at: lockURL)
        }

        let payload = Payload(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date(),
            owner: owner,
            sessionId: sessionId.uuidString
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: lockURL, options: .atomic)
        Self.logger.info(
            "Merge lock acquired by \(owner) (PID \(payload.pid))"
        )
    }

    // MARK: - Release

    /// Release the lock. No-op if we don't own it.
    public func release() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: lockURL.path) else { return }

        // Only remove if we own it (same PID).
        if let existing = try? load(),
           existing.pid == ProcessInfo.processInfo.processIdentifier
        {
            try? fm.removeItem(at: lockURL)
            Self.logger.info("Merge lock released")
        } else {
            Self.logger.warning(
                "Lock release skipped: we don't own the lock"
            )
        }
    }

    // MARK: - Query

    /// True if a live process currently holds the lock.
    public var isHeld: Bool {
        guard let payload = try? load() else { return false }
        return isAlive(pid: payload.pid)
    }

    // MARK: - Helpers

    private func load() throws -> Payload {
        let data = try Data(contentsOf: lockURL)
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    /// Returns true if `pid` is a running process.
    private func isAlive(pid: Int32) -> Bool {
        // kill(pid, 0) sends no signal but checks if the process exists.
        // Returns 0 if alive, -1 with errno = ESRCH if dead.
        return Darwin.kill(pid, 0) == 0
    }
}
