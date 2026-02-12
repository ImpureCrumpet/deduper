import ArgumentParser
import Foundation
import DeduperKit
import SwiftData

struct Merge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute a merge plan to remove duplicates."
    )

    @Argument(help: "Session ID from a previous scan.")
    var sessionId: String

    @Flag(name: .long, help: "Preview what would be moved to trash.")
    var dryRun = false

    @MainActor
    func run() async throws {
        guard let uuid = UUID(uuidString: sessionId) else {
            throw ValidationError("Invalid session ID: \(sessionId)")
        }

        let container = try PersistenceFactory.makeContainer()
        let context = ModelContext(container)

        // Find session
        let predicate = #Predicate<ScanSession> {
            $0.sessionId == uuid
        }
        var descriptor = FetchDescriptor<ScanSession>(predicate: predicate)
        descriptor.fetchLimit = 1
        let sessions = try context.fetch(descriptor)

        guard let session = sessions.first else {
            throw ValidationError(
                "Session not found: \(sessionId)\n"
                + "Run 'deduper history' to see available sessions."
            )
        }

        guard let resultsData = session.resultsJSON else {
            throw ValidationError("Session has no stored results.")
        }

        let groups = try JSONDecoder().decode(
            [StoredDuplicateGroup].self,
            from: resultsData
        )

        if groups.isEmpty {
            print("No duplicate groups found in session.")
            return
        }

        // Determine files to trash: all non-keeper members
        var filesToTrash: [URL] = []
        for group in groups {
            for path in group.memberPaths {
                if path != group.keeperPath {
                    filesToTrash.append(URL(fileURLWithPath: path))
                }
            }
        }

        if filesToTrash.isEmpty {
            print("No files to remove.")
            return
        }

        print("Session: \(session.directoryPath)")
        print("Groups: \(groups.count)")
        print("Files to move to trash: \(filesToTrash.count)")
        print()

        // Show what will be trashed
        for (i, group) in groups.enumerated() {
            let confidence = String(
                format: "%.0f%%", group.confidence * 100
            )
            print("Group \(i + 1) (\(confidence)):")
            for path in group.memberPaths {
                let isKeeper = path == group.keeperPath
                let label = isKeeper ? " [KEEP]" : " [TRASH]"
                print("  \(path)\(label)")
            }
            print()
        }

        if dryRun {
            print("[DRY RUN] No files were moved.")
            return
        }

        // Confirm
        print("Proceed? (y/N) ", terminator: "")
        guard let answer = readLine(), answer.lowercased() == "y" else {
            print("Aborted.")
            return
        }

        let merger = MergeService()
        let transaction = try merger.moveToTrash(files: filesToTrash)

        print("\nMoved \(transaction.filesMoved) file(s) to trash.")
        if transaction.errorCount > 0 {
            print("\(transaction.errorCount) error(s):")
            for error in transaction.errors {
                print("  \(error.originalPath): \(error.reason)")
            }
        }
        print("Transaction: \(transaction.id.uuidString)")
        print(
            "To undo, restore files from Trash "
            + "or use the transaction log."
        )
    }
}
