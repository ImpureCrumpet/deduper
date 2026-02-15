import ArgumentParser
import Foundation
import DeduperKit
import SwiftData

struct DeleteSession: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-session",
        abstract: "Delete a scan session and its stored results."
    )

    @Argument(help: "Session ID to delete.")
    var sessionId: String

    @MainActor
    func run() async throws {
        guard let uuid = UUID(uuidString: sessionId) else {
            throw ValidationError("Invalid session ID: \(sessionId)")
        }

        let container = try PersistenceFactory.makeContainer()
        let context = ModelContext(container)

        let predicate = #Predicate<ScanSession> {
            $0.sessionId == uuid
        }
        var descriptor = FetchDescriptor<ScanSession>(predicate: predicate)
        descriptor.fetchLimit = 1
        let sessions = try context.fetch(descriptor)

        guard let session = sessions.first else {
            throw ValidationError(
                "Session not found: \(sessionId)\n"
                + "Run 'deduper history' to see available sessions."
            )
        }

        context.delete(session)
        try context.save()

        print("Deleted session \(uuid.uuidString).")
    }
}
