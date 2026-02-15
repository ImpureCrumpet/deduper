import Foundation
import SwiftData

/// Cached session metadata populated from manifest files.
/// Lives in the app-only SwiftData store — the CLI never sees this model.
@Model
public final class SessionIndex {
    /// Session UUID (matches CLI session and artifact filename).
    public var sessionId: UUID
    public var directoryPath: String
    public var startedAt: Date
    public var completedAt: Date?
    public var totalFiles: Int
    public var mediaFiles: Int
    public var duplicateGroups: Int

    /// Absolute path to the .ndjson.gz artifact file.
    public var artifactPath: String

    /// Absolute path to the .manifest.json file.
    public var manifestPath: String

    /// When this index entry was last synced from the manifest.
    public var indexedAt: Date

    /// File modification time of the artifact at last materialization.
    public var artifactMtime: Date?

    /// Number of GroupSummary rows written in the current run.
    public var materializedGroupCount: Int

    /// Which materialization run is live (UI queries filter on this).
    public var currentRunId: UUID?

    public init(
        sessionId: UUID,
        directoryPath: String,
        startedAt: Date,
        completedAt: Date? = nil,
        totalFiles: Int = 0,
        mediaFiles: Int = 0,
        duplicateGroups: Int = 0,
        artifactPath: String,
        manifestPath: String,
        indexedAt: Date = Date(),
        artifactMtime: Date? = nil,
        materializedGroupCount: Int = 0,
        currentRunId: UUID? = nil
    ) {
        self.sessionId = sessionId
        self.directoryPath = directoryPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.totalFiles = totalFiles
        self.mediaFiles = mediaFiles
        self.duplicateGroups = duplicateGroups
        self.artifactPath = artifactPath
        self.manifestPath = manifestPath
        self.indexedAt = indexedAt
        self.artifactMtime = artifactMtime
        self.materializedGroupCount = materializedGroupCount
        self.currentRunId = currentRunId
    }

    /// Materialization freshness state.
    public enum MaterializationState: Sendable {
        case notMaterialized
        case partial(have: Int, expected: Int)
        case stale(artifactChanged: Date)
        case current
    }

    /// Check materialization freshness against artifact file mtime.
    public func materializationState(
        artifactMtime currentMtime: Date?
    ) -> MaterializationState {
        guard currentRunId != nil else {
            return .notMaterialized
        }
        if let currentMtime, let lastMtime = artifactMtime,
           currentMtime > lastMtime {
            return .stale(artifactChanged: currentMtime)
        }
        if materializedGroupCount != duplicateGroups,
           duplicateGroups > 0 {
            return .partial(
                have: materializedGroupCount,
                expected: duplicateGroups
            )
        }
        return .current
    }
}
