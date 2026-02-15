import Foundation
import SwiftData

/// Normalized member row for a duplicate group.
/// Materialized alongside GroupSummary to avoid per-click artifact decompression.
@Model
public final class GroupMember {
    public var sessionId: UUID
    /// Primary join key to GroupSummary (stable identity).
    public var groupId: UUID
    /// Human display/sort position of the group.
    public var groupIndex: Int
    /// Position within group (0-based).
    public var memberIndex: Int
    public var filePath: String
    /// Derived once at materialization to avoid repeated path parsing.
    public var fileName: String
    public var fileSize: Int64
    public var isKeeper: Bool
    /// Which materialization run produced this row (for double-buffer).
    public var materializationRunId: UUID

    // V2 signal data (nil for old artifacts)
    public var confidence: Double?
    /// JSON-encoded [ConfidenceSignal]
    public var signalsJSON: Data?
    /// JSON-encoded [ConfidencePenalty]
    public var penaltiesJSON: Data?
    /// JSON-encoded [String]
    public var rationaleJSON: Data?

    public init(
        sessionId: UUID,
        groupId: UUID,
        groupIndex: Int,
        memberIndex: Int,
        filePath: String,
        fileName: String,
        fileSize: Int64,
        isKeeper: Bool,
        materializationRunId: UUID,
        confidence: Double? = nil,
        signalsJSON: Data? = nil,
        penaltiesJSON: Data? = nil,
        rationaleJSON: Data? = nil
    ) {
        self.sessionId = sessionId
        self.groupId = groupId
        self.groupIndex = groupIndex
        self.memberIndex = memberIndex
        self.filePath = filePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.isKeeper = isKeeper
        self.materializationRunId = materializationRunId
        self.confidence = confidence
        self.signalsJSON = signalsJSON
        self.penaltiesJSON = penaltiesJSON
        self.rationaleJSON = rationaleJSON
    }
}
