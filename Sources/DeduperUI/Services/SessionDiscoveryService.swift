import Foundation
import SwiftData
import DeduperKit
import os

/// Discovers CLI-created sessions by reading manifest files from the
/// shared artifact directory. Syncs found sessions into the app's
/// SessionIndex SwiftData table.
public struct SessionDiscoveryService: Sendable {
    private static let logger = Logger(
        subsystem: "app.deduper.ui", category: "discovery"
    )

    public init() {}

    /// Read all manifest files from the sessions directory.
    public func discoverManifests() -> [SessionManifest] {
        let dir = SessionManifest.sessionsDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return []
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            )
        } catch {
            Self.logger.error(
                "Failed to enumerate sessions dir: \(error)"
            )
            return []
        }

        return contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".manifest.json") }
            .compactMap { url in
                do {
                    return try SessionManifest.read(from: url)
                } catch {
                    Self.logger.warning(
                        "Failed to read manifest \(url.lastPathComponent): \(error)"
                    )
                    return nil
                }
            }
    }

    /// Sync discovered manifests into the SessionIndex table.
    /// Inserts new sessions, removes orphans (manifests that no longer exist).
    @MainActor
    public func syncIndex(context: ModelContext) {
        let manifests = discoverManifests()
        let manifestIds = Set(manifests.map(\.sessionId))

        // Fetch existing index entries
        let descriptor = FetchDescriptor<SessionIndex>()
        let existing: [SessionIndex]
        do {
            existing = try context.fetch(descriptor)
        } catch {
            Self.logger.error("Failed to fetch session index: \(error)")
            return
        }

        let existingIds = Set(existing.map(\.sessionId))

        // Insert new sessions
        for manifest in manifests where !existingIds.contains(manifest.sessionId) {
            let sessionsDir = SessionManifest.sessionsDirectory()
            let artifactPath = sessionsDir
                .appendingPathComponent(manifest.artifactFileName)
            let manifestPath = SessionManifest.manifestPath(
                for: manifest.sessionId
            )

            // Only insert if the artifact file exists
            guard FileManager.default.fileExists(
                atPath: artifactPath.path
            ) else {
                Self.logger.warning(
                    "Artifact missing for session \(manifest.sessionId)"
                )
                continue
            }

            let entry = SessionIndex(
                sessionId: manifest.sessionId,
                directoryPath: manifest.directoryPath,
                startedAt: manifest.startedAt,
                completedAt: manifest.completedAt,
                totalFiles: manifest.totalFiles,
                mediaFiles: manifest.mediaFiles,
                duplicateGroups: manifest.duplicateGroups,
                artifactPath: artifactPath.path,
                manifestPath: manifestPath.path
            )
            context.insert(entry)
        }

        // Remove orphans (index entries whose manifests no longer exist)
        for entry in existing where !manifestIds.contains(entry.sessionId) {
            context.delete(entry)
        }

        do {
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to save session index: \(error)"
            )
        }
    }
}
