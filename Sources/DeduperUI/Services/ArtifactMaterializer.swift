import Foundation
import SwiftData
import DeduperKit
import os

/// Materializes NDJSON session artifacts into GroupSummary + GroupMember
/// SwiftData rows for fast list rendering. Uses double-buffer strategy:
/// old rows stay visible during rebuild, swapped atomically via run ID.
public struct ArtifactMaterializer: Sendable {
    private static let logger = Logger(
        subsystem: "app.deduper.ui", category: "materializer"
    )

    /// Batch size for SwiftData inserts.
    private static let batchSize = 500

    public init() {}

    /// Check a session's materialization freshness.
    @MainActor
    public static func materializationState(
        session: SessionIndex
    ) -> SessionIndex.MaterializationState {
        let url = URL(fileURLWithPath: session.artifactPath)
        let mtime = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )[.modificationDate] as? Date
        return session.materializationState(artifactMtime: mtime)
    }

    /// Sendable snapshot of session fields needed for materialization.
    public struct SessionSnapshot: Sendable {
        public let sessionId: UUID
        public let artifactPath: String

        public init(sessionId: UUID, artifactPath: String) {
            self.sessionId = sessionId
            self.artifactPath = artifactPath
        }

        /// Create from a SessionIndex on the main actor.
        @MainActor
        public init(session: SessionIndex) {
            self.sessionId = session.sessionId
            self.artifactPath = session.artifactPath
        }
    }

    /// Materialize all groups from a session's artifact into GroupSummary
    /// and GroupMember rows using double-buffer strategy.
    /// Returns the count of materialized groups.
    public func materialize(
        session snapshot: SessionSnapshot,
        container: ModelContainer,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let artifactPath = snapshot.artifactPath
        let sessionId = snapshot.sessionId

        // Read all groups from the artifact (off-main)
        let url = URL(fileURLWithPath: artifactPath)
        let storedGroups = try SessionArtifact.readGroups(from: url)
        let total = storedGroups.count

        if total == 0 { return 0 }

        // Get artifact mtime for freshness tracking
        let attrs = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let artifactMtime = attrs[.modificationDate] as? Date

        // Generate new run ID for double-buffer
        let newRunId = UUID()

        // Process in batches, inserting on @MainActor
        var count = 0
        var summaryBatch: [GroupSummaryData] = []
        var memberBatch: [GroupMemberData] = []

        for group in storedGroups {
            try Task.checkCancellation()

            let summaryData = makeGroupData(
                group: group, sessionId: sessionId,
                runId: newRunId
            )
            summaryBatch.append(summaryData)

            // Create member rows — use V2 data when available
            let encoder = JSONEncoder()
            if let v2Members = group.membersV2,
               !v2Members.isEmpty {
                for (idx, m) in v2Members.enumerated() {
                    let memberData = GroupMemberData(
                        sessionId: sessionId,
                        groupId: group.groupId,
                        groupIndex: group.groupIndex,
                        memberIndex: idx,
                        filePath: m.path,
                        fileName: URL(fileURLWithPath: m.path)
                            .lastPathComponent,
                        fileSize: m.fileSize,
                        isKeeper: m.isKeeper,
                        materializationRunId: newRunId,
                        confidence: m.confidence,
                        signalsJSON: try? encoder.encode(m.signals),
                        penaltiesJSON: try? encoder.encode(
                            m.penalties
                        ),
                        rationaleJSON: try? encoder.encode(
                            m.rationale
                        )
                    )
                    memberBatch.append(memberData)
                }
            } else {
                // V1 fallback: parallel arrays
                for (idx, path) in group.memberPaths.enumerated() {
                    let size = idx < group.memberSizes.count
                        ? group.memberSizes[idx] : 0
                    let memberData = GroupMemberData(
                        sessionId: sessionId,
                        groupId: group.groupId,
                        groupIndex: group.groupIndex,
                        memberIndex: idx,
                        filePath: path,
                        fileName: URL(fileURLWithPath: path)
                            .lastPathComponent,
                        fileSize: size,
                        isKeeper: group.keeperPath == path,
                        materializationRunId: newRunId,
                        confidence: nil,
                        signalsJSON: nil,
                        penaltiesJSON: nil,
                        rationaleJSON: nil
                    )
                    memberBatch.append(memberData)
                }
            }

            count += 1

            if summaryBatch.count >= Self.batchSize || count == total {
                let sBatch = summaryBatch
                let mBatch = memberBatch
                try await insertBatch(
                    summaries: sBatch, members: mBatch,
                    container: container
                )
                summaryBatch = []
                memberBatch = []
                progress?(count, total)
            }
        }

        // Atomic swap: set new run ID, update mtime, clean old rows
        try await finalize(
            sessionId: sessionId,
            newRunId: newRunId,
            artifactMtime: artifactMtime,
            groupCount: count,
            container: container
        )

        Self.logger.info(
            "Materialized \(count) groups for session \(sessionId)"
        )
        return count
    }

    /// Delete GroupSummary + GroupMember rows for a session
    /// (preserves ReviewDecision).
    @MainActor
    public static func dematerializeIndex(
        sessionId: UUID,
        in context: ModelContext
    ) throws {
        let summaryPred = #Predicate<GroupSummary> {
            $0.sessionId == sessionId
        }
        try context.delete(
            model: GroupSummary.self, where: summaryPred
        )

        let memberPred = #Predicate<GroupMember> {
            $0.sessionId == sessionId
        }
        try context.delete(
            model: GroupMember.self, where: memberPred
        )

        // Reset session materialization state
        let sessionPred = #Predicate<SessionIndex> {
            $0.sessionId == sessionId
        }
        var desc = FetchDescriptor<SessionIndex>(
            predicate: sessionPred
        )
        desc.fetchLimit = 1
        if let session = try context.fetch(desc).first {
            session.currentRunId = nil
            session.materializedGroupCount = 0
            session.artifactMtime = nil
        }

        try context.save()
    }

    /// Delete ReviewDecision rows for a session.
    @MainActor
    public static func deleteDecisions(
        sessionId: UUID,
        in context: ModelContext
    ) throws {
        let predicate = #Predicate<ReviewDecision> {
            $0.sessionId == sessionId
        }
        try context.delete(
            model: ReviewDecision.self, where: predicate
        )
        try context.save()
    }

    // MARK: - Private

    private struct GroupSummaryData: Sendable {
        let sessionId: UUID
        let groupIndex: Int
        let groupId: UUID
        let confidence: Double
        let mediaTypeRaw: Int16
        let memberCount: Int
        let suggestedKeeperPath: String?
        let totalSize: Int64
        let spaceSavings: Int64
        let isLargeGroup: Bool
        let isMixedFormat: Bool
        let matchBasis: String
        let matchKind: String
        let rationaleJSON: Data?
        let incomplete: Bool
        let materializationRunId: UUID
    }

    private struct GroupMemberData: Sendable {
        let sessionId: UUID
        let groupId: UUID
        let groupIndex: Int
        let memberIndex: Int
        let filePath: String
        let fileName: String
        let fileSize: Int64
        let isKeeper: Bool
        let materializationRunId: UUID
        let confidence: Double?
        let signalsJSON: Data?
        let penaltiesJSON: Data?
        let rationaleJSON: Data?
    }

    private func makeGroupData(
        group: StoredDuplicateGroup,
        sessionId: UUID,
        runId: UUID
    ) -> GroupSummaryData {
        let totalSize = group.memberSizes.reduce(0, +)
        let maxSize = group.memberSizes.max() ?? 0
        let spaceSavings = totalSize - maxSize

        let extensions = Set(group.memberPaths.map {
            URL(fileURLWithPath: $0).pathExtension.lowercased()
        })
        let flags = GroupSummary.computeRiskFlags(
            memberCount: group.memberPaths.count,
            extensions: extensions
        )

        let resolved = group.resolvedMatchKind
        let matchBasis: String
        switch resolved {
        case .sha256Exact: matchBasis = "checksum"
        case .perceptual: matchBasis = "perceptual"
        case .videoHeuristic: matchBasis = "perceptual"
        case .legacyUnknown: matchBasis = "unknown"
        }

        let rationaleJSON: Data?
        if let lines = group.rationaleLines, !lines.isEmpty {
            rationaleJSON = try? JSONEncoder().encode(lines)
        } else {
            rationaleJSON = nil
        }

        return GroupSummaryData(
            sessionId: sessionId,
            groupIndex: group.groupIndex,
            groupId: group.groupId,
            confidence: group.confidence,
            mediaTypeRaw: group.mediaType,
            memberCount: group.memberPaths.count,
            suggestedKeeperPath: group.keeperPath,
            totalSize: totalSize,
            spaceSavings: spaceSavings,
            isLargeGroup: flags.isLargeGroup,
            isMixedFormat: flags.isMixedFormat,
            matchBasis: matchBasis,
            matchKind: resolved.rawValue,
            rationaleJSON: rationaleJSON,
            incomplete: group.incomplete ?? false,
            materializationRunId: runId
        )
    }

    @MainActor
    private func insertBatch(
        summaries: [GroupSummaryData],
        members: [GroupMemberData],
        container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        for data in summaries {
            let summary = GroupSummary(
                sessionId: data.sessionId,
                groupIndex: data.groupIndex,
                groupId: data.groupId,
                confidence: data.confidence,
                mediaTypeRaw: data.mediaTypeRaw,
                memberCount: data.memberCount,
                suggestedKeeperPath: data.suggestedKeeperPath,
                totalSize: data.totalSize,
                spaceSavings: data.spaceSavings,
                isLargeGroup: data.isLargeGroup,
                isMixedFormat: data.isMixedFormat,
                matchBasis: data.matchBasis,
                matchKind: data.matchKind,
                rationaleJSON: data.rationaleJSON,
                incomplete: data.incomplete,
                materializationRunId: data.materializationRunId
            )
            context.insert(summary)
        }

        for data in members {
            let member = GroupMember(
                sessionId: data.sessionId,
                groupId: data.groupId,
                groupIndex: data.groupIndex,
                memberIndex: data.memberIndex,
                filePath: data.filePath,
                fileName: data.fileName,
                fileSize: data.fileSize,
                isKeeper: data.isKeeper,
                materializationRunId: data.materializationRunId,
                confidence: data.confidence,
                signalsJSON: data.signalsJSON,
                penaltiesJSON: data.penaltiesJSON,
                rationaleJSON: data.rationaleJSON
            )
            context.insert(member)
        }

        try context.save()
    }

    /// Atomic swap: update session to point to new run, delete old rows.
    @MainActor
    private func finalize(
        sessionId: UUID,
        newRunId: UUID,
        artifactMtime: Date?,
        groupCount: Int,
        container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // Update session index to point to new run
        let sessionPred = #Predicate<SessionIndex> {
            $0.sessionId == sessionId
        }
        var desc = FetchDescriptor<SessionIndex>(
            predicate: sessionPred
        )
        desc.fetchLimit = 1

        guard let session = try context.fetch(desc).first else {
            return
        }

        let oldRunId = session.currentRunId
        session.currentRunId = newRunId
        session.artifactMtime = artifactMtime
        session.materializedGroupCount = groupCount

        try context.save()

        // Delete old run's rows (if any)
        if let oldRunId {
            let oldSummaryPred = #Predicate<GroupSummary> {
                $0.sessionId == sessionId
                    && $0.materializationRunId == oldRunId
            }
            try context.delete(
                model: GroupSummary.self, where: oldSummaryPred
            )

            let oldMemberPred = #Predicate<GroupMember> {
                $0.sessionId == sessionId
                    && $0.materializationRunId == oldRunId
            }
            try context.delete(
                model: GroupMember.self, where: oldMemberPred
            )

            try context.save()
        }
    }
}
