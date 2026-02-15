import Foundation
import SwiftData

/// Fast-queryable index row for a duplicate group within a session.
/// Materialized from NDJSON artifacts into SwiftData for sort/filter/scroll.
@Model
public final class GroupSummary {
    // Identity
    public var sessionId: UUID
    public var groupIndex: Int
    public var groupId: UUID

    // Detection results (immutable after materialization)
    public var confidence: Double
    public var mediaTypeRaw: Int16
    public var memberCount: Int
    public var suggestedKeeperPath: String?
    public var totalSize: Int64
    /// Bytes reclaimable: totalSize minus largest member.
    public var spaceSavings: Int64

    // Risk flags (computed during materialization from artifact data only)
    /// Group has more than 3 members.
    public var isLargeGroup: Bool
    /// Members have different file extensions.
    public var isMixedFormat: Bool
    /// "checksum" for exact SHA256 match, "perceptual" for hash-based.
    /// Deprecated: use matchKind instead.
    public var matchBasis: String
    /// MatchKind raw value from artifact (sha256Exact, perceptual, videoHeuristic).
    public var matchKind: String?

    /// JSON-encoded [String] group rationale lines from V2 artifacts.
    public var rationaleJSON: Data?
    /// Whether this group was detected as incomplete (bucket overflow).
    public var incomplete: Bool?

    /// Which materialization run produced this row (for double-buffer).
    public var materializationRunId: UUID

    /// When this row was materialized from the artifact.
    public var materializedAt: Date

    public init(
        sessionId: UUID,
        groupIndex: Int,
        groupId: UUID,
        confidence: Double,
        mediaTypeRaw: Int16,
        memberCount: Int,
        suggestedKeeperPath: String?,
        totalSize: Int64,
        spaceSavings: Int64,
        isLargeGroup: Bool = false,
        isMixedFormat: Bool = false,
        matchBasis: String = "perceptual",
        matchKind: String? = "perceptual",
        rationaleJSON: Data? = nil,
        incomplete: Bool? = false,
        materializationRunId: UUID = UUID()
    ) {
        self.sessionId = sessionId
        self.groupIndex = groupIndex
        self.groupId = groupId
        self.confidence = confidence
        self.mediaTypeRaw = mediaTypeRaw
        self.memberCount = memberCount
        self.suggestedKeeperPath = suggestedKeeperPath
        self.totalSize = totalSize
        self.spaceSavings = spaceSavings
        self.isLargeGroup = isLargeGroup
        self.isMixedFormat = isMixedFormat
        self.matchBasis = matchBasis
        self.matchKind = matchKind
        self.rationaleJSON = rationaleJSON
        self.incomplete = incomplete
        self.materializationRunId = materializationRunId
        self.materializedAt = Date()
    }

    /// Compute risk flags from artifact data. Testable static method.
    public static func computeRiskFlags(
        memberCount: Int,
        extensions: Set<String>
    ) -> (isLargeGroup: Bool, isMixedFormat: Bool) {
        (
            isLargeGroup: memberCount > 3,
            isMixedFormat: extensions.count > 1
        )
    }
}
