import Testing
import Foundation
import SwiftData
@testable import DeduperUI
@testable import DeduperKit

@Suite("GroupMember")
struct GroupMemberTests {
    /// Helper: create test groups with specified structure.
    private func makeGroups() -> [StoredDuplicateGroup] {
        [
            StoredDuplicateGroup(
                groupId: UUID(),
                groupIndex: 0,
                confidence: 1.0,
                keeperPath: "/tmp/a/photo1.jpg",
                memberPaths: [
                    "/tmp/a/photo1.jpg", "/tmp/a/photo1_copy.jpg"
                ],
                memberSizes: [5000, 5000],
                mediaType: 1
            ),
            StoredDuplicateGroup(
                groupId: UUID(),
                groupIndex: 1,
                confidence: 0.92,
                keeperPath: "/tmp/b/image.png",
                memberPaths: [
                    "/tmp/b/image.png", "/tmp/b/image2.png"
                ],
                memberSizes: [12000, 11500],
                mediaType: 1
            ),
            StoredDuplicateGroup(
                groupId: UUID(),
                groupIndex: 2,
                confidence: 0.85,
                keeperPath: "/tmp/c/video.mov",
                memberPaths: [
                    "/tmp/c/video.mov", "/tmp/c/video_dup.mov"
                ],
                memberSizes: [500_000, 490_000],
                mediaType: 2
            )
        ]
    }

    @MainActor
    private func materializeGroups(
        _ groups: [StoredDuplicateGroup]
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
            session: snapshot,
            container: container
        )

        return (container, session)
    }

    @Test("3 groups × 2 members = 6 GroupMember rows")
    @MainActor
    func correctRowCount() async throws {
        let groups = makeGroups()
        let (container, session) = try await materializeGroups(groups)

        let context = ModelContext(container)
        let sid = session.sessionId
        let predicate = #Predicate<GroupMember> {
            $0.sessionId == sid
        }
        let count = try context.fetchCount(
            FetchDescriptor<GroupMember>(predicate: predicate)
        )
        #expect(count == 6)
    }

    @Test("Fetch members by groupId returns correct paths and sizes")
    @MainActor
    func fetchByGroupId() async throws {
        let groups = makeGroups()
        let targetGroupId = groups[1].groupId
        let (container, _) = try await materializeGroups(groups)

        let context = ModelContext(container)
        let predicate = #Predicate<GroupMember> {
            $0.groupId == targetGroupId
        }
        let descriptor = FetchDescriptor<GroupMember>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.memberIndex)]
        )
        let members = try context.fetch(descriptor)

        #expect(members.count == 2)
        #expect(members[0].filePath == "/tmp/b/image.png")
        #expect(members[0].fileName == "image.png")
        #expect(members[0].fileSize == 12000)
        #expect(members[1].filePath == "/tmp/b/image2.png")
        #expect(members[1].fileSize == 11500)
    }

    @Test("isKeeper flag set on correct member")
    @MainActor
    func keeperFlag() async throws {
        let groups = makeGroups()
        let targetGroupId = groups[0].groupId
        let (container, _) = try await materializeGroups(groups)

        let context = ModelContext(container)
        let predicate = #Predicate<GroupMember> {
            $0.groupId == targetGroupId
        }
        let descriptor = FetchDescriptor<GroupMember>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.memberIndex)]
        )
        let members = try context.fetch(descriptor)

        #expect(members[0].isKeeper == true)
        #expect(members[1].isKeeper == false)
    }

    @Test("Dematerialize removes all GroupMember rows")
    @MainActor
    func dematerializeClears() async throws {
        let groups = makeGroups()
        let (container, session) = try await materializeGroups(groups)

        let context = ModelContext(container)
        try ArtifactMaterializer.dematerializeIndex(
            sessionId: session.sessionId, in: context
        )

        let sid = session.sessionId
        let predicate = #Predicate<GroupMember> {
            $0.sessionId == sid
        }
        let count = try context.fetchCount(
            FetchDescriptor<GroupMember>(predicate: predicate)
        )
        #expect(count == 0)
    }

    @Test("fileName is derived correctly from path")
    @MainActor
    func fileNameDerivation() async throws {
        let groups = makeGroups()
        let (container, session) = try await materializeGroups(groups)

        let context = ModelContext(container)
        let sid = session.sessionId
        let predicate = #Predicate<GroupMember> {
            $0.sessionId == sid
        }
        let descriptor = FetchDescriptor<GroupMember>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.groupIndex),
                     SortDescriptor(\.memberIndex)]
        )
        let members = try context.fetch(descriptor)

        #expect(members[0].fileName == "photo1.jpg")
        #expect(members[1].fileName == "photo1_copy.jpg")
        #expect(members[4].fileName == "video.mov")
    }
}
