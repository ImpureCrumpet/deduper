import Foundation
import os

/// Handles moving duplicate files to trash with transaction logging and undo.
public struct MergeService: Sendable {
    private let logger = Logger(subsystem: "app.deduper", category: "merge")

    public init() {}

    /// Move files to trash, logging transactions for undo.
    /// Returns the transaction log path.
    public func moveToTrash(
        files: [URL],
        logDirectory: URL? = nil
    ) throws -> MergeTransaction {
        let logDir = logDirectory ?? defaultLogDirectory()
        try FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true
        )

        var entries: [MergeTransaction.Entry] = []
        var errors: [MergeTransaction.Error] = []

        for url in files {
            // Protected path check
            if isProtectedPath(url) {
                errors.append(.init(
                    originalPath: url.path,
                    reason: "Protected path -- refusing to move"
                ))
                logger.warning("Skipped protected path: \(url.path)")
                continue
            }

            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(
                    at: url,
                    resultingItemURL: &trashedURL
                )
                entries.append(.init(
                    originalPath: url.path,
                    trashedPath: trashedURL?.path
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
            id: UUID(),
            date: Date(),
            entries: entries,
            errors: errors
        )

        // Write transaction log
        let logPath = logDir.appendingPathComponent(
            "merge-\(transaction.id.uuidString).json"
        )
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: logPath)
        logger.info("Transaction log written to \(logPath.path)")

        return transaction
    }

    /// Undo a merge by restoring files from trash.
    /// Note: This is best-effort -- trash items may have been emptied.
    public func undo(transaction: MergeTransaction) -> [String] {
        var failures: [String] = []

        for entry in transaction.entries {
            guard let trashedPath = entry.trashedPath else {
                failures.append(
                    "No trash path recorded for \(entry.originalPath)"
                )
                continue
            }

            let trashedURL = URL(fileURLWithPath: trashedPath)
            let originalURL = URL(fileURLWithPath: entry.originalPath)

            do {
                try FileManager.default.moveItem(
                    at: trashedURL,
                    to: originalURL
                )
                logger.info("Restored: \(originalURL.lastPathComponent)")
            } catch {
                failures.append(
                    "\(entry.originalPath): \(error.localizedDescription)"
                )
            }
        }

        return failures
    }

    /// List transaction logs from the log directory.
    public func listTransactions(
        logDirectory: URL? = nil
    ) throws -> [MergeTransaction] {
        let logDir = logDirectory ?? defaultLogDirectory()
        guard FileManager.default.fileExists(atPath: logDir.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: nil
        )

        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> MergeTransaction? in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return try? JSONDecoder().decode(
                    MergeTransaction.self,
                    from: data
                )
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Protected Paths

    private func isProtectedPath(_ url: URL) -> Bool {
        let path = url.path
        let protectedPrefixes = [
            "/System",
            "/Library",
            "/usr",
            "/bin",
            "/sbin",
            "/Applications",
            "/private/var"
        ]
        return protectedPrefixes.contains { path.hasPrefix($0) }
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
}

// MARK: - MergeTransaction

public struct MergeTransaction: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let entries: [Entry]
    public let errors: [Error]

    public var filesMoved: Int { entries.count }
    public var errorCount: Int { errors.count }

    public struct Entry: Codable, Sendable {
        public let originalPath: String
        public let trashedPath: String?
    }

    public struct Error: Codable, Sendable {
        public let originalPath: String
        public let reason: String
    }
}

// MARK: - MergeError

public enum MergeError: Swift.Error, LocalizedError, Sendable {
    case protectedPath(URL)
    case transactionNotFound(UUID)
    case undoFailed([String])

    public var errorDescription: String? {
        switch self {
        case .protectedPath(let url):
            return "Refusing to move protected path: \(url.path)"
        case .transactionNotFound(let id):
            return "Transaction not found: \(id)"
        case .undoFailed(let reasons):
            return "Undo failed for \(reasons.count) file(s)"
        }
    }
}
