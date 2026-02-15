import Testing
import Foundation
import SwiftData
@testable import DeduperKit

@Suite("Persistence")
struct PersistenceTests {

    @Test("Create in-memory container")
    @MainActor
    func createInMemoryContainer() throws {
        let container = try PersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        #expect(context.autosaveEnabled)
    }

    @Test("Insert and fetch ScanSession")
    @MainActor
    func insertAndFetchSession() throws {
        let container = try PersistenceFactory.makeContainer(
            inMemory: true
        )
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
        let container = try PersistenceFactory.makeContainer(
            inMemory: true
        )
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
        let container = try PersistenceFactory.makeContainer(
            inMemory: true
        )
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
        let container = try PersistenceFactory.makeContainer(
            inMemory: true
        )
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
        #expect(
            results[0].perceptualHash == "ABCDEF1234567890"
        )
        #expect(results[0].hashAlgorithm == "pHash")
    }

    @Test("HashCacheService stores and retrieves hashes")
    @MainActor
    func hashCacheRoundTrip() async throws {
        let container = try PersistenceFactory.makeContainer(
            inMemory: true
        )
        let cache = HashCacheService(container: container)

        let path = "/photos/test.jpg"
        let size: Int64 = 5000
        let mtime = Date()

        let miss = await cache.lookup(
            path: path, fileSize: size, modifiedAt: mtime
        )
        #expect(miss == nil)

        await cache.store(
            path: path,
            fileSize: size,
            modifiedAt: mtime,
            hashes: [
                (algorithm: "dHash", hash: 0xABCD),
                (algorithm: "pHash", hash: 0x1234)
            ]
        )

        let hit = await cache.lookup(
            path: path, fileSize: size, modifiedAt: mtime
        )
        #expect(hit != nil)
        #expect(hit?.count == 2)
        #expect(
            hit?.contains {
                $0.algorithm == "dHash" && $0.hash == 0xABCD
            } == true
        )
        #expect(
            hit?.contains {
                $0.algorithm == "pHash" && $0.hash == 0x1234
            } == true
        )
    }

    @Test("HashCacheService invalidates on size change")
    @MainActor
    func hashCacheInvalidatesOnSizeChange() async throws {
        let container = try PersistenceFactory.makeContainer(
            inMemory: true
        )
        let cache = HashCacheService(container: container)

        let path = "/photos/changed.jpg"
        let mtime = Date()

        await cache.store(
            path: path,
            fileSize: 1000,
            modifiedAt: mtime,
            hashes: [(algorithm: "pHash", hash: 0xFF)]
        )

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
            StoredDuplicateGroup.self, from: data
        )

        #expect(decoded.groupId == group.groupId)
        #expect(decoded.confidence == 0.88)
        #expect(decoded.memberPaths.count == 3)
        #expect(decoded.keeperPath == "/keep.jpg")
    }

    // MARK: - Artifact Tests

    @Test("Write and read artifact with 1000 groups")
    func artifactWriteRead() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "deduper-art-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )

        let artPath = tmp.appendingPathComponent("test.ndjson.gz")

        var groups: [StoredDuplicateGroup] = []
        for i in 0..<1000 {
            groups.append(StoredDuplicateGroup(
                groupId: UUID(),
                groupIndex: i + 1,
                confidence: Double(i) / 1000.0,
                keeperPath: "/keep\(i).jpg",
                memberPaths: [
                    "/keep\(i).jpg", "/dup\(i).jpg"
                ],
                mediaType: 0
            ))
        }

        try SessionArtifact.write(groups: groups, to: artPath)

        let read = try SessionArtifact.readGroups(from: artPath)
        #expect(read.count == 1000)
        #expect(read[0].groupIndex == 1)
        #expect(read[999].groupIndex == 1000)
    }

    @Test("Streaming filter retrieves only matching group")
    func artifactStreamingFilter() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "deduper-art2-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )

        let artPath = tmp.appendingPathComponent("test.ndjson.gz")

        var groups: [StoredDuplicateGroup] = []
        for i in 0..<100 {
            groups.append(StoredDuplicateGroup(
                groupId: UUID(),
                groupIndex: i + 1,
                confidence: 0.9,
                keeperPath: "/keep\(i).jpg",
                memberPaths: [
                    "/keep\(i).jpg", "/dup\(i).jpg"
                ],
                mediaType: 0
            ))
        }

        try SessionArtifact.write(groups: groups, to: artPath)

        let filtered = try SessionArtifact.readGroups(
            from: artPath
        ) { $0.groupIndex == 42 }

        #expect(filtered.count == 1)
        #expect(filtered[0].groupIndex == 42)
    }

    @Test("Sessions with resultsJSON still load (migration)")
    @MainActor
    func legacyResultsJSONMigration() throws {
        let container = try PersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)

        let groups = [
            StoredDuplicateGroup(
                groupId: UUID(),
                groupIndex: 1,
                confidence: 0.95,
                keeperPath: "/a.jpg",
                memberPaths: ["/a.jpg", "/b.jpg"],
                mediaType: 0
            )
        ]

        let session = ScanSession(directoryPath: "/old")
        session.resultsJSON = try JSONEncoder().encode(groups)
        // No artifactPath set — legacy session
        context.insert(session)
        try context.save()

        let loaded = try session.loadGroups()
        #expect(loaded.count == 1)
        #expect(loaded[0].confidence == 0.95)
    }

    // MARK: - Content Fingerprint Tests

    // MARK: - MatchKind Resolution Tests (AD-005)

    @Test("V1 artifact without matchKind resolves to legacyUnknown")
    func v1ArtifactResolvesToLegacyUnknown() {
        let group = StoredDuplicateGroup(
            groupId: UUID(),
            confidence: 1.0,
            keeperPath: "/a.jpg",
            memberPaths: ["/a.jpg", "/b.jpg"],
            mediaType: 0
        )
        // V1 init sets matchKind = nil, schemaVersion = nil
        #expect(group.matchKind == nil)
        #expect(group.resolvedMatchKind == .legacyUnknown)
    }

    @Test(
        "V1 artifact with confidence 1.0 does NOT resolve to sha256Exact"
    )
    func v1HighConfidenceNotInferredAsExact() {
        let group = StoredDuplicateGroup(
            groupId: UUID(),
            confidence: 1.0,
            keeperPath: "/a.jpg",
            memberPaths: ["/a.jpg", "/b.jpg"],
            mediaType: 0
        )
        #expect(group.resolvedMatchKind != .sha256Exact)
        #expect(group.resolvedMatchKind == .legacyUnknown)
    }

    @Test("V2 artifact with explicit matchKind resolves correctly")
    func v2ExplicitMatchKindResolves() throws {
        // Create a V2 group by encoding with matchKind set
        let json = """
        {
            "groupId": "00000000-0000-0000-0000-000000000001",
            "groupIndex": 1,
            "confidence": 1.0,
            "keeperPath": "/a.jpg",
            "memberPaths": ["/a.jpg", "/b.jpg"],
            "memberSizes": [1000, 1000],
            "mediaType": 0,
            "schemaVersion": 2,
            "matchKind": "sha256Exact"
        }
        """
        let group = try JSONDecoder().decode(
            StoredDuplicateGroup.self, from: Data(json.utf8)
        )
        #expect(group.resolvedMatchKind == .sha256Exact)

        // Also test perceptual
        let json2 = json.replacingOccurrences(
            of: "\"sha256Exact\"", with: "\"perceptual\""
        )
        let group2 = try JSONDecoder().decode(
            StoredDuplicateGroup.self, from: Data(json2.utf8)
        )
        #expect(group2.resolvedMatchKind == .perceptual)
    }

    @Test("Content fingerprint computed for file")
    func contentFingerprintComputed() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "deduper-fp-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )

        let file = tmp.appendingPathComponent("test.bin")
        try Data(repeating: 0xAB, count: 200_000).write(to: file)

        let fp = ContentFingerprint.compute(for: file)
        #expect(fp != nil)
        #expect(fp!.count == 64) // SHA256 hex = 64 chars
    }

    @Test("Content fingerprint same for identical content")
    func contentFingerprintIdentical() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "deduper-fp2-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )

        let content = Data(repeating: 0xCD, count: 100_000)
        let file1 = tmp.appendingPathComponent("a.bin")
        let file2 = tmp.appendingPathComponent("b.bin")
        try content.write(to: file1)
        try content.write(to: file2)

        let fp1 = ContentFingerprint.compute(for: file1)
        let fp2 = ContentFingerprint.compute(for: file2)
        #expect(fp1 == fp2)
    }
}
