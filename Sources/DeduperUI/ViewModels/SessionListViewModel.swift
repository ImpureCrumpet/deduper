import Foundation
import SwiftData
import DeduperKit
import os

/// Drives the session sidebar. Discovers CLI-created sessions from manifest
/// files and triggers materialization when a session is selected.
@MainActor
@Observable
public final class SessionListViewModel {
    private static let logger = Logger(
        subsystem: "app.deduper.ui", category: "session-list"
    )

    // Published state
    public var sessions: [SessionIndex] = []
    public var selectedSessionId: UUID?
    public var isLoading = false
    public var errorMessage: String?

    // Materialization progress (nil = not materializing)
    public var materializationProgress: Double?
    public var materializationSessionId: UUID?

    private let discoveryService = SessionDiscoveryService()
    private let materializer = ArtifactMaterializer()
    private var materializationTask: Task<Void, Never>?

    public init() {}

    /// Discover sessions from manifest files and sync with SwiftData index.
    public func loadSessions(context: ModelContext) {
        isLoading = true
        errorMessage = nil

        discoveryService.syncIndex(context: context)

        var descriptor = FetchDescriptor<SessionIndex>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500

        do {
            sessions = try context.fetch(descriptor)
        } catch {
            Self.logger.error("Failed to fetch sessions: \(error)")
            errorMessage = "Failed to load sessions."
        }

        isLoading = false
    }

    /// Remove a session from the SwiftData index and local session list.
    /// Does not delete the underlying artifact or manifest files on disk.
    public func deleteSession(
        _ sessionId: UUID,
        context: ModelContext
    ) {
        let sid = sessionId
        let pred = #Predicate<SessionIndex> {
            $0.sessionId == sid
        }
        if let match = try? context.fetch(
            FetchDescriptor<SessionIndex>(predicate: pred)
        ).first {
            context.delete(match)
            do {
                try context.save()
                sessions.removeAll { $0.sessionId == sessionId }
                if selectedSessionId == sessionId {
                    selectedSessionId = sessions.first?.sessionId
                }
            } catch {
                Self.logger.error(
                    "Failed to delete session: \(error)"
                )
            }
        }
    }

    /// Ensure a session's groups are materialized into GroupSummary rows.
    /// Uses freshness check: skips if `.current`, re-materializes if
    /// `.stale` or `.partial`. Uses double-buffer so old rows stay
    /// visible during rebuild.
    public func ensureMaterialized(
        sessionId: UUID,
        container: ModelContainer,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        // Find the session index entry
        guard let session = sessions.first(
            where: { $0.sessionId == sessionId }
        ) else {
            return
        }

        // Check freshness
        let state = ArtifactMaterializer.materializationState(
            session: session
        )
        if case .current = state {
            onComplete?()
            return
        }

        // Already materializing this session?
        if materializationSessionId == sessionId {
            return
        }

        materializationTask?.cancel()
        materializationSessionId = sessionId
        materializationProgress = 0

        materializationTask = Task {
            do {
                let snapshot = ArtifactMaterializer.SessionSnapshot(
                    session: session
                )
                let count = try await materializer.materialize(
                    session: snapshot,
                    container: container
                ) { current, total in
                    Task { @MainActor in
                        self.materializationProgress =
                            Double(current) / Double(total)
                    }
                }
                Self.logger.info(
                    "Materialized \(count) groups for \(sessionId)"
                )
                onComplete?()
            } catch is CancellationError {
                Self.logger.info(
                    "Materialization cancelled for \(sessionId)"
                )
            } catch {
                Self.logger.error(
                    "Materialization failed: \(error)"
                )
                errorMessage = "Failed to load session groups."
            }

            materializationProgress = nil
            materializationSessionId = nil
        }
    }
}
