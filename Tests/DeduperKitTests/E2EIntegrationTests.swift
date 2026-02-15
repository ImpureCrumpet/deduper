import Testing
import Foundation
import SwiftData
@testable import DeduperKit

@Suite("E2E Integration")
struct E2EIntegrationTests {

    private let fixturesURL: URL = {
        // Find Fixtures directory relative to test source file
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    private func makeTempDir() throws -> URL {
        // Use home directory to avoid /private/var protected path check
        let tmp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".deduper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func copyFixture(
        _ name: String, to dir: URL, as newName: String? = nil
    ) throws -> URL {
        let src = fixturesURL.appendingPathComponent(name)
        let dst = dir.appendingPathComponent(newName ?? name)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
    }

    // MARK: - Full lifecycle: scan → persist → show → merge → undo

    @Test("Full scan-detect-persist-merge-undo lifecycle")
    func fullLifecycle() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Copy fixtures: an exact duplicate pair + a non-duplicate
        _ = try copyFixture("dup-original.png", to: dir)
        _ = try copyFixture("dup-original.png", to: dir, as: "dup-copy.png")
        let unique = try copyFixture("screenshot-a.png", to: dir)

        // Step 1: Scan
        let scanner = ScanService()
        var files: [ScannedFile] = []
        for try await event in scanner.scan(directory: dir) {
            if case .item(let f) = event { files.append(f) }
        }
        #expect(files.count == 3)

        // Step 2: Detect
        let detector = DetectionService()
        let groups = try await detector.detectDuplicates(in: files)

        // Should find the exact duplicate pair
        #expect(groups.count >= 1)
        let exactGroup = groups.first { $0.confidence == 1.0 }
        #expect(exactGroup != nil)
        #expect(exactGroup!.members.count == 2)

        // Step 3: Persist session
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let sessionId = try await persistSession(
            container: container,
            directory: dir,
            files: files,
            groups: groups
        )

        // Step 4: Verify session is recoverable
        let storedGroups = try await fetchStoredGroups(
            container: container, sessionId: sessionId
        )
        #expect(storedGroups != nil)
        #expect(storedGroups!.count == groups.count)

        // Step 5: Merge (only the exact match group)
        let mergeDir = dir.appendingPathComponent(".deduper-transactions")
        let merger = MergeService()

        // Find which path is not the keeper
        let keeper = storedGroups![0].keeperPath
        let toTrash = storedGroups![0].memberPaths
            .filter { $0 != keeper }
            .map { URL(fileURLWithPath: $0) }

        #expect(!toTrash.isEmpty)
        let transaction = try merger.moveToTrash(
            files: toTrash, logDirectory: mergeDir
        )
        #expect(transaction.filesMoved == toTrash.count)
        #expect(transaction.errorCount == 0)

        // Verify trashed file is gone
        for url in toTrash {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        // Keeper and unique still exist
        #expect(FileManager.default.fileExists(atPath: unique.path))

        // Step 6: Undo
        let failures = merger.undo(transaction: transaction)
        #expect(failures.isEmpty)

        // Verify restored
        for url in toTrash {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Selective group filtering by index")
    func selectiveGroupFilter() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create two pairs of exact duplicates
        _ = try copyFixture("dup-original.png", to: dir, as: "a1.png")
        _ = try copyFixture("dup-original.png", to: dir, as: "a2.png")
        _ = try copyFixture("screenshot-a.png", to: dir, as: "b1.png")
        _ = try copyFixture("screenshot-a.png", to: dir, as: "b2.png")

        let scanner = ScanService()
        var files: [ScannedFile] = []
        for try await event in scanner.scan(directory: dir) {
            if case .item(let f) = event { files.append(f) }
        }
        #expect(files.count == 4)

        let detector = DetectionService()
        let groups = try await detector.detectDuplicates(in: files)

        // Should find 2 exact groups
        #expect(groups.count >= 2)

        // Assign indices
        let storedGroups = groups.enumerated().map { (i, group) in
            let fileMap = Dictionary(
                uniqueKeysWithValues: files.map { ($0.id, $0.url) }
            )
            return StoredDuplicateGroup(
                from: group, fileMap: fileMap, index: i + 1
            )
        }

        // Filter to only group 1
        let filtered = storedGroups.filter { $0.groupIndex == 1 }
        #expect(filtered.count == 1)

        // Filter to skip group 1
        let remaining = storedGroups.filter { $0.groupIndex != 1 }
        #expect(remaining.count == storedGroups.count - 1)
    }

    @Test("MergeService undo restores trashed files")
    func mergeUndoRestoresFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create test files
        let file1 = dir.appendingPathComponent("trash-me-1.txt")
        let file2 = dir.appendingPathComponent("trash-me-2.txt")
        try Data("content 1".utf8).write(to: file1)
        try Data("content 2".utf8).write(to: file2)

        let logDir = dir.appendingPathComponent(".transactions")
        let merger = MergeService()

        // Trash them
        let transaction = try merger.moveToTrash(
            files: [file1, file2], logDirectory: logDir
        )
        #expect(transaction.filesMoved == 2)
        #expect(!FileManager.default.fileExists(atPath: file1.path))
        #expect(!FileManager.default.fileExists(atPath: file2.path))

        // Undo
        let failures = merger.undo(transaction: transaction)
        #expect(failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file1.path))
        #expect(FileManager.default.fileExists(atPath: file2.path))

        // Verify content preserved
        let restored1 = try String(contentsOf: file1, encoding: .utf8)
        let restored2 = try String(contentsOf: file2, encoding: .utf8)
        #expect(restored1 == "content 1")
        #expect(restored2 == "content 2")
    }

    @Test("Transaction list shows recent transactions")
    func transactionList() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file = dir.appendingPathComponent("temp.txt")
        try Data("x".utf8).write(to: file)

        let logDir = dir.appendingPathComponent(".transactions")
        let merger = MergeService()

        _ = try merger.moveToTrash(
            files: [file], logDirectory: logDir
        )

        let transactions = try merger.listTransactions(
            logDirectory: logDir
        )
        #expect(transactions.count == 1)
        #expect(transactions[0].filesMoved == 1)
    }

    @Test("Session deletion removes from SwiftData")
    @MainActor
    func sessionDeletion() throws {
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let session = ScanSession(
            directoryPath: "/tmp/test-delete",
            totalFiles: 10,
            mediaFiles: 5,
            duplicateGroups: 1
        )
        context.insert(session)
        try context.save()

        let sessionId = session.sessionId

        // Verify it exists
        let predicate = #Predicate<ScanSession> {
            $0.sessionId == sessionId
        }
        var desc = FetchDescriptor<ScanSession>(predicate: predicate)
        desc.fetchLimit = 1
        let before = try context.fetch(desc)
        #expect(before.count == 1)

        // Delete it
        context.delete(before[0])
        try context.save()

        // Verify it's gone
        let after = try context.fetch(desc)
        #expect(after.isEmpty)
    }

    // MARK: - Helpers

    @MainActor
    private func persistSession(
        container: ModelContainer,
        directory: URL,
        files: [ScannedFile],
        groups: [DuplicateGroupResult]
    ) throws -> UUID {
        let context = ModelContext(container)
        let fileURLMap = Dictionary(
            uniqueKeysWithValues: files.map { ($0.id, $0.url) }
        )

        let session = ScanSession(
            directoryPath: directory.path,
            totalFiles: files.count,
            mediaFiles: files.count,
            duplicateGroups: groups.count
        )
        session.completedAt = Date()

        let storedGroups = groups.enumerated().map { (i, group) in
            StoredDuplicateGroup(
                from: group, fileMap: fileURLMap, index: i + 1
            )
        }
        session.resultsJSON = try JSONEncoder().encode(storedGroups)

        context.insert(session)
        try context.save()

        return session.sessionId
    }

    @MainActor
    private func fetchStoredGroups(
        container: ModelContainer,
        sessionId: UUID
    ) throws -> [StoredDuplicateGroup]? {
        let context = ModelContext(container)
        let predicate = #Predicate<ScanSession> {
            $0.sessionId == sessionId
        }
        var descriptor = FetchDescriptor<ScanSession>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let session = try context.fetch(descriptor).first,
              let data = session.resultsJSON else {
            return nil
        }
        return try JSONDecoder().decode(
            [StoredDuplicateGroup].self, from: data
        )
    }
}
