import Testing
import Foundation
import SwiftData
@testable import DeduperKit

@Suite("Persistence")
struct PersistenceTests {

    @Test("Create in-memory container")
    @MainActor
    func createInMemoryContainer() throws {
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let context = ModelContext(container)
        // Should succeed without error
        #expect(context.autosaveEnabled)
    }

    @Test("Insert and fetch ScanSession")
    @MainActor
    func insertAndFetchSession() throws {
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let session = ScanSession(
            directoryPath: "/tmp/test",
            totalFiles: 100,
            mediaFiles: 42,
            duplicateGroups: 5
        )
        context.insert(session)
        try context.save()

        let descriptor = FetchDescriptor<ScanSession>()
        let sessions = try context.fetch(descriptor)
        #expect(sessions.count == 1)
        #expect(sessions[0].directoryPath == "/tmp/test")
        #expect(sessions[0].totalFiles == 100)
        #expect(sessions[0].mediaFiles == 42)
        #expect(sessions[0].duplicateGroups == 5)
    }

    @Test("ScanSession sessionId is unique per instance")
    @MainActor
    func sessionIdUnique() throws {
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let s1 = ScanSession(directoryPath: "/a")
        let s2 = ScanSession(directoryPath: "/b")
        context.insert(s1)
        context.insert(s2)
        try context.save()

        #expect(s1.sessionId != s2.sessionId)
    }

    @Test("ScanSession stores and recovers resultsJSON")
    @MainActor
    func sessionResultsJSON() throws {
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let groups = [
            StoredDuplicateGroup(
                groupId: UUID(),
                confidence: 0.92,
                keeperPath: "/a/photo.jpg",
                memberPaths: ["/a/photo.jpg", "/b/photo-copy.jpg"],
                mediaType: 0
            )
        ]

        let session = ScanSession(directoryPath: "/photos")
        session.resultsJSON = try JSONEncoder().encode(groups)
        context.insert(session)
        try context.save()

        let descriptor = FetchDescriptor<ScanSession>()
        let fetched = try context.fetch(descriptor).first!
        let decoded = try JSONDecoder().decode(
            [StoredDuplicateGroup].self,
            from: fetched.resultsJSON!
        )

        #expect(decoded.count == 1)
        #expect(decoded[0].confidence == 0.92)
        #expect(decoded[0].memberPaths.count == 2)
        #expect(decoded[0].keeperPath == "/a/photo.jpg")
    }

    @Test("Insert and fetch HashedFile")
    @MainActor
    func insertAndFetchHashedFile() throws {
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let hf = HashedFile(
            filePath: "/photos/img.jpg",
            fileSize: 1234,
            hashAlgorithm: "pHash",
            perceptualHash: "ABCDEF1234567890"
        )
        context.insert(hf)
        try context.save()

        let descriptor = FetchDescriptor<HashedFile>()
        let results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results[0].filePath == "/photos/img.jpg")
        #expect(results[0].perceptualHash == "ABCDEF1234567890")
        #expect(results[0].hashAlgorithm == "pHash")
    }

    @Test("HashCacheService stores and retrieves hashes")
    @MainActor
    func hashCacheRoundTrip() async throws {
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let cache = HashCacheService(container: container)

        let path = "/photos/test.jpg"
        let size: Int64 = 5000
        let mtime = Date()

        // Initially empty
        let miss = await cache.lookup(
            path: path, fileSize: size, modifiedAt: mtime
        )
        #expect(miss == nil)

        // Store hashes
        await cache.store(
            path: path,
            fileSize: size,
            modifiedAt: mtime,
            hashes: [
                (algorithm: "dHash", hash: 0xABCD),
                (algorithm: "pHash", hash: 0x1234)
            ]
        )

        // Lookup should hit
        let hit = await cache.lookup(
            path: path, fileSize: size, modifiedAt: mtime
        )
        #expect(hit != nil)
        #expect(hit?.count == 2)
        #expect(hit?.contains { $0.algorithm == "dHash" && $0.hash == 0xABCD } == true)
        #expect(hit?.contains { $0.algorithm == "pHash" && $0.hash == 0x1234 } == true)
    }

    @Test("HashCacheService invalidates on size change")
    @MainActor
    func hashCacheInvalidatesOnSizeChange() async throws {
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let cache = HashCacheService(container: container)

        let path = "/photos/changed.jpg"
        let mtime = Date()

        await cache.store(
            path: path,
            fileSize: 1000,
            modifiedAt: mtime,
            hashes: [(algorithm: "pHash", hash: 0xFF)]
        )

        // Different size should miss
        let miss = await cache.lookup(
            path: path, fileSize: 2000, modifiedAt: mtime
        )
        #expect(miss == nil)
    }

    @Test("StoredDuplicateGroup round-trips through Codable")
    func storedGroupCodable() throws {
        let group = StoredDuplicateGroup(
            groupId: UUID(),
            confidence: 0.88,
            keeperPath: "/keep.jpg",
            memberPaths: ["/keep.jpg", "/dup1.jpg", "/dup2.jpg"],
            mediaType: 0
        )

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(
            StoredDuplicateGroup.self,
            from: data
        )

        #expect(decoded.groupId == group.groupId)
        #expect(decoded.confidence == 0.88)
        #expect(decoded.memberPaths.count == 3)
        #expect(decoded.keeperPath == "/keep.jpg")
    }
}
