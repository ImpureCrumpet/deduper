import Foundation
import SwiftData

/// Creates a ModelContainer for UI-only models.
/// This store is completely separate from the CLI's SwiftData store.
/// The CLI never sees these models; the app never opens the CLI's store.
public enum UIPersistenceFactory {
    /// Create the app's SwiftData container.
    /// Pass `inMemory: true` for testing.
    public static func makeContainer(
        inMemory: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([
            SessionIndex.self,
            GroupSummary.self,
            GroupMember.self,
            ReviewDecision.self
        ])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
        } else {
            config = ModelConfiguration(
                "DeduperUI",
                schema: schema,
                url: storeURL()
            )
        }
        return try ModelContainer(
            for: schema, configurations: [config]
        )
    }

    /// Explicit store path under ~/Library/Application Support/Deduper/ui/.
    private static func storeURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport
            .appendingPathComponent("Deduper")
            .appendingPathComponent("ui")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("DeduperUI.store")
    }
}
