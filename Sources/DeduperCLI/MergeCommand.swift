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

    @Flag(
        name: .long,
        help: "Actually execute the merge (default is dry-run)."
    )
    var apply = false

    @Flag(
        name: .long,
        help: "Preview what would be moved (default behavior)."
    )
    var dryRun = false

    @Flag(
        name: .long,
        help: "Use OS Trash instead of quarantine directory."
    )
    var useTrash = false

    @Option(
        name: .long,
        help: "Only merge these group numbers (comma-separated)."
    )
    var groups: String?

    @Option(
        name: .long,
        help: "Skip these group numbers (comma-separated)."
    )
    var skip: String?

    @Option(
        name: .long,
        help: "Only merge groups above this confidence (0.0-1.0)."
    )
    var minConfidence: Double?

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "Override keeper (GROUP:/path/to/keeper)."
    )
    var keeper: [String] = []

    @MainActor
    func run() async throws {
        // Validate --apply and --dry-run are not both set
        if apply && dryRun {
            throw ValidationError(
                "--apply and --dry-run cannot be used together."
            )
        }

        // Default to dry-run unless --apply is passed
        let isDryRun = !apply

        guard let uuid = UUID(uuidString: sessionId) else {
            throw ValidationError(
                "Invalid session ID: \(sessionId)"
            )
        }

        let container = try PersistenceFactory.makeContainer()
        let context = ModelContext(container)

        let predicate = #Predicate<ScanSession> {
            $0.sessionId == uuid
        }
        var descriptor = FetchDescriptor<ScanSession>(
            predicate: predicate
        )
        descriptor.fetchLimit = 1
        let sessions = try context.fetch(descriptor)

        guard let session = sessions.first else {
            throw ValidationError(
                "Session not found: \(sessionId)\n"
                + "Run 'deduper history' to see available sessions."
            )
        }

        // Load groups from artifact or legacy JSON
        var allGroups = try session.loadGroups()

        guard !allGroups.isEmpty else {
            throw ValidationError("Session has no stored results.")
        }

        // Parse keeper overrides
        let keeperOverrides = try parseKeeperOverrides()
        for (groupIdx, keeperPath) in keeperOverrides {
            if let i = allGroups.firstIndex(where: {
                $0.groupIndex == groupIdx
            }) {
                allGroups[i].keeperPath = keeperPath
            } else {
                throw ValidationError(
                    "Keeper override references group \(groupIdx) "
                    + "which does not exist."
                )
            }
        }

        // Filter groups
        let selectedGroups = try filterGroups(allGroups)

        if selectedGroups.isEmpty {
            print("No groups match the specified filters.")
            return
        }

        // Resolve companions for all files
        let companionResolver = CompanionResolver()
        var assets: [AssetBundle] = []

        for group in selectedGroups {
            for path in group.memberPaths {
                if path != group.keeperPath {
                    let url = URL(fileURLWithPath: path)
                    let companionSet = companionResolver.resolve(
                        for: url
                    )
                    assets.append(AssetBundle(
                        primary: url,
                        companions: companionSet.companionURLs
                    ))
                }
            }
        }

        if assets.isEmpty {
            print("No files to remove.")
            return
        }

        let totalFiles = assets.reduce(0) {
            $0 + $1.allFiles.count
        }
        let companionCount = assets.reduce(0) {
            $0 + $1.companions.count
        }

        print("Session: \(session.directoryPath)")
        print("Groups: \(selectedGroups.count) of \(allGroups.count)")
        print(
            "Files to move: \(totalFiles)"
            + " (\(companionCount) companions)"
        )
        print()

        // Show what will be trashed
        for group in selectedGroups {
            let confidence = String(
                format: "%.0f%%", group.confidence * 100
            )
            let idx = group.groupIndex > 0
                ? group.groupIndex : 0
            print("Group \(idx) (\(confidence)):")
            for path in group.memberPaths {
                let isKeeper = path == group.keeperPath
                let label = isKeeper ? " [KEEP]" : " [TRASH]"
                print("  \(path)\(label)")
                if !isKeeper {
                    let url = URL(fileURLWithPath: path)
                    let companions = companionResolver.resolve(
                        for: url
                    )
                    for comp in companions.companions {
                        print(
                            "    + \(comp.url.lastPathComponent)"
                            + " [COMPANION]"
                        )
                    }
                }
            }
            print()
        }

        if isDryRun {
            print("[DRY RUN] No files were moved.")
            print("Pass --apply to execute the merge.")
            return
        }

        let merger = MergeService()

        if useTrash {
            let fileURLs = assets.flatMap(\.allFiles)
            let transaction = try merger.moveToTrash(
                files: fileURLs
            )
            printResult(transaction)
        } else {
            let transaction = try merger.moveToQuarantine(
                assets: assets
            )
            printResult(transaction)
        }
    }

    private func printResult(_ transaction: MergeTransaction) {
        print("\nMoved \(transaction.filesMoved) file(s).")
        if transaction.errorCount > 0 {
            print("\(transaction.errorCount) error(s):")
            for error in transaction.errors {
                print("  \(error.originalPath): \(error.reason)")
            }
        }
        print("Transaction: \(transaction.id.uuidString)")
        print(
            "Run 'deduper undo \(transaction.id.uuidString)'"
            + " to restore."
        )
    }

    // MARK: - Filtering

    private func filterGroups(
        _ allGroups: [StoredDuplicateGroup]
    ) throws -> [StoredDuplicateGroup] {
        var result = allGroups

        if let groupsStr = groups {
            let indices = try parseIntList(
                groupsStr, flag: "--groups"
            )
            let indexSet = Set(indices)
            result = result.filter {
                indexSet.contains($0.groupIndex)
            }
        }

        if let skipStr = skip {
            let indices = try parseIntList(
                skipStr, flag: "--skip"
            )
            let indexSet = Set(indices)
            result = result.filter {
                !indexSet.contains($0.groupIndex)
            }
        }

        if let minConf = minConfidence {
            guard minConf >= 0.0, minConf <= 1.0 else {
                throw ValidationError(
                    "--min-confidence must be between 0.0 and 1.0"
                )
            }
            result = result.filter { $0.confidence >= minConf }
        }

        return result
    }

    private func parseIntList(
        _ str: String,
        flag: String
    ) throws -> [Int] {
        let parts = str.split(separator: ",")
        return try parts.map { part in
            guard let n = Int(
                part.trimmingCharacters(in: .whitespaces)
            ), n > 0 else {
                throw ValidationError(
                    "Invalid group number in \(flag): '\(part)'. "
                    + "Expected positive integers."
                )
            }
            return n
        }
    }

    private func parseKeeperOverrides() throws -> [(Int, String)] {
        try keeper.map { spec in
            guard let colonIdx = spec.firstIndex(of: ":") else {
                throw ValidationError(
                    "Invalid --keeper format: '\(spec)'. "
                    + "Expected GROUP:/path/to/file"
                )
            }
            let groupStr = String(
                spec[spec.startIndex..<colonIdx]
            )
            let path = String(
                spec[spec.index(after: colonIdx)...]
            )
            guard let groupNum = Int(groupStr),
                  groupNum > 0 else {
                throw ValidationError(
                    "Invalid group in --keeper: '\(groupStr)'"
                )
            }
            guard FileManager.default.fileExists(
                atPath: path
            ) else {
                throw ValidationError(
                    "Keeper file not found: \(path)"
                )
            }
            return (groupNum, path)
        }
    }
}
