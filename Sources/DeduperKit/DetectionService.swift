import Foundation
import os
import CryptoKit

/// Orchestrates the duplicate detection pipeline:
/// scan files -> compute hashes -> index -> compare -> group.
public struct DetectionService: Sendable {
    private let logger = Logger(subsystem: "app.deduper", category: "detect")
    private let imageHasher: ImageHashingService
    private let videoFingerprinter: VideoFingerprinter
    private let metadataService: MetadataService
    private let hashCache: HashCacheService?

    public init(
        imageHasher: ImageHashingService = ImageHashingService(),
        videoFingerprinter: VideoFingerprinter = VideoFingerprinter(),
        metadataService: MetadataService = MetadataService(),
        hashCache: HashCacheService? = nil
    ) {
        self.imageHasher = imageHasher
        self.videoFingerprinter = videoFingerprinter
        self.metadataService = metadataService
        self.hashCache = hashCache
    }

    /// Detect duplicates among a set of scanned files.
    public func detectDuplicates(
        in files: [ScannedFile],
        options: DetectOptions = DetectOptions()
    ) async throws -> [DuplicateGroupResult] {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Fast first pass: SHA256 exact-match detection
        let (exactGroups, remainingFiles) = await detectExactDuplicates(
            in: files, options: options
        )

        // Separate remaining files by media type for perceptual detection
        let photos = remainingFiles.filter { $0.mediaType == .photo }
        let videos = remainingFiles.filter { $0.mediaType == .video }

        // Process in parallel
        async let photoGroups = detectImageDuplicates(
            photos,
            options: options
        )
        async let videoGroups = detectVideoDuplicates(
            videos,
            options: options
        )

        var results = exactGroups
            + (try await photoGroups)
            + (try await videoGroups)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let elapsedStr = String(format: "%.2f", elapsed)
        let exactCount = exactGroups.count
        logger.info(
            "Detection complete: \(results.count) groups (\(exactCount) exact) in \(elapsedStr)s"
        )

        results.sort { $0.confidence > $1.confidence }
        return results
    }

    // MARK: - SHA256 Exact-Match Detection

    /// Fast first pass: group files with identical SHA256 checksums.
    /// Returns exact-match groups and files that need perceptual analysis.
    private func detectExactDuplicates(
        in files: [ScannedFile],
        options: DetectOptions
    ) async -> ([DuplicateGroupResult], [ScannedFile]) {
        guard files.count >= 2 else { return ([], files) }

        // Compute SHA256 with bounded concurrency
        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
        var fileDigests: [(ScannedFile, String)] = []

        await withTaskGroup(
            of: (ScannedFile, String?).self
        ) { group in
            var iterator = files.makeIterator()

            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask {
                    let digest = Self.sha256(of: file.url)
                    return (file, digest)
                }
                return true
            }

            for _ in 0..<min(maxConcurrency, files.count) {
                _ = addNext()
            }

            for await (file, digest) in group {
                if let digest {
                    fileDigests.append((file, digest))
                }
                _ = addNext()
            }
        }

        // Group by SHA256
        var digestBuckets: [String: [ScannedFile]] = [:]
        for (file, digest) in fileDigests {
            digestBuckets[digest, default: []].append(file)
        }

        var exactGroups: [DuplicateGroupResult] = []
        var matchedIds = Set<UUID>()

        for (digest, bucket) in digestBuckets where bucket.count >= 2 {
            let members = bucket.map { file in
                DuplicateGroupMember(
                    fileId: file.id,
                    confidence: 1.0,
                    signals: [
                        ConfidenceSignal(
                            key: "checksum",
                            weight: options.weights.checksum,
                            rawScore: 1.0,
                            contribution: options.weights.checksum,
                            rationale: "SHA256 exact match: \(digest.prefix(12))…"
                        )
                    ],
                    penalties: [],
                    rationale: ["Byte-identical (SHA256)"],
                    fileSize: file.fileSize
                )
            }

            // Keeper: largest file (they're identical, so pick by metadata)
            let keeper = bucket.max(by: {
                $0.fileSize < $1.fileSize
            })?.id

            let mediaType = bucket.first?.mediaType ?? .photo

            exactGroups.append(DuplicateGroupResult(
                groupId: UUID(),
                members: members,
                confidence: 1.0,
                rationaleLines: ["Byte-identical files (SHA256)"],
                keeperSuggestion: keeper,
                incomplete: false,
                mediaType: mediaType
            ))

            for file in bucket {
                matchedIds.insert(file.id)
            }
        }

        // Return files not in any exact group for perceptual analysis
        let remaining = files.filter { !matchedIds.contains($0.id) }
        return (exactGroups, remaining)
    }

    /// Get file modification date.
    private static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Compute SHA256 digest of a file, reading in chunks.
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1 MB
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: chunkSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Image Duplicate Detection

    private func detectImageDuplicates(
        _ files: [ScannedFile],
        options: DetectOptions
    ) async throws -> [DuplicateGroupResult] {
        guard files.count >= 2 else { return [] }

        let hashIndex = HashIndexService(
            config: .default,
            hashingService: imageHasher
        )

        // Compute hashes with bounded concurrency (cache-aware)
        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
        var hashedFiles: [(ScannedFile, [ImageHashResult])] = []

        await withTaskGroup(
            of: (ScannedFile, [ImageHashResult]).self
        ) { group in
            var iterator = files.makeIterator()

            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask { [hashCache, imageHasher] in
                    // Check cache first
                    if let cache = hashCache {
                        let mtime = Self.modificationDate(of: file.url)
                        if let cached = await cache.lookup(
                            path: file.url.path,
                            fileSize: file.fileSize,
                            modifiedAt: mtime
                        ) {
                            let results = cached.map {
                                ImageHashResult(
                                    algorithm: HashAlgorithm(
                                        rawValue: $0.algorithm
                                    ) ?? .pHash,
                                    hash: $0.hash
                                )
                            }
                            return (file, results)
                        }
                    }

                    // Cache miss — compute fresh
                    let hashes = imageHasher.computeHashes(
                        for: file.url
                    )

                    // Store in cache
                    if let cache = hashCache {
                        let mtime = Self.modificationDate(of: file.url)
                        await cache.store(
                            path: file.url.path,
                            fileSize: file.fileSize,
                            modifiedAt: mtime,
                            hashes: hashes.map {
                                (algorithm: $0.algorithm.rawValue,
                                 hash: $0.hash)
                            }
                        )
                    }

                    return (file, hashes)
                }
                return true
            }

            for _ in 0..<min(maxConcurrency, files.count) {
                _ = addNext()
            }

            for await result in group {
                hashedFiles.append(result)
                _ = addNext()
            }
        }


        // Insert into index
        for (file, hashes) in hashedFiles {
            let hashResults = hashes.map { HashResult(from: $0) }
            await hashIndex.add(
                fileId: file.id.uuidString,
                hashResults: hashResults
            )
        }

        // Find similar pairs using the index
        let threshold = options.thresholds.imageDistance
        var unionFind = UnionFind<UUID>()
        // Track best hash distance per pair for confidence scoring
        var pairDistances: [AssetPair: Int] = [:]

        let fileMap = Dictionary(
            uniqueKeysWithValues: hashedFiles.map {
                ($0.0.id, ($0.0, $0.1))
            }
        )

        for (file, hashes) in hashedFiles {
            for hash in hashes {
                let matches = await hashIndex.queryWithin(
                    distance: threshold,
                    of: hash.hash,
                    algorithm: hash.algorithm.rawValue,
                    excludeFileId: file.id.uuidString
                )
                for match in matches.matches {
                    guard let matchId = UUID(
                        uuidString: match.fileId
                    ) else { continue }
                    unionFind.union(file.id, matchId)
                    let pair = AssetPair(file.id, matchId)
                    let existing = pairDistances[pair] ?? Int.max
                    pairDistances[pair] = min(existing, match.distance)
                }
            }
        }

        // Gather metadata for all files in groups (only for grouped files)
        let groupedIds = Set(unionFind.allGroups().flatMap { $0 })
        let metadataMap = await fetchMetadata(
            for: groupedIds, fileMap: fileMap
        )

        // Refine groups: split over-chained transitive clusters
        let rawGroups = unionFind.allGroups()
        let refinedGroups = rawGroups.flatMap { memberIds in
            Self.refineGroup(
                memberIds,
                pairDistances: pairDistances,
                threshold: threshold
            )
        }

        // Build results from refined groups
        return refinedGroups.compactMap { memberIds -> DuplicateGroupResult? in
            guard memberIds.count >= 2 else { return nil }

            let members = memberIds.compactMap {
                id -> DuplicateGroupMember? in
                guard let (file, _) = fileMap[id] else { return nil }
                let meta = metadataMap[id]

                let signals = buildImageSignals(
                    fileId: id,
                    pairDistances: pairDistances,
                    allIds: memberIds,
                    metadata: meta,
                    options: options
                )
                let totalConfidence = signals.reduce(0.0) {
                    $0 + $1.contribution
                }
                let clampedConfidence = min(1.0, max(0.0, totalConfidence))

                return DuplicateGroupMember(
                    fileId: id,
                    confidence: clampedConfidence,
                    signals: signals,
                    penalties: [],
                    rationale: signals.map(\.rationale),
                    fileSize: file.fileSize
                )
            }

            guard members.count >= 2 else { return nil }

            let avgConfidence = members.reduce(0.0) {
                $0 + $1.confidence
            } / Double(members.count)

            let keeper = selectKeeper(
                members: members,
                metadataMap: metadataMap
            )

            return DuplicateGroupResult(
                groupId: UUID(),
                members: members,
                confidence: avgConfidence,
                rationaleLines: [
                    "Perceptual hash match within threshold"
                ],
                keeperSuggestion: keeper,
                incomplete: false,
                mediaType: .photo
            )
        }
    }

    // MARK: - Video Duplicate Detection

    private func detectVideoDuplicates(
        _ files: [ScannedFile],
        options: DetectOptions
    ) async throws -> [DuplicateGroupResult] {
        guard files.count >= 2 else { return [] }

        var signatures: [(ScannedFile, VideoSignature)] = []

        for file in files {
            if let sig = await videoFingerprinter.fingerprint(
                url: file.url
            ) {
                signatures.append((file, sig))
            }
        }

        guard signatures.count >= 2 else { return [] }

        var unionFind = UnionFind<UUID>()
        var verdicts: [AssetPair: VideoSimilarity] = [:]
        let comparisonOptions = VideoComparisonOptions(
            perFrameMatchThreshold: options.thresholds.videoFrameDistance
        )

        for i in 0..<signatures.count {
            for j in (i + 1)..<signatures.count {
                let similarity = videoFingerprinter.compare(
                    signatures[i].1,
                    signatures[j].1,
                    options: comparisonOptions
                )
                if similarity.verdict == .duplicate
                    || similarity.verdict == .similar {
                    let idA = signatures[i].0.id
                    let idB = signatures[j].0.id
                    unionFind.union(idA, idB)
                    verdicts[AssetPair(idA, idB)] = similarity
                }
            }
        }

        let sigMap = Dictionary(
            uniqueKeysWithValues: signatures.map { ($0.0.id, $0) }
        )

        // Fetch metadata for grouped videos
        let groupedIds = Set(unionFind.allGroups().flatMap { $0 })
        let fileMap = Dictionary(
            uniqueKeysWithValues: signatures.map {
                ($0.0.id, ($0.0, [ImageHashResult]()))
            }
        )
        let metadataMap = await fetchMetadata(
            for: groupedIds, fileMap: fileMap
        )

        let groups = unionFind.allGroups()

        return groups.compactMap { memberIds -> DuplicateGroupResult? in
            guard memberIds.count >= 2 else { return nil }

            let members = memberIds.compactMap {
                id -> DuplicateGroupMember? in
                guard let (file, _) = sigMap[id] else { return nil }
                let meta = metadataMap[id]

                let signals = buildVideoSignals(
                    fileId: id,
                    verdicts: verdicts,
                    allIds: memberIds,
                    metadata: meta
                )
                let totalConfidence = signals.reduce(0.0) {
                    $0 + $1.contribution
                }
                let clampedConfidence = min(
                    1.0, max(0.0, totalConfidence)
                )

                return DuplicateGroupMember(
                    fileId: id,
                    confidence: clampedConfidence,
                    signals: signals,
                    penalties: [],
                    rationale: signals.map(\.rationale),
                    fileSize: file.fileSize
                )
            }

            guard members.count >= 2 else { return nil }
            let avgConfidence = members.reduce(0.0) {
                $0 + $1.confidence
            } / Double(members.count)

            let keeper = selectKeeper(
                members: members,
                metadataMap: metadataMap
            )

            return DuplicateGroupResult(
                groupId: UUID(),
                members: members,
                confidence: avgConfidence,
                rationaleLines: [
                    "Video frame fingerprint similarity"
                ],
                keeperSuggestion: keeper,
                incomplete: false,
                mediaType: .video
            )
        }
    }

    // MARK: - Group Refinement

    /// Split an over-chained Union-Find group into validated sub-groups.
    ///
    /// The transitive closure problem: Union-Find chains A→B→C even when
    /// A and C are very different. This method uses a stricter adjacency
    /// graph with tighter thresholds and density requirements.
    private static func refineGroup(
        _ memberIds: [UUID],
        pairDistances: [AssetPair: Int],
        threshold: Int
    ) -> [[UUID]] {
        // Small groups don't need refinement
        guard memberIds.count > 3 else { return [memberIds] }

        // Use a stricter threshold for group membership validation:
        // pairs must be within 60% of the BK-tree query threshold
        let strictThreshold = max(1, threshold * 6 / 10)

        // Build adjacency with the strict threshold
        var adjacency: [UUID: Set<UUID>] = [:]
        for id in memberIds {
            adjacency[id] = []
        }

        for i in 0..<memberIds.count {
            for j in (i + 1)..<memberIds.count {
                let a = memberIds[i]
                let b = memberIds[j]
                let pair = AssetPair(a, b)
                if let dist = pairDistances[pair], dist <= strictThreshold {
                    adjacency[a, default: []].insert(b)
                    adjacency[b, default: []].insert(a)
                }
            }
        }

        // Find connected components on the strict adjacency graph
        var visited = Set<UUID>()
        var components: [[UUID]] = []

        let nodesWithEdges = memberIds.filter {
            !(adjacency[$0]?.isEmpty ?? true)
        }

        for node in nodesWithEdges {
            guard !visited.contains(node) else { continue }
            var component: [UUID] = []
            var queue: [UUID] = [node]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard !visited.contains(current) else { continue }
                visited.insert(current)
                component.append(current)
                for neighbor in adjacency[current] ?? [] {
                    if !visited.contains(neighbor) {
                        queue.append(neighbor)
                    }
                }
            }
            components.append(component)
        }

        // For each component, verify density: average pairwise distance
        // should be below 50% of the original threshold
        let maxAvgDistance = Double(threshold) * 0.5
        var result: [[UUID]] = []

        for component in components {
            guard component.count >= 2 else { continue }

            if component.count <= 4 {
                // Small components are fine
                result.append(component)
                continue
            }

            // Check average pairwise distance
            var totalDist = 0.0
            var pairCount = 0
            for i in 0..<component.count {
                for j in (i + 1)..<component.count {
                    let pair = AssetPair(component[i], component[j])
                    if let dist = pairDistances[pair] {
                        totalDist += Double(dist)
                        pairCount += 1
                    }
                }
            }

            if pairCount > 0 {
                let avgDist = totalDist / Double(pairCount)
                if avgDist <= maxAvgDistance {
                    result.append(component)
                } else {
                    // Too loose — extract only tight pairs
                    let tight = extractTightPairs(
                        from: component,
                        pairDistances: pairDistances,
                        threshold: strictThreshold
                    )
                    result.append(contentsOf: tight)
                }
            } else {
                result.append(component)
            }
        }

        return result.isEmpty ? [] : result
    }

    /// Extract tight clusters from a loose group by keeping only pairs
    /// where both members are strongly connected.
    private static func extractTightPairs(
        from ids: [UUID],
        pairDistances: [AssetPair: Int],
        threshold: Int
    ) -> [[UUID]] {
        // Use an even tighter threshold (half of the strict threshold)
        let tightThreshold = max(1, threshold / 2)

        var tightUF = UnionFind<UUID>()
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let pair = AssetPair(ids[i], ids[j])
                if let dist = pairDistances[pair],
                   dist <= tightThreshold {
                    tightUF.union(ids[i], ids[j])
                }
            }
        }

        return tightUF.allGroups().filter { $0.count >= 2 }
    }

    // MARK: - Confidence Signals

    private func buildImageSignals(
        fileId: UUID,
        pairDistances: [AssetPair: Int],
        allIds: [UUID],
        metadata: MediaMetadata?,
        options: DetectOptions
    ) -> [ConfidenceSignal] {
        var signals: [ConfidenceSignal] = []
        let weights = options.weights

        // Hash distance signal: best distance to any other member
        let bestDistance = allIds
            .filter { $0 != fileId }
            .compactMap { pairDistances[AssetPair(fileId, $0)] }
            .min() ?? Int.max

        if bestDistance < Int.max {
            let hashScore = max(
                0.0, 1.0 - Double(bestDistance) / 64.0
            )
            signals.append(ConfidenceSignal(
                key: "hash",
                weight: weights.hash,
                rawScore: hashScore,
                contribution: hashScore * weights.hash,
                rationale: "pHash distance \(bestDistance)/64"
            ))
        }

        // Metadata signals
        if let meta = metadata {
            // Name similarity signal
            let nameScore = DetectionAsset.normalizeStem(
                (meta.fileName as NSString).deletingPathExtension
            ).isEmpty ? 0.0 : 1.0
            signals.append(ConfidenceSignal(
                key: "name",
                weight: weights.name,
                rawScore: nameScore,
                contribution: nameScore * weights.name,
                rationale: "File name present"
            ))

            // Metadata completeness as a bonus signal
            let completeness = meta.completenessScore
            signals.append(ConfidenceSignal(
                key: "metadata",
                weight: weights.metadata,
                rawScore: completeness,
                contribution: completeness * weights.metadata,
                rationale: String(
                    format: "Metadata %.0f%% complete",
                    completeness * 100
                )
            ))
        }

        return signals
    }

    private func buildVideoSignals(
        fileId: UUID,
        verdicts: [AssetPair: VideoSimilarity],
        allIds: [UUID],
        metadata: MediaMetadata?
    ) -> [ConfidenceSignal] {
        var signals: [ConfidenceSignal] = []

        // Best verdict against any other member
        let bestVerdict = allIds
            .filter { $0 != fileId }
            .compactMap { verdicts[AssetPair(fileId, $0)] }
            .min(by: { ($0.averageDistance ?? 999) < ($1.averageDistance ?? 999) })

        if let verdict = bestVerdict {
            let score: Double = switch verdict.verdict {
            case .duplicate: 0.95
            case .similar: 0.75
            case .different: 0.3
            case .insufficientData: 0.1
            }
            signals.append(ConfidenceSignal(
                key: "video_fingerprint",
                weight: 0.5,
                rawScore: score,
                contribution: score * 0.5,
                rationale: "Video verdict: \(verdict.verdict)"
            ))

            // Duration match signal
            let durationScore = verdict.durationDeltaRatio < 0.02
                ? 1.0 : max(0.0, 1.0 - verdict.durationDeltaRatio)
            signals.append(ConfidenceSignal(
                key: "duration",
                weight: 0.2,
                rawScore: durationScore,
                contribution: durationScore * 0.2,
                rationale: String(
                    format: "Duration delta %.1f%%",
                    verdict.durationDeltaRatio * 100
                )
            ))
        }

        if let meta = metadata {
            signals.append(ConfidenceSignal(
                key: "metadata",
                weight: 0.1,
                rawScore: meta.completenessScore,
                contribution: meta.completenessScore * 0.1,
                rationale: String(
                    format: "Metadata %.0f%% complete",
                    meta.completenessScore * 100
                )
            ))
        }

        return signals
    }

    // MARK: - Keeper Selection

    /// Select the best file to keep from a duplicate group.
    /// Prefers: highest metadata completeness > best format > largest size.
    private func selectKeeper(
        members: [DuplicateGroupMember],
        metadataMap: [UUID: MediaMetadata]
    ) -> UUID? {
        members.max(by: { a, b in
            let metaA = metadataMap[a.fileId]
            let metaB = metadataMap[b.fileId]
            return keeperScore(meta: metaA, size: a.fileSize)
                < keeperScore(meta: metaB, size: b.fileSize)
        })?.fileId
    }

    /// Composite score for keeper selection.
    private func keeperScore(
        meta: MediaMetadata?,
        size: Int64
    ) -> Double {
        guard let meta else {
            return Double(size) / 1_000_000_000.0
        }
        // Weighted: format preference (40%) + completeness (35%)
        // + file size normalized (25%)
        let format = meta.formatPreferenceScore * 0.4
        let completeness = meta.completenessScore * 0.35
        let sizeScore = min(
            1.0, Double(size) / 50_000_000.0
        ) * 0.25
        return format + completeness + sizeScore
    }

    // MARK: - Metadata Fetching

    private func fetchMetadata(
        for ids: Set<UUID>,
        fileMap: [UUID: (ScannedFile, [ImageHashResult])]
    ) async -> [UUID: MediaMetadata] {
        var result: [UUID: MediaMetadata] = [:]

        await withTaskGroup(
            of: (UUID, MediaMetadata).self
        ) { group in
            for id in ids {
                guard let (file, _) = fileMap[id] else { continue }
                group.addTask {
                    let meta = await metadataService.extractMetadata(
                        from: file.url
                    )
                    return (id, meta)
                }
            }
            for await (id, meta) in group {
                result[id] = meta
            }
        }

        return result
    }
}

// MARK: - Union-Find

struct UnionFind<T: Hashable>: Sendable where T: Sendable {
    private var parent: [T: T] = [:]
    private var rank: [T: Int] = [:]

    mutating func find(_ x: T) -> T {
        if parent[x] == nil {
            parent[x] = x
            rank[x] = 0
        }
        var root = x
        while parent[root] != root {
            parent[root] = parent[parent[root]!]  // path compression
            root = parent[root]!
        }
        return root
    }

    mutating func union(_ x: T, _ y: T) {
        let rootX = find(x)
        let rootY = find(y)
        guard rootX != rootY else { return }

        let rankX = rank[rootX, default: 0]
        let rankY = rank[rootY, default: 0]

        if rankX < rankY {
            parent[rootX] = rootY
        } else if rankX > rankY {
            parent[rootY] = rootX
        } else {
            parent[rootY] = rootX
            rank[rootX] = rankX + 1
        }
    }

    func allGroups() -> [[T]] {
        var copy = self
        var groups: [T: [T]] = [:]
        for key in parent.keys {
            let root = copy.find(key)
            groups[root, default: []].append(key)
        }
        return Array(groups.values)
    }
}
