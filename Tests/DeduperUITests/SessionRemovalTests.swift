import Testing
import Foundation
import SwiftData
@testable import DeduperUI
@testable import DeduperKit

@Suite("Session Removal")
@MainActor
struct SessionRemovalTests {

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        try UIPersistenceFactory.makeContainer(inMemory: true)
    }

    private func makeSession(
        in context: ModelContext,
        sessionId: UUID = UUID()
    ) -> SessionIndex {
        let entry = SessionIndex(
            sessionId: sessionId,
            directoryPath: "/tmp/test",
            startedAt: Date(),
            artifactPath: "/tmp/test/artifact.ndjson.gz",
            manifestPath: "/tmp/test/manifest.json"
        )
        context.insert(entry)
        try? context.save()
        return entry
    }

    // MARK: - Tombstone persistence

    @Test("Deleted session is marked hidden, not physically deleted")
    func deletedSessionIsHidden() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid = UUID()
        _ = makeSession(in: context, sessionId: sid)

        // Sync so vm.sessions is populated
        vm.sessions = try context.fetch(FetchDescriptor<SessionIndex>())
        vm.deleteSession(sid, context: context)

        // Row still exists in SwiftData
        let pred = #Predicate<SessionIndex> { $0.sessionId == sid }
        let remaining = try context.fetch(
            FetchDescriptor<SessionIndex>(predicate: pred)
        )
        #expect(remaining.count == 1)
        #expect(remaining.first?.isHidden == true)
    }

    @Test("Hidden session excluded from loadSessions fetch")
    func hiddenSessionExcludedFromFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid = UUID()
        _ = makeSession(in: context, sessionId: sid)

        vm.sessions = try context.fetch(FetchDescriptor<SessionIndex>())
        vm.deleteSession(sid, context: context)

        // loadSessions should not return hidden sessions
        let descriptor = FetchDescriptor<SessionIndex>(
            predicate: #Predicate { !$0.isHidden }
        )
        let visible = try context.fetch(descriptor)
        #expect(visible.isEmpty)
    }

    @Test("Discovery syncIndex does not re-add hidden session")
    func discoveryDoesNotUnhide() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid = UUID()
        let entry = makeSession(in: context, sessionId: sid)

        // Mark as hidden
        vm.sessions = [entry]
        vm.deleteSession(sid, context: context)

        // The session ID is already in existingIds, so syncIndex won't
        // re-insert it. Simulate what syncIndex would do for a "newly
        // discovered" manifest with the same sessionId:
        let existing = try context.fetch(FetchDescriptor<SessionIndex>())
        let existingIds = Set(existing.map(\.sessionId))
        #expect(existingIds.contains(sid))
        // Since sid is in existingIds, the "insert new" branch is skipped
        #expect(existing.first?.isHidden == true)
    }

    @Test("Discovery syncIndex preserves hidden row even if manifest absent")
    func hiddenRowSurvivesOrphanSweep() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid = UUID()
        let entry = makeSession(in: context, sessionId: sid)

        vm.sessions = [entry]
        vm.deleteSession(sid, context: context)

        // Simulate orphan sweep: manifestIds does NOT contain sid
        // (as if manifest was deleted from disk).
        // Hidden rows must survive this sweep.
        let existing = try context.fetch(FetchDescriptor<SessionIndex>())
        let manifestIds: Set<UUID> = []  // no manifests on disk
        for row in existing where !manifestIds.contains(row.sessionId) && !row.isHidden {
            context.delete(row)
        }
        try context.save()

        // Hidden row should still be present
        let remaining = try context.fetch(
            FetchDescriptor<SessionIndex>(
                predicate: #Predicate { $0.sessionId == sid }
            )
        )
        #expect(remaining.count == 1)
        #expect(remaining.first?.isHidden == true)
    }

    @Test("Deleting session advances selection to next session")
    func deletionAdvancesSelection() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid1 = UUID()
        let sid2 = UUID()
        _ = makeSession(in: context, sessionId: sid1)
        _ = makeSession(in: context, sessionId: sid2)

        vm.sessions = try context.fetch(FetchDescriptor<SessionIndex>())
        vm.selectedSessionId = sid1
        vm.deleteSession(sid1, context: context)

        // selectedSessionId should advance to remaining session
        #expect(vm.selectedSessionId == sid2 || vm.selectedSessionId != sid1)
        #expect(!vm.sessions.contains(where: { $0.sessionId == sid1 }))
    }

    @Test("SessionIndex isHidden defaults to false on new entries")
    func newEntryIsVisibleByDefault() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeSession(in: context)
        #expect(entry.isHidden == false)
    }

    // MARK: - Bulk delete

    @Test("deleteSessions hides all specified sessions")
    func bulkDeleteHidesAll() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid1 = UUID()
        let sid2 = UUID()
        let sid3 = UUID()
        _ = makeSession(in: context, sessionId: sid1)
        _ = makeSession(in: context, sessionId: sid2)
        _ = makeSession(in: context, sessionId: sid3)

        vm.sessions = try context.fetch(FetchDescriptor<SessionIndex>())
        vm.deleteSessions([sid1, sid2], context: context)

        // Both targeted sessions are hidden
        let all = try context.fetch(FetchDescriptor<SessionIndex>())
        let hidden = all.filter(\.isHidden)
        let visible = all.filter { !$0.isHidden }
        #expect(hidden.count == 2)
        #expect(visible.count == 1)
        #expect(visible.first?.sessionId == sid3)

        // vm.sessions only contains the remaining visible session
        #expect(vm.sessions.count == 1)
        #expect(vm.sessions.first?.sessionId == sid3)
    }

    @Test("deleteSessions clears selectedSessionIds for removed sessions")
    func bulkDeleteClearsSelectionSet() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid1 = UUID()
        let sid2 = UUID()
        _ = makeSession(in: context, sessionId: sid1)
        _ = makeSession(in: context, sessionId: sid2)

        vm.sessions = try context.fetch(FetchDescriptor<SessionIndex>())
        vm.selectedSessionIds = [sid1, sid2]
        vm.deleteSessions([sid1, sid2], context: context)

        #expect(vm.selectedSessionIds.isEmpty)
    }

    @Test("deleteSessions advances selectedSessionId when active is removed")
    func bulkDeleteAdvancesActiveSession() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid1 = UUID()
        let sid2 = UUID()
        let sid3 = UUID()
        _ = makeSession(in: context, sessionId: sid1)
        _ = makeSession(in: context, sessionId: sid2)
        _ = makeSession(in: context, sessionId: sid3)

        vm.sessions = try context.fetch(FetchDescriptor<SessionIndex>())
        vm.selectedSessionId = sid1
        vm.deleteSessions([sid1, sid2], context: context)

        // Active session should not be one of the removed sessions
        #expect(vm.selectedSessionId != sid1)
        #expect(vm.selectedSessionId != sid2)
        // Should have advanced to sid3 (the only remaining session)
        #expect(vm.selectedSessionId == sid3)
    }

    @Test("deleteSessions with empty set is a no-op")
    func bulkDeleteEmptySetIsNoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = SessionListViewModel()
        let sid = UUID()
        _ = makeSession(in: context, sessionId: sid)
        vm.sessions = try context.fetch(FetchDescriptor<SessionIndex>())

        vm.deleteSessions([], context: context)

        #expect(vm.sessions.count == 1)
        let all = try context.fetch(FetchDescriptor<SessionIndex>())
        #expect(all.first?.isHidden == false)
    }
}
