import Foundation
import SwiftUI
import SwiftData

/// Decision states for a duplicate group review.
public enum DecisionState: Int16, Sendable, CaseIterable {
    case undecided = 0
    case approved = 1
    case skipped = 2
    case needsReview = 3
    case blocked = 4
    case notDuplicate = 5
    case merged = 6

    public var displayName: String {
        switch self {
        case .undecided: "Pending"
        case .approved: "Approved"
        case .skipped: "Skipped"
        case .needsReview: "Needs Review"
        case .blocked: "Blocked"
        case .notDuplicate: "Not Duplicate"
        case .merged: "Merged"
        }
    }

    public var systemImage: String {
        switch self {
        case .undecided: "circle"
        case .approved: "checkmark.circle.fill"
        case .skipped: "forward.fill"
        case .needsReview: "questionmark.circle"
        case .blocked: "exclamationmark.triangle"
        case .notDuplicate: "xmark.circle"
        case .merged: "archivebox.circle.fill"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .undecided: .secondary
        case .approved: .green
        case .skipped: .orange
        case .needsReview: .yellow
        case .blocked: .red
        case .notDuplicate: .red
        case .merged: .purple
        }
    }
}

/// Mutable user-authored review state for a duplicate group.
/// Defined in Slice 1 for schema stability; fully utilized in Slice 2.
@Model
public final class ReviewDecision {
    // Identity (compound key: sessionId + groupIndex)
    public var sessionId: UUID
    public var groupIndex: Int
    @Attribute(.unique)
    public var groupId: UUID

    // User decisions
    /// Overridden keeper path. nil = accept suggestion.
    public var selectedKeeperPath: String?
    /// ContentFingerprint of the chosen keeper at decision time.
    /// Allows Slice 3 to validate the keeper still matches before merging.
    public var selectedKeeperFingerprint: String?
    /// File size of the chosen keeper at decision time.
    public var selectedKeeperFileSize: Int64?
    /// DecisionState.rawValue
    public var decisionStateRaw: Int16

    // Metadata salvage (Slice 4)
    public var salvagePlanJSON: Data?

    /// JSON-encoded RenameTemplate for keeper rename at merge time.
    public var renameTemplateJSON: Data?

    /// Artifact identity at decision time: "{artifactFileName}:{mtime}".
    /// If artifact identity changes (re-scan), decisions can be flagged stale.
    /// Set by Slice 2 when decision is created.
    public var artifactIdentity: String?

    // Audit
    public var notes: String?
    public var decidedAt: Date?
    public var createdAt: Date

    public var decisionState: DecisionState {
        get { DecisionState(rawValue: decisionStateRaw) ?? .undecided }
        set { decisionStateRaw = newValue.rawValue }
    }

    public init(
        sessionId: UUID,
        groupIndex: Int,
        groupId: UUID,
        decisionState: DecisionState = .undecided
    ) {
        self.sessionId = sessionId
        self.groupIndex = groupIndex
        self.groupId = groupId
        self.selectedKeeperPath = nil
        self.selectedKeeperFingerprint = nil
        self.selectedKeeperFileSize = nil
        self.decisionStateRaw = decisionState.rawValue
        self.salvagePlanJSON = nil
        self.renameTemplateJSON = nil
        self.artifactIdentity = nil
        self.notes = nil
        self.decidedAt = nil
        self.createdAt = Date()
    }
}

// MARK: - Stored Form (AD-003)

/// Import conflict policy for `ReviewDecision.importSession`.
public enum ReviewDecisionImportMode: Sendable {
    /// Skip decisions whose `groupId` already exists.
    case skipExisting
}

/// Codable, Sendable export form of a ReviewDecision.
/// Independent of SwiftData — suitable for JSON files, auditing,
/// and cross-database import.
public struct StoredReviewDecision: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionId: UUID
    public let groupIndex: Int
    public let groupId: UUID
    public let decisionState: Int16
    public let selectedKeeperPath: String?
    public let selectedKeeperFingerprint: String?
    public let selectedKeeperFileSize: Int64?
    public let salvagePlanJSON: Data?
    public let renameTemplateJSON: Data?
    public let artifactIdentity: String?
    public let notes: String?
    public let decidedAt: Date?
    public let createdAt: Date

    public init(
        schemaVersion: Int = 1,
        sessionId: UUID,
        groupIndex: Int,
        groupId: UUID,
        decisionState: Int16,
        selectedKeeperPath: String? = nil,
        selectedKeeperFingerprint: String? = nil,
        selectedKeeperFileSize: Int64? = nil,
        salvagePlanJSON: Data? = nil,
        renameTemplateJSON: Data? = nil,
        artifactIdentity: String? = nil,
        notes: String? = nil,
        decidedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.groupIndex = groupIndex
        self.groupId = groupId
        self.decisionState = decisionState
        self.selectedKeeperPath = selectedKeeperPath
        self.selectedKeeperFingerprint = selectedKeeperFingerprint
        self.selectedKeeperFileSize = selectedKeeperFileSize
        self.salvagePlanJSON = salvagePlanJSON
        self.renameTemplateJSON = renameTemplateJSON
        self.artifactIdentity = artifactIdentity
        self.notes = notes
        self.decidedAt = decidedAt
        self.createdAt = createdAt
    }
}

// MARK: - Conversion

extension ReviewDecision {
    /// Convert to exportable stored form.
    public func toStoredForm() -> StoredReviewDecision {
        StoredReviewDecision(
            sessionId: sessionId,
            groupIndex: groupIndex,
            groupId: groupId,
            decisionState: decisionStateRaw,
            selectedKeeperPath: selectedKeeperPath,
            selectedKeeperFingerprint: selectedKeeperFingerprint,
            selectedKeeperFileSize: selectedKeeperFileSize,
            salvagePlanJSON: salvagePlanJSON,
            renameTemplateJSON: renameTemplateJSON,
            artifactIdentity: artifactIdentity,
            notes: notes,
            decidedAt: decidedAt,
            createdAt: createdAt
        )
    }

    /// Import from stored form. Inserts into the given context.
    /// Returns nil if a decision with the same groupId already exists.
    @MainActor
    public static func from(
        _ stored: StoredReviewDecision,
        context: ModelContext
    ) throws -> ReviewDecision? {
        let gid = stored.groupId
        let pred = #Predicate<ReviewDecision> {
            $0.groupId == gid
        }
        var desc = FetchDescriptor<ReviewDecision>(predicate: pred)
        desc.fetchLimit = 1
        if !(try context.fetch(desc)).isEmpty { return nil }

        let decision = ReviewDecision(
            sessionId: stored.sessionId,
            groupIndex: stored.groupIndex,
            groupId: stored.groupId,
            decisionState: DecisionState(
                rawValue: stored.decisionState
            ) ?? .undecided
        )
        decision.selectedKeeperPath = stored.selectedKeeperPath
        decision.selectedKeeperFingerprint =
            stored.selectedKeeperFingerprint
        decision.selectedKeeperFileSize =
            stored.selectedKeeperFileSize
        decision.salvagePlanJSON = stored.salvagePlanJSON
        decision.renameTemplateJSON = stored.renameTemplateJSON
        decision.artifactIdentity = stored.artifactIdentity
        decision.notes = stored.notes
        decision.decidedAt = stored.decidedAt
        decision.createdAt = stored.createdAt
        context.insert(decision)
        return decision
    }
}

// MARK: - Batch Export/Import

extension ReviewDecision {
    /// Export all decisions for a session as JSON Data.
    /// Sorted by groupIndex then groupId for deterministic output.
    @MainActor
    public static func exportSession(
        sessionId: UUID,
        context: ModelContext
    ) throws -> Data {
        let sid = sessionId
        let pred = #Predicate<ReviewDecision> {
            $0.sessionId == sid
        }
        let decisions = try context.fetch(
            FetchDescriptor<ReviewDecision>(predicate: pred)
        )
        let stored = decisions
            .map { $0.toStoredForm() }
            .sorted {
                if $0.groupIndex != $1.groupIndex {
                    return $0.groupIndex < $1.groupIndex
                }
                return $0.groupId.uuidString < $1.groupId.uuidString
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(stored)
    }

    /// Import decisions from JSON Data. Returns count of imported
    /// decisions. Skips conflicts per the given mode.
    @MainActor
    public static func importSession(
        from data: Data,
        context: ModelContext,
        mode: ReviewDecisionImportMode = .skipExisting
    ) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(
            [StoredReviewDecision].self, from: data
        )
        var imported = 0
        for item in stored {
            switch mode {
            case .skipExisting:
                if let _ = try from(item, context: context) {
                    imported += 1
                }
            }
        }
        try context.save()
        return imported
    }
}
