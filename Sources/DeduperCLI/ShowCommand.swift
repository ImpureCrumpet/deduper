import ArgumentParser
import Foundation
import DeduperKit
import SwiftData

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show details of a scan session's duplicate groups."
    )

    @Argument(help: "Session ID from a previous scan.")
    var sessionId: String

    @Option(name: .long, help: "Show only this group number (1-based).")
    var group: Int?

    @Option(name: .long, help: "Output format.")
    var format: OutputFormat = .table

    @MainActor
    func run() async throws {
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

        // Use streaming read for single group lookup
        var groups: [StoredDuplicateGroup]
        if let groupNum = group {
            groups = try session.loadGroups { g in
                g.groupIndex == groupNum
            }
            if groups.isEmpty {
                throw ValidationError(
                    "Group \(groupNum) not found. "
                    + "This session has "
                    + "\(session.duplicateGroups) group(s)."
                )
            }
        } else {
            groups = try session.loadGroups()
        }

        switch format {
        case .table:
            printTableOutput(session: session, groups: groups)
        case .json:
            printJSONOutput(session: session, groups: groups)
        case .ndjson:
            printNDJSONOutput(session: session, groups: groups)
        }
    }

    private func printTableOutput(
        session: ScanSession,
        groups: [StoredDuplicateGroup]
    ) {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        print("Session: \(session.sessionId.uuidString)")
        print("Directory: \(session.directoryPath)")
        print("Scanned: \(df.string(from: session.startedAt))")
        print(
            "Files: \(session.totalFiles) total, "
            + "\(session.mediaFiles) media"
        )
        print("Groups: \(session.duplicateGroups)")
        print()

        if groups.isEmpty {
            print("No duplicate groups in this session.")
            return
        }

        for group in groups {
            let confidence = String(
                format: "%.0f%%", group.confidence * 100
            )
            let idx = group.groupIndex > 0
                ? group.groupIndex : 0
            print("Group \(idx) (\(confidence) confidence):")
            for (i, path) in group.memberPaths.enumerated() {
                let isKeeper = PathIdentity.canonical(path)
                    == group.keeperPath
                        .map(PathIdentity.canonical(_:))
                let label = isKeeper ? " [KEEP]" : ""
                let size: String
                if i < group.memberSizes.count {
                    size = formatBytes(group.memberSizes[i])
                } else {
                    size = "?"
                }
                print("  \(path) (\(size))\(label)")
            }
            print()
        }
    }

    private func printJSONOutput(
        session: ScanSession,
        groups: [StoredDuplicateGroup]
    ) {
        struct Output: Codable {
            let sessionId: String
            let directory: String
            let groups: [StoredDuplicateGroup]
        }

        let output = Output(
            sessionId: session.sessionId.uuidString,
            directory: session.directoryPath,
            groups: groups
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(output),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    private func printNDJSONOutput(
        session: ScanSession,
        groups: [StoredDuplicateGroup]
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        for group in groups {
            if let data = try? encoder.encode(group),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
