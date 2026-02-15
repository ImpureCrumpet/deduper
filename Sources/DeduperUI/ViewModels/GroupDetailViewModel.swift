import Foundation
import AppKit
import SwiftData
import DeduperKit
import os

/// Detail about a single member in a duplicate group.
public struct MemberDetail: Identifiable, Sendable {
    public let id: String  // file path
    public let path: String
    public let fileName: String
    public let fileSize: Int64
    public let fileExists: Bool
    public let isKeeper: Bool
    public let metadata: MediaMetadata?
    public let companions: [String]
    /// PNG thumbnail bytes. Convert to NSImage in the view layer.
    public let thumbnailData: Data?
    // V2 signal data (nil for old artifacts)
    public let confidence: Double?
    public let signals: [ConfidenceSignal]
    public let penalties: [ConfidencePenalty]
    public let rationale: [String]
}

/// Drives the group detail view. Loads members from SwiftData, then
/// enriches each with metadata, companions, and thumbnails off-main.
@MainActor
@Observable
public final class GroupDetailViewModel {
    private static let logger = Logger(
        subsystem: "app.deduper.ui", category: "group-detail"
    )

    // Published state
    public var members: [MemberDetail] = []
    public var confidence: Double = 0
    public var matchBasis: String = ""
    public var matchKind: String = "perceptual"
    public var groupIndex: Int = 0
    public var groupRationale: [String] = []
    public var incomplete: Bool = false
    public var renameTemplate: RenameTemplate = RenameTemplate()
    public var showRename: Bool = false
    public var isLoading = false
    public var errorMessage: String?

    // Decision state
    public var currentDecision: DecisionState = .undecided
    public private(set) var currentGroupId: UUID?
    private var currentSessionId: UUID?

    /// Monotonic counter to prevent stale async writes after selection
    /// changes. Incremented on every loadGroup() and clear().
    private var selectionEpoch: UInt64 = 0

    /// Set by the parent view to propagate decision changes to list.
    /// The list VM's `commitDecision` handles auto-advance.
    public var onDecisionChanged:
        ((UUID, DecisionSnapshot) -> Void)?

    private let metadataService = MetadataService()
    private let companionResolver = CompanionResolver()
    private let thumbnailService = ThumbnailService()
    private var loadTask: Task<Void, Never>?

    /// Maximum concurrent enrichment tasks.
    private nonisolated static let maxConcurrency = 4

    public init() {}

    /// Load a group's full detail from SwiftData GroupMember rows.
    public func loadGroup(
        groupSummary: GroupSummary,
        container: ModelContainer,
        context: ModelContext? = nil
    ) {
        loadTask?.cancel()
        members = []
        isLoading = true
        errorMessage = nil
        confidence = groupSummary.confidence
        matchBasis = groupSummary.matchBasis
        matchKind = groupSummary.matchKind ?? "perceptual"
        groupIndex = groupSummary.groupIndex
        incomplete = groupSummary.incomplete ?? false
        if let data = groupSummary.rationaleJSON {
            groupRationale = (try? JSONDecoder().decode(
                [String].self, from: data
            )) ?? []
        } else {
            groupRationale = []
        }
        currentGroupId = groupSummary.groupId
        currentSessionId = groupSummary.sessionId
        selectionEpoch &+= 1

        // Load current decision state
        if let ctx = context {
            loadDecisionState(
                groupId: groupSummary.groupId, context: ctx
            )
        } else {
            currentDecision = .undecided
        }

        let groupId = groupSummary.groupId
        let expectedEpoch = selectionEpoch

        loadTask = Task { @MainActor in
            do {
                // Fetch members from SwiftData on main actor
                let memberRows = try fetchMembers(
                    groupId: groupId, container: container
                )

                try Task.checkCancellation()
                guard expectedEpoch == selectionEpoch else { return }

                guard !memberRows.isEmpty else {
                    errorMessage = "No members found for group."
                    isLoading = false
                    return
                }

                // Enrich off-main with bounded concurrency
                let details = try await enrichMembers(memberRows)

                try Task.checkCancellation()
                guard expectedEpoch == selectionEpoch else { return }
                members = details
                isLoading = false

            } catch is CancellationError {
                // Normal cancellation, don't report
            } catch {
                Self.logger.error(
                    "Failed to load group detail: \(error)"
                )
                guard expectedEpoch == selectionEpoch else { return }
                errorMessage = "Failed to load group."
                isLoading = false
            }
        }
    }

    /// Clear detail state.
    public func clear() {
        loadTask?.cancel()
        selectionEpoch &+= 1
        members = []
        isLoading = false
        errorMessage = nil
        currentDecision = .undecided
        currentGroupId = nil
        currentSessionId = nil
    }

    // MARK: - Decision Actions

    /// Approve the group with the suggested keeper.
    public func approve(
        context: ModelContext,
        artifactIdentity: String? = nil
    ) {
        upsertDecision(
            state: .approved,
            keeperPath: nil,
            context: context,
            artifactIdentity: artifactIdentity
        )
    }

    /// Skip this group for later review.
    public func skip(
        context: ModelContext,
        artifactIdentity: String? = nil
    ) {
        upsertDecision(
            state: .skipped,
            keeperPath: nil,
            context: context,
            artifactIdentity: artifactIdentity
        )
    }

    /// Change the keeper to a different member.
    public func changeKeeper(
        to path: String,
        context: ModelContext,
        artifactIdentity: String? = nil
    ) {
        upsertDecision(
            state: .approved,
            keeperPath: path,
            context: context,
            artifactIdentity: artifactIdentity
        )
    }

    /// Save just the rename template on the existing decision.
    public func saveRenameTemplate(context: ModelContext) {
        guard let groupId = currentGroupId else { return }

        let gid = groupId
        let predicate = #Predicate<ReviewDecision> {
            $0.groupId == gid
        }
        var descriptor = FetchDescriptor<ReviewDecision>(
            predicate: predicate
        )
        descriptor.fetchLimit = 1

        guard let decision = try? context.fetch(descriptor).first
        else { return }

        if renameTemplate.mode != .keepOriginal {
            decision.renameTemplateJSON = try? JSONEncoder().encode(
                renameTemplate
            )
        } else {
            decision.renameTemplateJSON = nil
        }
        try? context.save()
    }

    /// Mark this group as not a duplicate.
    public func markNotDuplicate(
        context: ModelContext,
        artifactIdentity: String? = nil
    ) {
        upsertDecision(
            state: .notDuplicate,
            keeperPath: nil,
            context: context,
            artifactIdentity: artifactIdentity
        )
    }

    // MARK: - Private

    private func loadDecisionState(
        groupId: UUID,
        context: ModelContext
    ) {
        let gid = groupId
        let predicate = #Predicate<ReviewDecision> {
            $0.groupId == gid
        }
        var descriptor = FetchDescriptor<ReviewDecision>(
            predicate: predicate
        )
        descriptor.fetchLimit = 1

        if let decision = try? context.fetch(descriptor).first {
            currentDecision = decision.decisionState
            if let data = decision.renameTemplateJSON {
                renameTemplate = (try? JSONDecoder().decode(
                    RenameTemplate.self, from: data
                )) ?? RenameTemplate()
            } else {
                renameTemplate = RenameTemplate()
            }
        } else {
            currentDecision = .undecided
            renameTemplate = RenameTemplate()
        }
    }

    private func upsertDecision(
        state: DecisionState,
        keeperPath: String?,
        context: ModelContext,
        artifactIdentity: String?
    ) {
        guard let groupId = currentGroupId,
              let sessionId = currentSessionId
        else { return }

        // Cannot override .merged state from UI — undo first.
        if currentDecision == .merged { return }

        // Idempotency: don't re-save or re-advance if already in
        // the target state with no keeper change.
        if currentDecision == state && keeperPath == nil {
            return
        }

        let gid = groupId
        let predicate = #Predicate<ReviewDecision> {
            $0.groupId == gid
        }
        var descriptor = FetchDescriptor<ReviewDecision>(
            predicate: predicate
        )
        descriptor.fetchLimit = 1

        let decision: ReviewDecision
        if let existing = try? context.fetch(descriptor).first {
            decision = existing
        } else {
            decision = ReviewDecision(
                sessionId: sessionId,
                groupIndex: groupIndex,
                groupId: groupId
            )
            context.insert(decision)
        }

        decision.decisionState = state
        decision.decidedAt = Date()
        decision.artifactIdentity = artifactIdentity
        if renameTemplate.mode != .keepOriginal {
            decision.renameTemplateJSON = try? JSONEncoder().encode(
                renameTemplate
            )
        } else {
            decision.renameTemplateJSON = nil
        }

        // Keeper fields are only meaningful for approved decisions.
        if state != .approved {
            decision.selectedKeeperPath = nil
            decision.selectedKeeperFingerprint = nil
            decision.selectedKeeperFileSize = nil
        } else if let keeperPath {
            decision.selectedKeeperPath = keeperPath
            let url = URL(fileURLWithPath: keeperPath)
            decision.selectedKeeperFingerprint =
                ContentFingerprint.compute(for: url)
            if let attrs = try? FileManager.default
                .attributesOfItem(atPath: keeperPath),
               let size = attrs[.size] as? Int64 {
                decision.selectedKeeperFileSize = size
            }
        }

        do {
            try context.save()
            currentDecision = state
            onDecisionChanged?(
                groupId,
                DecisionSnapshot(
                    state: state, decidedAt: decision.decidedAt
                )
            )
        } catch {
            Self.logger.error(
                "Failed to save decision: \(error)"
            )
        }
    }

    /// Sendable snapshot of a GroupMember row for off-main enrichment.
    private struct MemberSnapshot: Sendable {
        let filePath: String
        let fileName: String
        let fileSize: Int64
        let isKeeper: Bool
        let memberIndex: Int
        let confidence: Double?
        let signals: [ConfidenceSignal]
        let penalties: [ConfidencePenalty]
        let rationale: [String]
    }

    private func fetchMembers(
        groupId: UUID,
        container: ModelContainer
    ) throws -> [MemberSnapshot] {
        let context = ModelContext(container)
        let predicate = #Predicate<GroupMember> {
            $0.groupId == groupId
        }
        let descriptor = FetchDescriptor<GroupMember>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.memberIndex)]
        )

        let rows = try context.fetch(descriptor)
        let decoder = JSONDecoder()
        return rows.map { row in
            let signals: [ConfidenceSignal] = row.signalsJSON
                .flatMap { try? decoder.decode(
                    [ConfidenceSignal].self, from: $0
                ) } ?? []
            let penalties: [ConfidencePenalty] = row.penaltiesJSON
                .flatMap { try? decoder.decode(
                    [ConfidencePenalty].self, from: $0
                ) } ?? []
            let rationale: [String] = row.rationaleJSON
                .flatMap { try? decoder.decode(
                    [String].self, from: $0
                ) } ?? []
            return MemberSnapshot(
                filePath: row.filePath,
                fileName: row.fileName,
                fileSize: row.fileSize,
                isKeeper: row.isKeeper,
                memberIndex: row.memberIndex,
                confidence: row.confidence,
                signals: signals,
                penalties: penalties,
                rationale: rationale
            )
        }
    }

    /// Enrich members with metadata, companions, and thumbnails
    /// using bounded concurrent task group.
    private nonisolated func enrichMembers(
        _ snapshots: [MemberSnapshot]
    ) async throws -> [MemberDetail] {
        try await withThrowingTaskGroup(
            of: (Int, MemberDetail).self
        ) { group in
            var results: [(Int, MemberDetail)] = []
            results.reserveCapacity(snapshots.count)

            var iterator = snapshots.enumerated().makeIterator()

            // Seed initial batch
            let initialBatch = min(
                snapshots.count, Self.maxConcurrency
            )
            for _ in 0..<initialBatch {
                guard let (idx, snap) = iterator.next() else {
                    break
                }
                group.addTask {
                    try Task.checkCancellation()
                    let detail = await self.enrichOne(snap)
                    return (idx, detail)
                }
            }

            // As each completes, launch next
            for try await result in group {
                results.append(result)
                if let (idx, snap) = iterator.next() {
                    group.addTask {
                        try Task.checkCancellation()
                        let detail = await self.enrichOne(snap)
                        return (idx, detail)
                    }
                }
            }

            // Sort by original index
            results.sort { $0.0 < $1.0 }
            return results.map(\.1)
        }
    }

    /// Enrich a single member with metadata, companions, and thumbnail.
    private nonisolated func enrichOne(
        _ snap: MemberSnapshot
    ) async -> MemberDetail {
        let url = URL(fileURLWithPath: snap.filePath)
        let exists = FileManager.default.fileExists(
            atPath: snap.filePath
        )

        // Metadata
        let metadata: MediaMetadata? = exists
            ? await metadataService.extractMetadata(from: url)
            : nil

        // Companions
        let companions: [String]
        if exists {
            let companionSet = companionResolver.resolve(for: url)
            companions = companionSet.companionURLs.map(\.path)
        } else {
            companions = []
        }

        // Thumbnail as PNG Data (not NSImage — honest Sendability)
        var thumbnailData: Data?
        if exists {
            let image = await thumbnailService.thumbnail(
                for: snap.filePath, size: .detail
            )
            if let image {
                thumbnailData = pngData(from: image)
            }
        }

        return MemberDetail(
            id: snap.filePath,
            path: snap.filePath,
            fileName: snap.fileName,
            fileSize: snap.fileSize,
            fileExists: exists,
            isKeeper: snap.isKeeper,
            metadata: metadata,
            companions: companions,
            thumbnailData: thumbnailData,
            confidence: snap.confidence,
            signals: snap.signals,
            penalties: snap.penalties,
            rationale: snap.rationale
        )
    }

    /// Convert NSImage to PNG Data for Sendable transport.
    private nonisolated func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
