import ArgumentParser
import Foundation
import DeduperKit
import SwiftData

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List past scan sessions."
    )

    @Option(name: .long, help: "Output format.")
    var format: OutputFormat = .table

    @Option(name: .long, help: "Maximum sessions to show.")
    var limit: Int = 20

    @MainActor
    func run() async throws {
        let container = try PersistenceFactory.makeContainer()
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<ScanSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let sessions = try context.fetch(descriptor)

        if sessions.isEmpty {
            print("No scan sessions found.")
            print("Run 'deduper scan <path>' to create one.")
            return
        }

        switch format {
        case .table:
            printTableOutput(sessions)
        case .json:
            printJSONOutput(sessions)
        case .ndjson:
            printNDJSONOutput(sessions)
        }
    }

    private func printTableOutput(_ sessions: [ScanSession]) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        print(
            String(
                format: "%-36s  %-16s  %6s  %6s  %6s  %s",
                "SESSION ID", "DATE", "FILES", "MEDIA", "DUPES", "DIRECTORY"
            )
        )
        print(String(repeating: "-", count: 100))

        for session in sessions {
            let date = dateFormatter.string(from: session.startedAt)
            print(
                String(
                    format: "%-36s  %-16s  %6d  %6d  %6d  %s",
                    session.sessionId.uuidString,
                    date,
                    session.totalFiles,
                    session.mediaFiles,
                    session.duplicateGroups,
                    abbreviatePath(session.directoryPath)
                )
            )
        }

        print()
        print(
            "Use 'deduper merge <session-id>' to act on a session."
        )
    }

    private func printJSONOutput(_ sessions: [ScanSession]) {
        struct JSONSession: Codable {
            let sessionId: String
            let directory: String
            let startedAt: String
            let completedAt: String?
            let totalFiles: Int
            let mediaFiles: Int
            let duplicateGroups: Int
        }

        let iso = ISO8601DateFormatter()
        let output = sessions.map {
            JSONSession(
                sessionId: $0.sessionId.uuidString,
                directory: $0.directoryPath,
                startedAt: iso.string(from: $0.startedAt),
                completedAt: $0.completedAt.map { iso.string(from: $0) },
                totalFiles: $0.totalFiles,
                mediaFiles: $0.mediaFiles,
                duplicateGroups: $0.duplicateGroups
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(output),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    private func printNDJSONOutput(_ sessions: [ScanSession]) {
        struct NDJSONSession: Codable {
            let sessionId: String
            let directory: String
            let startedAt: String
            let completedAt: String?
            let totalFiles: Int
            let mediaFiles: Int
            let duplicateGroups: Int
        }

        let iso = ISO8601DateFormatter()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        for session in sessions {
            let line = NDJSONSession(
                sessionId: session.sessionId.uuidString,
                directory: session.directoryPath,
                startedAt: iso.string(from: session.startedAt),
                completedAt: session.completedAt.map { iso.string(from: $0) },
                totalFiles: session.totalFiles,
                mediaFiles: session.mediaFiles,
                duplicateGroups: session.duplicateGroups
            )
            if let data = try? encoder.encode(line),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
