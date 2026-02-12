import ArgumentParser
import Foundation
import DeduperKit
import SwiftData

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan a directory for duplicate media files."
    )

    @Argument(help: "Path to the directory to scan.")
    var path: String

    @Option(name: .long, help: "Similarity threshold (0.0-1.0).")
    var threshold: Double = 0.85

    @Option(name: .long, help: "Output format.")
    var format: OutputFormat = .table

    @Flag(name: .long, help: "Show what would be found without writing results.")
    var dryRun = false

    /// Print to stderr when using machine-readable formats.
    private func status(_ message: String) {
        if format == .ndjson {
            FileHandle.standardError.write(
                Data((message + "\n").utf8)
            )
        } else {
            print(message)
        }
    }

    func run() async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("Directory not found: \(path)")
        }

        status("Scanning \(url.path)...")

        let scanner = ScanService()
        var files: [ScannedFile] = []
        var metrics: ScanMetrics?
        for try await event in scanner.scan(directory: url) {
            switch event {
            case .item(let file):
                files.append(file)
            case .finished(let m):
                metrics = m
            case .progress(let count):
                if count % 500 == 0 {
                    status("  \(count) files scanned...")
                }
            default:
                break
            }
        }

        status("Found \(files.count) media files.")

        guard !files.isEmpty else { return }

        status("Detecting duplicates...")
        let container = try PersistenceFactory.makeContainer()
        let hashCache = HashCacheService(container: container)
        let detector = DetectionService(hashCache: hashCache)
        let options = DetectOptions(
            thresholds: .init(confidenceDuplicate: threshold)
        )
        let groups = try await detector.detectDuplicates(
            in: files,
            options: options
        )

        // Build file ID -> URL map for output and persistence
        let fileMap = Dictionary(
            uniqueKeysWithValues: files.map { ($0.id, $0) }
        )
        let fileURLMap = Dictionary(
            uniqueKeysWithValues: files.map { ($0.id, $0.url) }
        )

        // Persist session unless dry-run
        var sessionId: UUID?
        if !dryRun {
            sessionId = try await persistSession(
                container: container,
                directory: url,
                files: files,
                groups: groups,
                metrics: metrics,
                fileURLMap: fileURLMap
            )
        }

        switch format {
        case .table:
            printTableOutput(groups, fileMap: fileMap, sessionId: sessionId)
        case .json:
            printJSONOutput(groups, fileURLMap: fileURLMap, sessionId: sessionId)
        case .ndjson:
            printNDJSONOutput(groups, fileURLMap: fileURLMap, sessionId: sessionId)
        }
    }

    @MainActor
    private func persistSession(
        container: ModelContainer,
        directory: URL,
        files: [ScannedFile],
        groups: [DuplicateGroupResult],
        metrics: ScanMetrics?,
        fileURLMap: [UUID: URL]
    ) throws -> UUID {
        let context = ModelContext(container)

        let session = ScanSession(
            directoryPath: directory.path,
            totalFiles: metrics?.totalFiles ?? files.count,
            mediaFiles: metrics?.mediaFiles ?? files.count,
            duplicateGroups: groups.count
        )
        session.completedAt = Date()

        // Serialize group results
        let storedGroups = groups.map {
            StoredDuplicateGroup(from: $0, fileMap: fileURLMap)
        }
        session.resultsJSON = try JSONEncoder().encode(storedGroups)

        context.insert(session)
        try context.save()

        return session.sessionId
    }

    private func printTableOutput(
        _ groups: [DuplicateGroupResult],
        fileMap: [UUID: ScannedFile],
        sessionId: UUID?
    ) {
        if groups.isEmpty {
            print("No duplicates found.")
            if let id = sessionId {
                print("Session: \(id.uuidString)")
            }
            return
        }

        print("\nFound \(groups.count) duplicate group(s):\n")

        for (index, group) in groups.enumerated() {
            let confidence = String(
                format: "%.0f%%", group.confidence * 100
            )
            print("Group \(index + 1) (\(confidence) confidence):")
            for member in group.members {
                let path = fileMap[member.fileId]?.url.path ?? "unknown"
                let keeper = member.fileId == group.keeperSuggestion
                    ? " [KEEP]" : ""
                print("  \(path)\(keeper)")
            }
            print()
        }

        if let id = sessionId {
            print("Session: \(id.uuidString)")
            print("Run 'deduper merge \(id.uuidString)' to remove duplicates.")
        }
    }

    private func printJSONOutput(
        _ groups: [DuplicateGroupResult],
        fileURLMap: [UUID: URL],
        sessionId: UUID?
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        struct JSONOutput: Codable {
            let sessionId: String?
            let groups: [JSONGroup]
        }
        struct JSONGroup: Codable {
            let groupId: String
            let confidence: Double
            let members: [String]
            let keeper: String?
        }

        let output = JSONOutput(
            sessionId: sessionId?.uuidString,
            groups: groups.map { group in
                JSONGroup(
                    groupId: group.groupId.uuidString,
                    confidence: group.confidence,
                    members: group.members.compactMap {
                        fileURLMap[$0.fileId]?.path
                    },
                    keeper: group.keeperSuggestion.flatMap {
                        fileURLMap[$0]?.path
                    }
                )
            }
        )

        if let data = try? encoder.encode(output),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    /// NDJSON: one JSON object per line. First line is session metadata,
    /// then one line per duplicate group.
    private func printNDJSONOutput(
        _ groups: [DuplicateGroupResult],
        fileURLMap: [UUID: URL],
        sessionId: UUID?
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        func jsonLine<T: Encodable>(_ value: T) {
            if let data = try? encoder.encode(value),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
        }

        struct SessionLine: Codable {
            let type: String
            let sessionId: String?
            let groupCount: Int
        }

        struct GroupLine: Codable {
            let type: String
            let groupId: String
            let confidence: Double
            let mediaType: String
            let members: [MemberLine]
            let keeper: String?
        }

        struct MemberLine: Codable {
            let path: String
            let confidence: Double
            let fileSize: Int64
            let signals: [SignalLine]
        }

        struct SignalLine: Codable {
            let key: String
            let score: Double
            let rationale: String
        }

        // Session header line
        jsonLine(SessionLine(
            type: "session",
            sessionId: sessionId?.uuidString,
            groupCount: groups.count
        ))

        // One line per group
        for group in groups {
            let members = group.members.map { member in
                MemberLine(
                    path: fileURLMap[member.fileId]?.path ?? "unknown",
                    confidence: member.confidence,
                    fileSize: member.fileSize,
                    signals: member.signals.map {
                        SignalLine(
                            key: $0.key,
                            score: $0.contribution,
                            rationale: $0.rationale
                        )
                    }
                )
            }
            jsonLine(GroupLine(
                type: "group",
                groupId: group.groupId.uuidString,
                confidence: group.confidence,
                mediaType: "\(group.mediaType)",
                members: members,
                keeper: group.keeperSuggestion.flatMap {
                    fileURLMap[$0]?.path
                }
            ))
        }
    }
}

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case table
    case json
    case ndjson
}
