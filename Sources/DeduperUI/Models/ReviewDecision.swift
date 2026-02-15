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
