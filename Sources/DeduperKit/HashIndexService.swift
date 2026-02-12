import Foundation
import os

// MARK: - HashResult (input type for indexing)

public struct HashResult: Sendable, Equatable {
    public let algorithm: String
    public let hash: UInt64
    public let width: Int
    public let height: Int

    public init(algorithm: String, hash: UInt64, width: Int = 0, height: Int = 0) {
        self.algorithm = algorithm
        self.hash = hash
        self.width = width
        self.height = height
    }

    public init(from imageHash: ImageHashResult, width: Int = 0, height: Int = 0) {
        self.algorithm = imageHash.algorithm.rawValue
        self.hash = imageHash.hash
        self.width = width
        self.height = height
    }
}

// MARK: - HashIndexEntry

private struct HashIndexEntry {
    let fileId: String
    let algorithm: String
    let hash: UInt64
    let width: Int
    let height: Int
    let computedAt: Date
}

// MARK: - HashMatch

public struct HashMatch: Sendable, Equatable {
    public let fileId: String
    public let algorithm: String
    public let hash: UInt64
    public let distance: Int
    public let width: Int
    public let height: Int

    public var confidence: Double {
        // Hamming distance of 0 = perfect match (1.0)
        // Max meaningful distance for a 64-bit hash is 64
        max(0.0, 1.0 - Double(distance) / 64.0)
    }

    public var isExactDuplicate: Bool {
        distance == 0
    }

    public var isNearDuplicate: Bool {
        distance > 0 && distance <= 10
    }
}

// MARK: - HashIndexStatistics

public struct HashIndexStatistics: Sendable {
    public let totalEntries: Int
    public let entriesByAlgorithm: [String: Int]
    public let averageDistances: [String: Double]
}

// MARK: - BKTreeSearchResult

public struct BKTreeSearchResult: Sendable {
    public let matches: [HashMatch]
    public let visitedNodeCount: Int
}

// MARK: - HashIndexService

public actor HashIndexService {
    private let logger = Logger(subsystem: "app.deduper", category: "hash")
    private let config: HashingConfig
    private let hashingService: ImageHashingService
    private var entries: [HashIndexEntry] = []
    private var bkTree: BKTree?
    private let useBKTree: Bool
    private let bkTreeThreshold: Int = 1000

    public init(config: HashingConfig, hashingService: ImageHashingService, useBKTree: Bool = true) {
        self.config = config
        self.hashingService = hashingService
        self.useBKTree = useBKTree
    }

    // MARK: - Factory

    public static func optimizedForLargeDataset(
        config: HashingConfig,
        hashingService: ImageHashingService
    ) -> HashIndexService {
        HashIndexService(config: config, hashingService: hashingService, useBKTree: true)
    }

    // MARK: - Mutation

    public func add(fileId: String, hashResult: HashResult) {
        let entry = HashIndexEntry(
            fileId: fileId,
            algorithm: hashResult.algorithm,
            hash: hashResult.hash,
            width: hashResult.width,
            height: hashResult.height,
            computedAt: Date()
        )
        entries.append(entry)

        if useBKTree {
            if bkTree == nil && entries.count >= bkTreeThreshold {
                rebuildBKTree()
            } else if let tree = bkTree {
                tree.insert(entry: entry)
            }
        }

        logger.debug("Added hash entry for file \(fileId), algorithm=\(hashResult.algorithm)")
    }

    public func add(fileId: String, hashResults: [HashResult]) {
        for result in hashResults {
            let entry = HashIndexEntry(
                fileId: fileId,
                algorithm: result.algorithm,
                hash: result.hash,
                width: result.width,
                height: result.height,
                computedAt: Date()
            )
            entries.append(entry)
        }

        if useBKTree {
            if bkTree == nil && entries.count >= bkTreeThreshold {
                rebuildBKTree()
            } else if let tree = bkTree {
                for result in hashResults {
                    let entry = HashIndexEntry(
                        fileId: fileId,
                        algorithm: result.algorithm,
                        hash: result.hash,
                        width: result.width,
                        height: result.height,
                        computedAt: Date()
                    )
                    tree.insert(entry: entry)
                }
            }
        }

        logger.debug("Bulk-added \(hashResults.count) hash entries for file \(fileId)")
    }

    public func remove(fileId: String) {
        entries.removeAll { $0.fileId == fileId }

        // BK-trees don't support efficient deletion; rebuild if active
        if bkTree != nil {
            rebuildBKTree()
        }

        logger.debug("Removed hash entries for file \(fileId)")
    }

    public func clear() {
        entries.removeAll()
        bkTree = nil
        logger.debug("Cleared all hash index entries")
    }

    // MARK: - Query

    public func queryWithin(
        distance maxDistance: Int,
        of hash: UInt64,
        algorithm: String,
        excludeFileId: String? = nil
    ) -> BKTreeSearchResult {
        if let tree = bkTree {
            return searchWithBKTree(tree: tree, hash: hash, maxDistance: maxDistance, algorithm: algorithm, excludeFileId: excludeFileId)
        } else {
            let matches = linearScan(hash: hash, maxDistance: maxDistance, algorithm: algorithm, excludeFileId: excludeFileId)
            return BKTreeSearchResult(matches: matches, visitedNodeCount: entries.count)
        }
    }

    public func findExactMatches(
        for hash: UInt64,
        algorithm: String,
        excludeFileId: String? = nil
    ) -> [HashMatch] {
        let result = queryWithin(distance: 0, of: hash, algorithm: algorithm, excludeFileId: excludeFileId)
        return result.matches
    }

    public func findNearDuplicates(
        for hash: UInt64,
        algorithm: String,
        excludeFileId: String? = nil
    ) -> [HashMatch] {
        let result = queryWithin(distance: 10, of: hash, algorithm: algorithm, excludeFileId: excludeFileId)
        return result.matches.filter { $0.distance > 0 }
    }

    public func count() -> Int {
        entries.count
    }

    // MARK: - Private Helpers

    private func searchWithBKTree(
        tree: BKTree,
        hash: UInt64,
        maxDistance: Int,
        algorithm: String,
        excludeFileId: String?
    ) -> BKTreeSearchResult {
        let (candidates, visitedCount) = tree.search(hash: hash, maxDistance: maxDistance)

        let matches = candidates.compactMap { entry -> HashMatch? in
            guard entry.algorithm == algorithm else { return nil }
            if let excludeId = excludeFileId, entry.fileId == excludeId { return nil }

            let dist = hashingService.hammingDistance(entry.hash, hash)
            guard dist <= maxDistance else { return nil }

            return HashMatch(
                fileId: entry.fileId,
                algorithm: entry.algorithm,
                hash: entry.hash,
                distance: dist,
                width: entry.width,
                height: entry.height
            )
        }

        return BKTreeSearchResult(matches: matches, visitedNodeCount: visitedCount)
    }

    private func linearScan(
        hash: UInt64,
        maxDistance: Int,
        algorithm: String,
        excludeFileId: String?
    ) -> [HashMatch] {
        var matches: [HashMatch] = []

        for entry in entries {
            guard entry.algorithm == algorithm else { continue }
            if let excludeId = excludeFileId, entry.fileId == excludeId { continue }

            let dist = hashingService.hammingDistance(entry.hash, hash)
            guard dist <= maxDistance else { continue }

            matches.append(HashMatch(
                fileId: entry.fileId,
                algorithm: entry.algorithm,
                hash: entry.hash,
                distance: dist,
                width: entry.width,
                height: entry.height
            ))
        }

        return matches
    }

    private func rebuildBKTree() {
        let tree = BKTree(hashingService: hashingService)
        for entry in entries {
            tree.insert(entry: entry)
        }
        bkTree = tree
        logger.debug("Rebuilt BK-tree with \(self.entries.count) entries")
    }
}

// MARK: - BKTree

private class BKTree {
    private var root: BKNode?
    private let hashingService: ImageHashingService
    private var nodeCount: Int = 0

    init(hashingService: ImageHashingService) {
        self.hashingService = hashingService
    }

    func insert(entry: HashIndexEntry) {
        let newNode = BKNode(entry: entry)

        guard let root = root else {
            self.root = newNode
            nodeCount = 1
            return
        }

        var current = root
        while true {
            let dist = hashingService.hammingDistance(current.entry.hash, entry.hash)
            if let child = current.children[dist] {
                current = child
            } else {
                current.children[dist] = newNode
                nodeCount += 1
                return
            }
        }
    }

    func search(hash: UInt64, maxDistance: Int) -> (entries: [HashIndexEntry], visitedCount: Int) {
        guard let root = root else {
            return ([], 0)
        }

        var results: [HashIndexEntry] = []
        var visited = 0
        var stack: [BKNode] = [root]

        while let node = stack.popLast() {
            visited += 1

            let dist = hashingService.hammingDistance(node.entry.hash, hash)
            if dist <= maxDistance {
                results.append(node.entry)
            }

            // Triangle inequality pruning: only visit children
            // whose distance key is in [dist - maxDistance, dist + maxDistance]
            let lower = dist - maxDistance
            let upper = dist + maxDistance

            for (childDist, childNode) in node.children {
                if childDist >= lower && childDist <= upper {
                    stack.append(childNode)
                }
            }
        }

        return (results, visited)
    }

    func count() -> Int {
        nodeCount
    }

    func clear() {
        root = nil
        nodeCount = 0
    }

    // MARK: - BKNode

    private class BKNode {
        let entry: HashIndexEntry
        var children: [Int: BKNode] = [:]

        init(entry: HashIndexEntry) {
            self.entry = entry
        }
    }
}
