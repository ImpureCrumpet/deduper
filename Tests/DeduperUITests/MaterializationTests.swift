import Testing
import Foundation
import SwiftData
@testable import DeduperUI
@testable import DeduperKit

@Suite("Materialization")
struct MaterializationTests {
    @MainActor
    private func makeTestSession(
        groups: [StoredDuplicateGroup],
        tempDir: URL
    ) throws -> (
        ModelContainer, SessionIndex,
        ArtifactMaterializer.SessionSnapshot
    ) {
        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)

        let artifactPath = tempDir.appendingPathComponent(
            "test.ndjson.gz"
        )
        try SessionArtifact.write(groups: groups, to: artifactPath)

        let sessionId = UUID()
        let session = SessionIndex(
            sessionId: sessionId,
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
        return (container, session, snapshot)
    }

    private func makeGroups(
        count: Int, membersEach: Int = 2
    ) -> [StoredDuplicateGroup] {
        (0..<count).map { i in
            let paths = (0..<membersEach).map {
                "/tmp/test/group\(i)/file\($0).jpg"
            }
            let sizes = (0..<membersEach).map {
                Int64(($0 + 1) * 1000)
            }
            return StoredDuplicateGroup(
                groupId: UUID(),
                groupIndex: i,
                confidence: 0.95,
                keeperPath: paths.first,
                memberPaths: paths,
                memberSizes: sizes,
                mediaType: 1
            )
        }
    }

    @MainActor
    private func fetchSession(
        sessionId: UUID,
        container: ModelContainer
    ) throws -> SessionIndex {
        let context = ModelContext(container)
        let sid = sessionId
        let pred = #Predicate<SessionIndex> {
            $0.sessionId == sid
        }
        var desc = FetchDescriptor<SessionIndex>(predicate: pred)
        desc.fetchLimit = 1
        return try context.fetch(desc).first!
    }

    @Test("State transitions: notMaterialized → materialize → current")
    @MainActor
    func stateTransitions() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groups = makeGroups(count: 5)
        let (container, session, snapshot) = try makeTestSession(
            groups: groups, tempDir: tempDir
        )

        let initialState = ArtifactMaterializer.materializationState(
            session: session
        )
        guard case .notMaterialized = initialState else {
            Issue.record(
                "Expected .notMaterialized, got \(initialState)"
            )
            return
        }

        let materializer = ArtifactMaterializer()
        let count = try await materializer.materialize(
            session: snapshot, container: container
        )
        #expect(count == 5)

        let refreshed = try fetchSession(
            sessionId: session.sessionId, container: container
        )
        let afterState = ArtifactMaterializer.materializationState(
            session: refreshed
        )
        guard case .current = afterState else {
            Issue.record("Expected .current, got \(afterState)")
            return
        }
    }

    @Test("Materialize twice produces N groups, not 2N (idempotent)")
    @MainActor
    func idempotentMaterialization() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groups = makeGroups(count: 3)
        let (container, session, snapshot) = try makeTestSession(
            groups: groups, tempDir: tempDir
        )

        let materializer = ArtifactMaterializer()

        let count1 = try await materializer.materialize(
            session: snapshot, container: container
        )
        #expect(count1 == 3)

        let count2 = try await materializer.materialize(
            session: snapshot, container: container
        )
        #expect(count2 == 3)

        let context = ModelContext(container)
        let sid = session.sessionId
        let sPred = #Predicate<GroupSummary> {
            $0.sessionId == sid
        }
        let summaryCount = try context.fetchCount(
            FetchDescriptor<GroupSummary>(predicate: sPred)
        )
        #expect(summaryCount == 3)

        let mPred = #Predicate<GroupMember> {
            $0.sessionId == sid
        }
        let memberCount = try context.fetchCount(
            FetchDescriptor<GroupMember>(predicate: mPred)
        )
        #expect(memberCount == 6)
    }

    @Test("Stale artifact triggers .stale state")
    @MainActor
    func staleArtifactDetection() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groups = makeGroups(count: 2)
        let (container, session, snapshot) = try makeTestSession(
            groups: groups, tempDir: tempDir
        )

        let materializer = ArtifactMaterializer()
        _ = try await materializer.materialize(
            session: snapshot, container: container
        )

        let refreshed = try fetchSession(
            sessionId: session.sessionId, container: container
        )

        try await Task.sleep(for: .milliseconds(100))
        let artifactURL = URL(
            fileURLWithPath: refreshed.artifactPath
        )
        let newGroups = makeGroups(count: 3)
        try SessionArtifact.write(groups: newGroups, to: artifactURL)

        let state = ArtifactMaterializer.materializationState(
            session: refreshed
        )
        guard case .stale = state else {
            Issue.record("Expected .stale, got \(state)")
            return
        }
    }

    @Test("V1 artifact materializes with legacyUnknown matchKind")
    @MainActor
    func v1ArtifactMaterializesAsLegacy() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // V1 groups have no matchKind or schemaVersion
        let groups = makeGroups(count: 2)
        let (container, session, snapshot) = try makeTestSession(
            groups: groups, tempDir: tempDir
        )

        let materializer = ArtifactMaterializer()
        _ = try await materializer.materialize(
            session: snapshot, container: container
        )

        let context = ModelContext(container)
        let sid = session.sessionId
        let pred = #Predicate<GroupSummary> {
            $0.sessionId == sid
        }
        let summaries = try context.fetch(
            FetchDescriptor<GroupSummary>(predicate: pred)
        )
        #expect(summaries.count == 2)
        for summary in summaries {
            #expect(
                summary.matchKind == MatchKind.legacyUnknown.rawValue
            )
        }
    }

    @Test("Partial materialization detected by count mismatch")
    func partialMaterializationDetection() {
        let session = SessionIndex(
            sessionId: UUID(),
            directoryPath: "/tmp",
            startedAt: Date(),
            duplicateGroups: 10,
            artifactPath: "/tmp/fake.ndjson.gz",
            manifestPath: "/tmp/fake.manifest.json",
            materializedGroupCount: 5,
            currentRunId: UUID()
        )

        let mtime: Date? = nil
        let state = session.materializationState(
            artifactMtime: mtime
        )
        guard case .partial(let have, let expected) = state else {
            Issue.record("Expected .partial, got \(state)")
            return
        }
        #expect(have == 5)
        #expect(expected == 10)
    }

    @Test("Dematerialize removes all rows and resets state")
    @MainActor
    func dematerialize() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groups = makeGroups(count: 3)
        let (container, session, snapshot) = try makeTestSession(
            groups: groups, tempDir: tempDir
        )

        let materializer = ArtifactMaterializer()
        _ = try await materializer.materialize(
            session: snapshot, container: container
        )

        let context = ModelContext(container)
        try ArtifactMaterializer.dematerializeIndex(
            sessionId: session.sessionId, in: context
        )

        let sid = session.sessionId
        let sPred = #Predicate<GroupSummary> {
            $0.sessionId == sid
        }
        let summaryCount = try context.fetchCount(
            FetchDescriptor<GroupSummary>(predicate: sPred)
        )
        #expect(summaryCount == 0)

        let mPred = #Predicate<GroupMember> {
            $0.sessionId == sid
        }
        let memberCount = try context.fetchCount(
            FetchDescriptor<GroupMember>(predicate: mPred)
        )
        #expect(memberCount == 0)
    }
}
