import Testing
import Foundation
import SwiftData
@testable import DeduperUI
@testable import DeduperKit

@Suite("DetailCancellation")
struct DetailCancellationTests {
    @MainActor
    private func materialize(
        groups: [StoredDuplicateGroup]
    ) async throws -> (ModelContainer, SessionIndex) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )

        let artifactPath = tempDir.appendingPathComponent(
            "test.ndjson.gz"
        )
        try SessionArtifact.write(groups: groups, to: artifactPath)

        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)

        let session = SessionIndex(
            sessionId: UUID(),
            directoryPath: tempDir.path,
            startedAt: Date(),
            duplicateGroups: groups.count,
            artifactPath: artifactPath.path,
            manifestPath: tempDir.appendingPathComponent(
                "test.manifest.json"
            ).path
        )
        context.insert(session)
        try context.save()

        let snapshot = ArtifactMaterializer.SessionSnapshot(
            session: session
        )
        let materializer = ArtifactMaterializer()
        _ = try await materializer.materialize(
            session: snapshot, container: container
        )

        return (container, session)
    }

    private func makeGroups(
        count: Int
    ) -> [StoredDuplicateGroup] {
        (0..<count).map { i in
            StoredDuplicateGroup(
                groupId: UUID(),
                groupIndex: i,
                confidence: 0.9,
                keeperPath: "/tmp/g\(i)/file0.jpg",
                memberPaths: [
                    "/tmp/g\(i)/file0.jpg",
                    "/tmp/g\(i)/file1.jpg"
                ],
                memberSizes: [1000, 1000],
                mediaType: 1
            )
        }
    }

    @MainActor
    private func fetchSessionRunId(
        sessionId: UUID,
        container: ModelContainer
    ) throws -> UUID {
        let context = ModelContext(container)
        let sid = sessionId
        let pred = #Predicate<SessionIndex> {
            $0.sessionId == sid
        }
        var desc = FetchDescriptor<SessionIndex>(predicate: pred)
        desc.fetchLimit = 1
        return try context.fetch(desc).first!.currentRunId!
    }

    @MainActor
    private func makeGroupSummary(
        from group: StoredDuplicateGroup,
        sessionId: UUID,
        runId: UUID
    ) -> GroupSummary {
        GroupSummary(
            sessionId: sessionId,
            groupIndex: group.groupIndex,
            groupId: group.groupId,
            confidence: group.confidence,
            mediaTypeRaw: group.mediaType,
            memberCount: group.memberPaths.count,
            suggestedKeeperPath: group.keeperPath,
            totalSize: 2000,
            spaceSavings: 1000,
            materializationRunId: runId
        )
    }

    @Test("Rapid group selection: only last group's members published")
    @MainActor
    func rapidSelectionPublishesOnlyLast() async throws {
        let groups = makeGroups(count: 3)
        let (container, session) = try await materialize(
            groups: groups
        )

        let sid = session.sessionId
        let runId = try fetchSessionRunId(
            sessionId: sid, container: container
        )

        let vm = GroupDetailViewModel()

        // Load group A
        let summaryA = makeGroupSummary(
            from: groups[0], sessionId: sid, runId: runId
        )
        vm.loadGroup(
            groupSummary: summaryA, container: container
        )

        // Immediately load group B (cancels A)
        let summaryB = makeGroupSummary(
            from: groups[1], sessionId: sid, runId: runId
        )
        vm.loadGroup(
            groupSummary: summaryB, container: container
        )

        // Wait for enrichment to complete
        // (files don't exist so enrichment is fast)
        try await Task.sleep(for: .milliseconds(500))

        // Should show group B's index, not A's
        #expect(vm.groupIndex == groups[1].groupIndex)
        // Members should be loaded (even though files don't exist,
        // GroupMember rows were materialized)
        #expect(vm.members.count == 2)
    }

    @Test("Epoch guard prevents stale writes after rapid switching")
    @MainActor
    func epochGuardPreventsStaleWrites() async throws {
        let groups = makeGroups(count: 3)
        let (container, session) = try await materialize(
            groups: groups
        )

        let sid = session.sessionId
        let runId = try fetchSessionRunId(
            sessionId: sid, container: container
        )

        let vm = GroupDetailViewModel()

        // Rapid A → B → C
        for group in groups {
            let summary = makeGroupSummary(
                from: group, sessionId: sid, runId: runId
            )
            vm.loadGroup(
                groupSummary: summary, container: container
            )
        }

        // Wait for all enrichments to settle
        try await Task.sleep(for: .milliseconds(500))

        // Only group C's data should be visible
        #expect(vm.groupIndex == groups[2].groupIndex)
        #expect(vm.members.count == 2)
        // Verify member paths belong to group C
        for member in vm.members {
            #expect(member.path.contains("g2"))
        }
    }

    @Test("Double-approve does not trigger decision callback twice")
    @MainActor
    func doubleApproveIdempotent() async throws {
        let groups = makeGroups(count: 2)
        let (container, session) = try await materialize(
            groups: groups
        )

        let sid = session.sessionId
        let runId = try fetchSessionRunId(
            sessionId: sid, container: container
        )

        let vm = GroupDetailViewModel()
        let context = ModelContext(container)

        let summary = makeGroupSummary(
            from: groups[0], sessionId: sid, runId: runId
        )
        vm.loadGroup(
            groupSummary: summary,
            container: container,
            context: context
        )

        // Wait for load
        try await Task.sleep(for: .milliseconds(300))

        var decisionCount = 0
        vm.onDecisionChanged = { _, _ in
            decisionCount += 1
        }

        // First approve
        vm.approve(context: context)
        #expect(decisionCount == 1)

        // Second approve (same state) — should be idempotent
        vm.approve(context: context)
        #expect(decisionCount == 1)
    }

    @Test("Clear cancels in-flight load")
    @MainActor
    func clearCancelsLoad() async throws {
        let groups = makeGroups(count: 1)
        let (container, session) = try await materialize(
            groups: groups
        )

        let sid = session.sessionId
        let runId = try fetchSessionRunId(
            sessionId: sid, container: container
        )

        let vm = GroupDetailViewModel()

        let summary = makeGroupSummary(
            from: groups[0], sessionId: sid, runId: runId
        )
        vm.loadGroup(
            groupSummary: summary, container: container
        )

        // Immediately clear
        vm.clear()

        #expect(vm.members.isEmpty)
        #expect(vm.isLoading == false)
    }
}
