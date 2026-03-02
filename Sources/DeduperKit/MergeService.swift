import Foundation
import os

/// Handles moving duplicate files to quarantine/trash with transaction
/// logging, undo, and companion file awareness.
public struct MergeService: Sendable {
    private let logger = Logger(subsystem: "app.deduper", category: "merge")

    public init() {}

    // MARK: - Asset Bundle Merge

    /// Move asset bundles to quarantine, logging transactions for undo.
    /// Each asset is a primary file plus its companion files.
    /// Companions of the keeper are preserved; companions of non-keepers
    /// are trashed along with the non-keeper.
    ///
    /// Optional `renames` execute after quarantine moves complete.
    /// Each rename is journaled as a separate `.rename` entry in the
    /// transaction. Rename failures are non-fatal (logged as errors).
    public func moveToQuarantine(
        assets: [AssetBundle],
        renames: [KeeperRenameRequest] = [],
        sessionId: UUID? = nil,
        groupIds: [UUID]? = nil,
        logDirectory: URL? = nil,
        quarantineRoot: URL? = nil
    ) throws -> MergeTransaction {
        let logDir = logDirectory ?? defaultLogDirectory()
        try FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true
        )

        // Acquire single-writer lock before any filesystem mutations.
        let lock = MergeLock(logDirectory: logDir)
        try lock.acquire(
            owner: "ui",
            sessionId: sessionId ?? UUID()
        )
        defer { lock.release() }

        let txId = UUID()
        let qRoot = quarantineRoot
            ?? defaultQuarantineRoot(for: assets)

        // Write-ahead: create planned transaction before any moves
        var plannedEntries: [MergeTransaction.Entry] = []
        for asset in assets {
            let allFiles = [asset.primary] + asset.companions
            for file in allFiles {
                let destPath = quarantinePath(
                    for: file, transactionId: txId, root: qRoot
                )
                plannedEntries.append(.init(
                    originalPath: file.path,
                    trashedPath: destPath.path,
                    isCompanion: file != asset.primary,
                    status: .planned
                ))
            }
        }

        // Planned entries for renames
        for rename in renames {
            plannedEntries.append(.init(
                originalPath: rename.to.path,
                trashedPath: nil,
                isCompanion: rename.isCompanion,
                status: .planned,
                operation: .rename,
                renamedFrom: rename.from.path
            ))
        }

        let journalPath = logDir.appendingPathComponent(
            "merge-\(txId.uuidString).journal.ndjson"
        )
        let walTransaction = MergeTransaction(
            id: txId,
            date: Date(),
            entries: plannedEntries,
            errors: [],
            mode: .quarantine,
            status: .planned,
            sessionId: sessionId,
            groupIds: groupIds
        )
        try writeTransactionLog(walTransaction, to: logDir)
        try writeJournalEntry(
            "planned", txId: txId, to: journalPath
        )

        // Execute moves
        var completedEntries: [MergeTransaction.Entry] = []
        var errors: [MergeTransaction.Error] = []

        for asset in assets {
            let allFiles = [asset.primary] + asset.companions
            // Trash companions first, then primary
            // (so undo restores primary first)
            let ordered = allFiles.reversed()

            for file in ordered {
                if isProtectedPath(file) {
                    errors.append(.init(
                        originalPath: file.path,
                        reason: "Protected path -- refusing to move"
                    ))
                    logger.warning(
                        "Skipped protected path: \(file.path)"
                    )
                    continue
                }

                let dest = quarantinePath(
                    for: file, transactionId: txId, root: qRoot
                )

                do {
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(
                        at: file, to: dest
                    )
                    completedEntries.append(.init(
                        originalPath: file.path,
                        trashedPath: dest.path,
                        isCompanion: file != asset.primary,
                        status: .completed
                    ))
                    try writeJournalEntry(
                        "moved:\(file.path)->\(dest.path)",
                        txId: txId, to: journalPath
                    )
                    logger.info("Quarantined: \(file.lastPathComponent)")
                } catch {
                    errors.append(.init(
                        originalPath: file.path,
                        reason: error.localizedDescription
                    ))
                    logger.error(
                        "Failed to quarantine \(file.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
        }

        // Execute keeper renames (after quarantine moves).
        // Renames are ordered: keeper (isCompanion=false) then
        // its companions (isCompanion=true). Each keeper starts
        // a new group. On failure within a group, roll back any
        // already-renamed files to maintain per-group consistency.
        var renameGroups: [[(request: KeeperRenameRequest,
                             index: Int)]] = []
        for (i, rename) in renames.enumerated() {
            if !rename.isCompanion {
                renameGroups.append([(rename, i)])
            } else if !renameGroups.isEmpty {
                renameGroups[renameGroups.count - 1]
                    .append((rename, i))
            }
        }

        for group in renameGroups {
            var groupSucceeded: [(from: URL, to: URL)] = []
            var groupFailed = false

            for (rename, _) in group {
                do {
                    try FileManager.default.moveItem(
                        at: rename.from, to: rename.to
                    )
                    groupSucceeded.append(
                        (from: rename.from, to: rename.to)
                    )
                } catch {
                    groupFailed = true
                    errors.append(.init(
                        originalPath: rename.from.path,
                        reason: "Rename failed: \(error.localizedDescription)",
                        operation: .rename
                    ))
                    logger.error(
                        "Failed to rename \(rename.from.lastPathComponent): \(error.localizedDescription)"
                    )
                    break
                }
            }

            if groupFailed {
                // Roll back already-renamed files in this group
                for pair in groupSucceeded.reversed() {
                    do {
                        try FileManager.default.moveItem(
                            at: pair.to, to: pair.from
                        )
                        logger.info(
                            "Rolled back rename: \(pair.to.lastPathComponent) -> \(pair.from.lastPathComponent)"
                        )
                    } catch {
                        // Rollback failure: log but still record
                        // the completed rename so undo can handle it
                        logger.error(
                            "Rollback failed for \(pair.to.lastPathComponent): \(error.localizedDescription)"
                        )
                        completedEntries.append(.init(
                            originalPath: pair.to.path,
                            trashedPath: nil,
                            isCompanion: pair.from != pair.to,
                            status: .completed,
                            operation: .rename,
                            renamedFrom: pair.from.path
                        ))
                    }
                }
            } else {
                // All renames in this group succeeded
                for (rename, _) in group {
                    completedEntries.append(.init(
                        originalPath: rename.to.path,
                        trashedPath: nil,
                        isCompanion: rename.isCompanion,
                        status: .completed,
                        operation: .rename,
                        renamedFrom: rename.from.path
                    ))
                    do {
                        try writeJournalEntry(
                            "renamed:\(rename.from.path)"
                                + "->\(rename.to.path)",
                            txId: txId, to: journalPath
                        )
                    } catch {
                        logger.error(
                            "Journal write failed for rename: \(error.localizedDescription)"
                        )
                    }
                    logger.info(
                        "Renamed: \(rename.from.lastPathComponent) -> \(rename.to.lastPathComponent)"
                    )
                }
            }
        }

        let transaction = MergeTransaction(
            id: txId,
            date: Date(),
            entries: completedEntries,
            errors: errors,
            mode: .quarantine,
            status: .completed,
            sessionId: sessionId,
            groupIds: groupIds
        )

        try writeTransactionLog(transaction, to: logDir)
        try writeJournalEntry(
            "completed", txId: txId, to: journalPath
        )

        return transaction
    }

    // MARK: - Mark Undone

    /// Mark a transaction as undone by rewriting its log file with
    /// `.undone` status. Preserves the transaction for audit trail.
    /// Also appends an "undone" event to the journal for append-only
    /// audit history.
    public func markUndone(
        transaction: MergeTransaction,
        logDirectory: URL? = nil
    ) throws {
        let logDir = logDirectory ?? defaultLogDirectory()
        let updated = MergeTransaction(
            id: transaction.id,
            date: transaction.date,
            entries: transaction.entries,
            errors: transaction.errors,
            mode: transaction.mode,
            status: .undone,
            sessionId: transaction.sessionId,
            groupIds: transaction.groupIds
        )
        try writeTransactionLog(updated, to: logDir)

        // Append to journal for immutable audit trail
        let journalPath = logDir.appendingPathComponent(
            "merge-\(transaction.id.uuidString).journal.ndjson"
        )
        try writeJournalEntry(
            "undone", txId: transaction.id, to: journalPath
        )
    }

    /// Mark a transaction as purged by rewriting its log file with
    /// `.purged` status. Also appends a journal entry.
    public func markPurged(
        transaction: MergeTransaction,
        logDirectory: URL? = nil
    ) throws {
        let logDir = logDirectory ?? defaultLogDirectory()
        let updated = MergeTransaction(
            id: transaction.id,
            date: transaction.date,
            entries: transaction.entries,
            errors: transaction.errors,
            mode: transaction.mode,
            status: .purged,
            sessionId: transaction.sessionId,
            groupIds: transaction.groupIds
        )
        try writeTransactionLog(updated, to: logDir)

        let journalPath = logDir.appendingPathComponent(
            "merge-\(transaction.id.uuidString).journal.ndjson"
        )
        try writeJournalEntry(
            "purged", txId: transaction.id, to: journalPath
        )
    }

    /// Legacy: move files to OS Trash (for --use-trash flag).
    public func moveToTrash(
        files: [URL],
        logDirectory: URL? = nil
    ) throws -> MergeTransaction {
        let logDir = logDirectory ?? defaultLogDirectory()
        try FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true
        )

        let txId = UUID()
        var entries: [MergeTransaction.Entry] = []
        var errors: [MergeTransaction.Error] = []

        for url in files {
            if isProtectedPath(url) {
                errors.append(.init(
                    originalPath: url.path,
                    reason: "Protected path -- refusing to move"
                ))
                logger.warning(
                    "Skipped protected path: \(url.path)"
                )
                continue
            }

            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(
                    at: url, resultingItemURL: &trashedURL
                )
                entries.append(.init(
                    originalPath: url.path,
                    trashedPath: trashedURL?.path,
                    isCompanion: false,
                    status: .completed
                ))
                logger.info("Trashed: \(url.lastPathComponent)")
            } catch {
                errors.append(.init(
                    originalPath: url.path,
                    reason: error.localizedDescription
                ))
                logger.error(
                    "Failed to trash \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        let transaction = MergeTransaction(
            id: txId,
            date: Date(),
            entries: entries,
            errors: errors,
            mode: .trash,
            status: .completed
        )

        try writeTransactionLog(transaction, to: logDir)
        return transaction
    }

    // MARK: - Undo

    /// Undo a merge by restoring files from quarantine or trash.
    /// Reverses renames first (Phase 0), then restores quarantined
    /// files with primaries before companions (Phase 1).
    public func undo(
        transaction: MergeTransaction,
        logDirectory: URL? = nil
    ) -> [String] {
        var failures: [String] = []

        // Acquire lock — undo mutates quarantine files.
        let logDir = logDirectory ?? defaultLogDirectory()
        let lock = MergeLock(logDirectory: logDir)
        do {
            try lock.acquire(
                owner: "ui-undo",
                sessionId: transaction.sessionId ?? UUID()
            )
        } catch {
            return [error.localizedDescription]
        }
        defer { lock.release() }

        // Phase 0: Reverse renames before restoring quarantined files.
        // Only reverse completed renames (planned-but-unexecuted are
        // no-ops). Reverse in reverse order to reduce self-collision.
        let renameEntries = transaction.entries
            .filter { $0.operation == .rename
                && $0.status == .completed }
            .reversed()
        for entry in renameEntries {
            guard let oldPath = entry.renamedFrom else { continue }
            let currentURL = URL(
                fileURLWithPath: entry.originalPath
            )
            let originalURL = URL(fileURLWithPath: oldPath)
            do {
                try FileManager.default.moveItem(
                    at: currentURL, to: originalURL
                )
                logger.info(
                    "Reversed rename: \(currentURL.lastPathComponent) -> \(originalURL.lastPathComponent)"
                )
            } catch {
                failures.append(
                    "\(oldPath): \(error.localizedDescription)"
                )
            }
        }

        // Phase 1: Restore quarantined files (move entries only)
        let moveEntries = transaction.entries.filter {
            $0.operation == .move
        }
        let sorted = moveEntries.sorted { a, b in
            if a.isCompanion != b.isCompanion {
                return !a.isCompanion // primaries first
            }
            return false
        }

        for entry in sorted {
            guard let trashedPath = entry.trashedPath else {
                failures.append(
                    "No trash path recorded for \(entry.originalPath)"
                )
                continue
            }

            let trashedURL = URL(fileURLWithPath: trashedPath)
            let originalURL = URL(fileURLWithPath: entry.originalPath)

            do {
                // Ensure parent directory exists
                try FileManager.default.createDirectory(
                    at: originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(
                    at: trashedURL, to: originalURL
                )
                logger.info(
                    "Restored: \(originalURL.lastPathComponent)"
                )
            } catch {
                failures.append(
                    "\(entry.originalPath): \(error.localizedDescription)"
                )
            }
        }

        return failures
    }

    // MARK: - Purge

    /// Permanently delete quarantined files for a transaction.
    /// Rename entries are skipped (no quarantine file to delete).
    public func purge(
        transaction: MergeTransaction,
        logDirectory: URL? = nil
    ) throws -> Int {
        guard transaction.status != .undone else {
            throw MergeError.cannotPurgeUndone(transaction.id)
        }

        // Acquire lock — purge permanently deletes quarantined files.
        let logDir = logDirectory ?? defaultLogDirectory()
        let lock = MergeLock(logDirectory: logDir)
        try lock.acquire(
            owner: "ui-purge",
            sessionId: transaction.sessionId ?? UUID()
        )
        defer { lock.release() }
        // Only delete quarantined files (move entries)
        let moveEntries = transaction.entries.filter {
            $0.operation == .move
        }
        var deleted = 0
        for entry in moveEntries {
            guard let trashedPath = entry.trashedPath else { continue }
            let url = URL(fileURLWithPath: trashedPath)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                deleted += 1
            }
        }

        // Clean up empty quarantine directory
        for entry in moveEntries {
            guard let trashedPath = entry.trashedPath else { continue }
            let dir = URL(fileURLWithPath: trashedPath)
                .deletingLastPathComponent()
            cleanEmptyDirectories(at: dir)
        }

        return deleted
    }

    // MARK: - Transaction Listing

    /// List transaction logs from the log directory.
    public func listTransactions(
        logDirectory: URL? = nil
    ) throws -> [MergeTransaction] {
        let logDir = logDirectory ?? defaultLogDirectory()
        guard FileManager.default.fileExists(
            atPath: logDir.path
        ) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: nil
        )

        return contents
            .filter {
                $0.pathExtension == "json"
                    && !$0.lastPathComponent.contains("journal")
            }
            .compactMap { url -> MergeTransaction? in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return try? JSONDecoder().decode(
                    MergeTransaction.self, from: data
                )
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Protected Paths

    private func isProtectedPath(_ url: URL) -> Bool {
        let path = PathIdentity.canonical(url)
        // Use specific prefixes to avoid over-blocking under
        // /System/Volumes/Data (macOS firmlinks to user space).
        let protectedPrefixes = [
            "/System/Library", "/usr", "/Library",
            "/bin", "/sbin", "/Applications",
            "/private/var"
        ]
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }

    // MARK: - Quarantine Paths

    private func quarantinePath(
        for file: URL,
        transactionId: UUID,
        root: URL
    ) -> URL {
        // Preserve relative path from volume root
        let filePath = file.path
        let volumeRoot = volumeRootPath(for: file)
        let relative: String
        if filePath.hasPrefix(volumeRoot) {
            relative = String(filePath.dropFirst(volumeRoot.count))
        } else {
            relative = file.lastPathComponent
        }
        return root
            .appendingPathComponent(transactionId.uuidString)
            .appendingPathComponent(relative)
    }

    private func volumeRootPath(for url: URL) -> String {
        // For local volumes, use /Users/<user> as the relative root
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return home
        }
        // For external volumes, use /Volumes/<name>
        if url.path.hasPrefix("/Volumes/") {
            let parts = url.path.split(separator: "/")
            if parts.count >= 2 {
                return "/\(parts[0])/\(parts[1])"
            }
        }
        return "/"
    }

    private func defaultQuarantineRoot(
        for assets: [AssetBundle]
    ) -> URL {
        // Place quarantine near the source files
        if let first = assets.first {
            let dir = first.primary.deletingLastPathComponent()
            return dir.appendingPathComponent(".deduper_quarantine")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".deduper_quarantine")
    }

    private func defaultLogDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Deduper")
            .appendingPathComponent("transactions")
    }

    // MARK: - WAL Helpers

    private func writeTransactionLog(
        _ transaction: MergeTransaction,
        to logDir: URL
    ) throws {
        let logPath = logDir.appendingPathComponent(
            "merge-\(transaction.id.uuidString).json"
        )
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: logPath)
        logger.info("Transaction log written to \(logPath.path)")
    }

    private func writeJournalEntry(
        _ entry: String,
        txId: UUID,
        to path: URL
    ) throws {
        let line = "\(ISO8601DateFormatter().string(from: Date()))"
            + " \(entry)\n"
        if FileManager.default.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try handle.close()
        } else {
            try Data(line.utf8).write(to: path)
        }
    }

    private func cleanEmptyDirectories(at url: URL) {
        var current = url
        let fm = FileManager.default
        while current.path != "/" {
            let contents = (try? fm.contentsOfDirectory(
                atPath: current.path
            )) ?? ["placeholder"]
            if contents.isEmpty {
                try? fm.removeItem(at: current)
                current = current.deletingLastPathComponent()
            } else {
                break
            }
        }
    }
}

// MARK: - AssetBundle

/// A primary media file and its companion files to be moved together.
public struct AssetBundle: Sendable, Equatable {
    public let primary: URL
    public let companions: [URL]

    public init(primary: URL, companions: [URL] = []) {
        self.primary = primary
        self.companions = companions
    }

    /// All files in this bundle.
    public var allFiles: [URL] {
        [primary] + companions
    }
}

// MARK: - MergeTransaction

public struct MergeTransaction: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let entries: [Entry]
    public let errors: [Error]
    public let mode: MergeMode
    public let status: TransactionStatus
    /// Session that triggered this merge. Optional for backward
    /// compatibility with transaction logs written before this field.
    public let sessionId: UUID?
    /// Group IDs affected by this transaction. Used to scope undo
    /// to exactly the groups merged in this operation (not "all
    /// merged decisions in the session").
    public let groupIds: [UUID]?

    public var filesMoved: Int { entries.count }
    public var errorCount: Int { errors.count }
    /// Move errors prevent decision transition to .merged.
    public var moveErrorCount: Int {
        errors.filter { $0.operation == .move }.count
    }
    /// Rename errors are non-fatal for decision transitions.
    public var renameErrorCount: Int {
        errors.filter { $0.operation == .rename }.count
    }

    public init(
        id: UUID,
        date: Date,
        entries: [Entry],
        errors: [Error],
        mode: MergeMode = .quarantine,
        status: TransactionStatus = .completed,
        sessionId: UUID? = nil,
        groupIds: [UUID]? = nil
    ) {
        self.id = id
        self.date = date
        self.entries = entries
        self.errors = errors
        self.mode = mode
        self.status = status
        self.sessionId = sessionId
        self.groupIds = groupIds
    }

    public struct Entry: Codable, Sendable {
        public let originalPath: String
        public let trashedPath: String?
        public let isCompanion: Bool
        public let status: EntryStatus
        /// Discriminates move-to-quarantine vs in-place rename.
        /// Defaults to `.move` for backward compatibility with
        /// transaction logs that predate rename support.
        public let operation: EntryOperation
        /// For `.rename` entries: the path before renaming.
        /// `originalPath` holds the post-rename path. `nil`
        /// for `.move` entries.
        public let renamedFrom: String?

        public init(
            originalPath: String,
            trashedPath: String?,
            isCompanion: Bool = false,
            status: EntryStatus = .completed,
            operation: EntryOperation = .move,
            renamedFrom: String? = nil
        ) {
            self.originalPath = originalPath
            self.trashedPath = trashedPath
            self.isCompanion = isCompanion
            self.status = status
            self.operation = operation
            self.renamedFrom = renamedFrom
        }

        // Backward-compatible decoding: old logs lack operation
        // and renamedFrom fields.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(
                keyedBy: CodingKeys.self
            )
            originalPath = try c.decode(
                String.self, forKey: .originalPath
            )
            trashedPath = try c.decodeIfPresent(
                String.self, forKey: .trashedPath
            )
            isCompanion = try c.decode(
                Bool.self, forKey: .isCompanion
            )
            status = try c.decode(
                EntryStatus.self, forKey: .status
            )
            operation = try c.decodeIfPresent(
                EntryOperation.self, forKey: .operation
            ) ?? .move
            renamedFrom = try c.decodeIfPresent(
                String.self, forKey: .renamedFrom
            )
        }
    }

    public struct Error: Codable, Sendable {
        public let originalPath: String
        public let reason: String
        /// Which operation produced this error. Defaults to
        /// `.move` for backward compatibility.
        public let operation: EntryOperation

        public init(
            originalPath: String,
            reason: String,
            operation: EntryOperation = .move
        ) {
            self.originalPath = originalPath
            self.reason = reason
            self.operation = operation
        }

        // Backward-compatible decoding
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(
                keyedBy: CodingKeys.self
            )
            originalPath = try c.decode(
                String.self, forKey: .originalPath
            )
            reason = try c.decode(
                String.self, forKey: .reason
            )
            operation = try c.decodeIfPresent(
                EntryOperation.self, forKey: .operation
            ) ?? .move
        }
    }

    public enum EntryStatus: String, Codable, Sendable {
        case planned
        case completed
    }
}

public enum MergeMode: String, Codable, Sendable {
    case quarantine
    case trash
}

/// Discriminates move-to-quarantine from in-place rename entries.
/// Has an `unknown` case for forward compatibility — entries with
/// unknown operations are skipped by undo and purge.
public enum EntryOperation: Sendable, Equatable {
    /// File moved to quarantine (or trash).
    case move
    /// File renamed in-place (keeper or companion).
    case rename
    /// Unknown operation from a newer version. Preserves the raw
    /// string for round-trip fidelity; skipped by undo/purge.
    case unknown(String)
}

extension EntryOperation: Codable {
    private static let knownValues: [String: EntryOperation] = [
        "move": .move,
        "rename": .rename,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer()
            .decode(String.self)
        self = Self.knownValues[raw] ?? .unknown(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .move: try container.encode("move")
        case .rename: try container.encode("rename")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

/// Request to rename a keeper (or companion) in-place after
/// quarantine moves complete.
public struct KeeperRenameRequest: Sendable {
    public let from: URL
    public let to: URL
    public let isCompanion: Bool
    public init(
        from: URL,
        to: URL,
        isCompanion: Bool = false
    ) {
        self.from = from
        self.to = to
        self.isCompanion = isCompanion
    }
}

public enum TransactionStatus: Sendable, Equatable {
    case planned
    case completed
    case failed
    case undone
    case purged
    /// Unknown status from a newer version. Preserves the raw
    /// string for round-trip fidelity; treated as completed for
    /// forward compatibility (undo-eligible, not silently lost).
    case unknown(String)
}

extension TransactionStatus: Codable {
    private static let knownValues: [String: TransactionStatus] = [
        "planned": .planned,
        "completed": .completed,
        "failed": .failed,
        "undone": .undone,
        "purged": .purged,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(
            String.self
        )
        self = Self.knownValues[raw] ?? .unknown(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .planned: try container.encode("planned")
        case .completed: try container.encode("completed")
        case .failed: try container.encode("failed")
        case .undone: try container.encode("undone")
        case .purged: try container.encode("purged")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

extension TransactionStatus {
    /// Status-only undo check. Not sufficient for full eligibility
    /// — use MergeViewModel.isUndoEligible() for UI gating which
    /// also checks groupIds, filesystem existence, etc.
    public var isStatusUndoEligible: Bool {
        switch self {
        case .completed, .unknown: true
        case .planned, .failed, .undone, .purged: false
        }
    }
}

// MARK: - MergeError

public enum MergeError: Swift.Error, LocalizedError, Sendable {
    case protectedPath(URL)
    case transactionNotFound(UUID)
    case undoFailed([String])
    case cannotPurgeUndone(UUID)
    /// Another merge/undo/purge is already in progress.
    case lockHeld(owner: String, pid: Int32, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .protectedPath(let url):
            return "Refusing to move protected path: \(url.path)"
        case .transactionNotFound(let id):
            return "Transaction not found: \(id)"
        case .undoFailed(let reasons):
            return "Undo failed for \(reasons.count) file(s)"
        case .cannotPurgeUndone(let id):
            return "Cannot purge undone transaction: \(id)"
        case .lockHeld(let owner, let pid, let seconds):
            return "A merge is already in progress"
                + " (\(owner), PID \(pid), \(seconds)s ago)."
                + " Wait for it to finish or force-quit the other process."
        }
    }
}
