import Testing
import Foundation
@testable import DeduperKit

@Suite("HashIndexService")
struct HashIndexServiceTests {
    let hashingService = ImageHashingService()

    private func makeIndex(useBKTree: Bool = false) -> HashIndexService {
        HashIndexService(
            config: .default,
            hashingService: hashingService,
            useBKTree: useBKTree
        )
    }

    @Test("Add and query exact match")
    func addAndQueryExact() async {
        let index = makeIndex()
        let hash: UInt64 = 0xABCD_1234_5678_9012

        await index.add(
            fileId: "file1",
            hashResult: HashResult(algorithm: "dHash", hash: hash)
        )

        let result = await index.queryWithin(
            distance: 0,
            of: hash,
            algorithm: "dHash"
        )
        #expect(result.matches.count == 1)
        #expect(result.matches[0].fileId == "file1")
        #expect(result.matches[0].distance == 0)
    }

    @Test("Query with distance threshold finds near matches")
    func queryNearMatches() async {
        let index = makeIndex()
        let baseHash: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        // Flip 3 bits
        let nearHash: UInt64 = baseHash ^ 0b111

        await index.add(
            fileId: "file1",
            hashResult: HashResult(algorithm: "dHash", hash: baseHash)
        )

        let result = await index.queryWithin(
            distance: 5,
            of: nearHash,
            algorithm: "dHash"
        )
        #expect(result.matches.count == 1)
        #expect(result.matches[0].distance == 3)
    }

    @Test("Query excludes self by fileId")
    func queryExcludesSelf() async {
        let index = makeIndex()
        let hash: UInt64 = 42

        await index.add(
            fileId: "file1",
            hashResult: HashResult(algorithm: "dHash", hash: hash)
        )

        let result = await index.queryWithin(
            distance: 0,
            of: hash,
            algorithm: "dHash",
            excludeFileId: "file1"
        )
        #expect(result.matches.isEmpty)
    }

    @Test("Query filters by algorithm")
    func queryFiltersByAlgorithm() async {
        let index = makeIndex()
        let hash: UInt64 = 99

        await index.add(
            fileId: "file1",
            hashResult: HashResult(algorithm: "pHash", hash: hash)
        )

        let result = await index.queryWithin(
            distance: 0,
            of: hash,
            algorithm: "dHash"
        )
        #expect(result.matches.isEmpty)
    }

    @Test("Far-apart hashes are not matched")
    func farApartNotMatched() async {
        let index = makeIndex()

        await index.add(
            fileId: "file1",
            hashResult: HashResult(algorithm: "dHash", hash: 0)
        )

        let result = await index.queryWithin(
            distance: 5,
            of: UInt64.max,
            algorithm: "dHash"
        )
        #expect(result.matches.isEmpty)
    }

    @Test("Bulk add and query multiple results")
    func bulkAddAndQuery() async {
        let index = makeIndex()
        let baseHash: UInt64 = 0x1000

        for i in 0..<10 {
            await index.add(
                fileId: "file\(i)",
                hashResult: HashResult(
                    algorithm: "dHash",
                    hash: baseHash ^ UInt64(i % 4)
                )
            )
        }

        let result = await index.queryWithin(
            distance: 3,
            of: baseHash,
            algorithm: "dHash"
        )
        // All 10 entries have distance 0-2 from baseHash
        #expect(result.matches.count == 10)
    }

    @Test("Remove entry removes from index")
    func removeEntry() async {
        let index = makeIndex()

        await index.add(
            fileId: "file1",
            hashResult: HashResult(algorithm: "dHash", hash: 42)
        )
        await index.remove(fileId: "file1")

        let count = await index.count()
        #expect(count == 0)
    }

    @Test("Clear removes all entries")
    func clearAll() async {
        let index = makeIndex()

        await index.add(
            fileId: "a",
            hashResult: HashResult(algorithm: "dHash", hash: 1)
        )
        await index.add(
            fileId: "b",
            hashResult: HashResult(algorithm: "dHash", hash: 2)
        )
        await index.clear()

        let count = await index.count()
        #expect(count == 0)
    }

    @Test("Batch query returns same results as individual queries")
    func batchQuerySameResults() async {
        let index = makeIndex()
        let hashes: [UInt64] = [100, 103, 200, 300]
        for (i, hash) in hashes.enumerated() {
            await index.add(
                fileId: "file\(i)",
                hashResult: HashResult(
                    algorithm: "dHash", hash: hash
                )
            )
        }

        // Individual queries
        let result0 = await index.queryWithin(
            distance: 5, of: 100, algorithm: "dHash",
            excludeFileId: "file0"
        )
        let result1 = await index.queryWithin(
            distance: 5, of: 200, algorithm: "dHash",
            excludeFileId: "file2"
        )

        // Batch query
        let batchResults = await index.batchQuery(queries: [
            (hash: 100, algorithm: "dHash",
             excludeFileId: "file0", maxDistance: 5),
            (hash: 200, algorithm: "dHash",
             excludeFileId: "file2", maxDistance: 5)
        ])

        #expect(batchResults.count == 2)
        #expect(
            batchResults[0].count == result0.matches.count
        )
        #expect(
            batchResults[1].count == result1.matches.count
        )
    }

    @Test("HashMatch confidence calculation")
    func hashMatchConfidence() {
        let exact = HashMatch(
            fileId: "a", algorithm: "dHash",
            hash: 0, distance: 0, width: 0, height: 0
        )
        #expect(exact.confidence == 1.0)
        #expect(exact.isExactDuplicate)

        let near = HashMatch(
            fileId: "b", algorithm: "dHash",
            hash: 0, distance: 5, width: 0, height: 0
        )
        #expect(near.confidence > 0.9)
        #expect(near.isNearDuplicate)

        let far = HashMatch(
            fileId: "c", algorithm: "dHash",
            hash: 0, distance: 32, width: 0, height: 0
        )
        #expect(far.confidence == 0.5)
        #expect(!far.isNearDuplicate)
    }
}
