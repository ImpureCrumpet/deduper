import Foundation
import os
import CryptoKit

/// Progress updates during detection.
public struct DetectionProgress: Sendable {
    public enum Phase: Sendable {
        case sizeBucketing
        case prehashing(current: Int, total: Int)
        case sha256(current: Int, total: Int)
        case hashing(current: Int, total: Int)
        case indexing
        case querying
        case complete
    }
    public let phase: Phase
}

/// Orchestrates the duplicate detection pipeline:
/// scan files -> compute hashes -> index -> compare -> group.
public struct DetectionService: Sendable {
    private let logger = Logger(
        subsystem: "app.deduper", category: "detect"
    )
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
        options: DetectOptions = DetectOptions(),
        progress: (@Sendable (DetectionProgress) -> Void)? = nil
    ) async throws -> [DuplicateGroupResult] {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Fast first pass: SHA256 exact-match detection with prehash
        let (exactGroups, remainingFiles) = await detectExactDuplicates(
            in: files, options: options, progress: progress
        )

        // If exact-only mode, skip perceptual detection
        if options.exactOnly {
            progress?(.init(phase: .complete))
            var results = exactGroups
            results = applyConfidenceFilter(results, options: options)
            results.sort { $0.confidence > $1.confidence }
            return results
        }

        // Separate remaining files by media type
        let photos = remainingFiles.filter { $0.mediaType == .photo }
        let videos: [ScannedFile]
        if options.includeVideos {
            videos = remainingFiles.filter { $0.mediaType == .video }
        } else {
            videos = []
        }

        // Process in parallel
        async let photoGroups = detectImageDuplicates(
            photos, options: options, progress: progress
        )
        async let videoGroups = detectVideoDuplicates(
            videos, options: options
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

        results = applyConfidenceFilter(results, options: options)
        results.sort { $0.confidence > $1.confidence }
        progress?(.init(phase: .complete))
        return results
    }

    /// Filter results by confidence threshold.
    private func applyConfidenceFilter(
        _ results: [DuplicateGroupResult],
        options: DetectOptions
    ) -> [DuplicateGroupResult] {
        results.filter {
            $0.confidence >= options.thresholds.confidenceDuplicate
        }
    }

    // MARK: - SHA256 Exact-Match Detection (with prehash)

    private func detectExactDuplicates(
        in files: [ScannedFile],
        options: DetectOptions,
        progress: (@Sendable (DetectionProgress) -> Void)? = nil
    ) async -> ([DuplicateGroupResult], [ScannedFile]) {
        guard files.count >= 2 else { return ([], files) }

        progress?(.init(phase: .sizeBucketing))

        // Step 1: Group by file size — unique sizes can't be exact matches
        var sizeBuckets: [Int64: [ScannedFile]] = [:]
        for file in files {
            sizeBuckets[file.fileSize, default: []].append(file)
        }

        let uniqueSizeFiles = sizeBuckets.values
            .filter { $0.count == 1 }
            .flatMap { $0 }
        let candidateFiles = sizeBuckets.values
            .filter { $0.count >= 2 }
            .flatMap { $0 }

        guard !candidateFiles.isEmpty else {
            return ([], files)
        }

        logger.info(
            "Size bucketing: \(candidateFiles.count) candidates, \(uniqueSizeFiles.count) unique sizes skipped"
        )

        // Step 2: Prehash — SHA256 of (first 64KB + last 64KB + size)
        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
        var prehashes: [(ScannedFile, String)] = []
        var prehashCount = 0
        let totalPrehash = candidateFiles.count

        await withTaskGroup(
            of: (ScannedFile, String?).self
        ) { group in
            var iterator = candidateFiles.makeIterator()

            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask {
                    let fp = ContentFingerprint.compute(for: file.url)
                    return (file, fp)
                }
                return true
            }

            for _ in 0..<min(maxConcurrency, candidateFiles.count) {
                _ = addNext()
            }

            for await (file, digest) in group {
                if let digest {
                    prehashes.append((file, digest))
                }
                prehashCount += 1
                if prehashCount % 500 == 0 {
                    progress?(.init(phase: .prehashing(
                        current: prehashCount, total: totalPrehash
                    )))
                }
                _ = addNext()
            }
        }

        // Step 3: Group by prehash — unique prehashes can't be exact
        var prehashBuckets: [String: [ScannedFile]] = [:]
        for (file, hash) in prehashes {
            prehashBuckets[hash, default: []].append(file)
        }

        let prehashCandidates = prehashBuckets.values
            .filter { $0.count >= 2 }
            .flatMap { $0 }

        let prehashUniqueFiles = prehashBuckets.values
            .filter { $0.count == 1 }
            .flatMap { $0 }

        logger.info(
            "Prehash: \(prehashCandidates.count) need full SHA256, \(prehashUniqueFiles.count) unique prehashes skipped"
        )

        guard !prehashCandidates.isEmpty else {
            return ([], files)
        }

        // Step 4: Full SHA256 for remaining candidates
        var fileDigests: [(ScannedFile, String)] = []
        var sha256Count = 0
        let totalSHA = prehashCandidates.count

        await withTaskGroup(
            of: (ScannedFile, String?).self
        ) { group in
            var iterator = prehashCandidates.makeIterator()

            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask {
                    let digest = Self.sha256(of: file.url)
                    return (file, digest)
                }
                return true
            }

            for _ in 0..<min(maxConcurrency, prehashCandidates.count) {
                _ = addNext()
            }

            for await (file, digest) in group {
                if let digest {
                    fileDigests.append((file, digest))
                }
                sha256Count += 1
                if sha256Count % 200 == 0 {
                    progress?(.init(phase: .sha256(
                        current: sha256Count, total: totalSHA
                    )))
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
                            rationale: "SHA256 exact match: "
                                + "\(digest.prefix(12))..."
                        )
                    ],
                    penalties: [],
                    rationale: ["Byte-identical (SHA256)"],
                    fileSize: file.fileSize
                )
            }

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

        let remaining = files.filter { !matchedIds.contains($0.id) }
        return (exactGroups, remaining)
    }

    /// Get file modification date.
    private static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date
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
        options: DetectOptions,
        progress: (@Sendable (DetectionProgress) -> Void)? = nil
    ) async throws -> [DuplicateGroupResult] {
        guard files.count >= 2 else { return [] }

        let hashIndex = HashIndexService(
            config: .default,
            hashingService: imageHasher
        )

        // Compute hashes with bounded concurrency, streaming into index
        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
        var fileHashMap: [UUID: (ScannedFile, [ImageHashResult])] = [:]
        var hashCount = 0
        let totalHash = files.count

        await withTaskGroup(
            of: (ScannedFile, [ImageHashResult]).self
        ) { group in
            var iterator = files.makeIterator()

            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask { [hashCache, imageHasher] in
                    // Check cache first (content fingerprint)
                    if let cache = hashCache {
                        let fp = ContentFingerprint.compute(
                            for: file.url
                        )
                        if let fp,
                           let cached = await cache
                               .lookupByFingerprint(fingerprint: fp) {
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

                        // Fallback: path-based lookup
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

                    // Store in cache with content fingerprint
                    if let cache = hashCache {
                        let mtime = Self.modificationDate(of: file.url)
                        let fp = ContentFingerprint.compute(
                            for: file.url
                        )
                        await cache.store(
                            path: file.url.path,
                            fileSize: file.fileSize,
                            modifiedAt: mtime,
                            hashes: hashes.map {
                                (algorithm: $0.algorithm.rawValue,
                                 hash: $0.hash)
                            },
                            contentFingerprint: fp
                        )
                    }

                    return (file, hashes)
                }
                return true
            }

            for _ in 0..<min(maxConcurrency, files.count) {
                _ = addNext()
            }

            for await (file, hashes) in group {
                fileHashMap[file.id] = (file, hashes)

                // Stream: insert into index immediately
                let hashResults = hashes.map { HashResult(from: $0) }
                await hashIndex.add(
                    fileId: file.id.uuidString,
                    hashResults: hashResults
                )

                hashCount += 1
                if hashCount % 200 == 0 {
                    progress?(.init(phase: .hashing(
                        current: hashCount, total: totalHash
                    )))
                }

                _ = addNext()
            }
        }

        progress?(.init(phase: .querying))

        // Find similar pairs using batch queries
        let threshold = options.thresholds.imageDistance
        var unionFind = UnionFind<UUID>()
        var pairDistances: [AssetPair: Int] = [:]

        // Batch query: collect all queries, process in batches
        var queryBatch: [(UUID, UInt64, String)] = [] // (fileId, hash, algo)
        for (fileId, (_, hashes)) in fileHashMap {
            for hash in hashes {
                queryBatch.append(
                    (fileId, hash.hash, hash.algorithm.rawValue)
                )
            }
        }

        // Process queries in batches to reduce actor hops
        let batchSize = 1000
        for batchStart in stride(
            from: 0, to: queryBatch.count, by: batchSize
        ) {
            let batchEnd = min(
                batchStart + batchSize, queryBatch.count
            )
            let batch = Array(queryBatch[batchStart..<batchEnd])

            let batchResults = await hashIndex.batchQuery(
                queries: batch.map { (
                    hash: $0.1,
                    algorithm: $0.2,
                    excludeFileId: $0.0.uuidString,
                    maxDistance: threshold
                ) }
            )

            for (i, matches) in batchResults.enumerated() {
                let queryFileId = batch[i].0
                for match in matches {
                    guard let matchId = UUID(
                        uuidString: match.fileId
                    ) else { continue }
                    unionFind.union(queryFileId, matchId)
                    let pair = AssetPair(queryFileId, matchId)
                    let existing = pairDistances[pair] ?? Int.max
                    pairDistances[pair] = min(
                        existing, match.distance
                    )
                }
            }
        }

        // Gather metadata for all files in groups
        let groupedIds = Set(unionFind.allGroups().flatMap { $0 })
        let metadataFileMap = Dictionary(
            uniqueKeysWithValues: fileHashMap.map { ($0.key, $0.value) }
        )
        let metadataMap = await fetchMetadata(
            for: groupedIds, fileMap: metadataFileMap
        )

        // Refine groups
        let rawGroups = unionFind.allGroups()
        let refinedGroups = rawGroups.flatMap { memberIds in
            Self.refineGroup(
                memberIds,
                pairDistances: pairDistances,
                threshold: threshold
            )
        }

        return refinedGroups.compactMap {
            memberIds -> DuplicateGroupResult? in
            guard memberIds.count >= 2 else { return nil }

            let members = memberIds.compactMap {
                id -> DuplicateGroupMember? in
                guard let (file, _) = fileHashMap[id] else {
                    return nil
                }
                let meta = metadataMap[id]

                let signals = buildImageSignals(
                    fileId: id,
                    pairDistances: pairDistances,
                    allIds: memberIds,
                    metadata: meta,
                    allMetadata: metadataMap,
                    options: options
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

        // Pre-bucket by file size to skip obviously different files
        var sizeBuckets: [Int64: [ScannedFile]] = [:]
        for file in files {
            // Round to nearest 10% bucket
            let bucket = file.fileSize / 10 * 10
            sizeBuckets[bucket, default: []].append(file)
        }

        var signatures: [(ScannedFile, VideoSignature)] = []

        for file in files {
            if let sig = await videoFingerprinter.fingerprint(
                url: file.url
            ) {
                signatures.append((file, sig))
            }
        }

        guard signatures.count >= 2 else { return [] }

        // Pre-bucket by rounded duration to reduce O(n^2) comparisons
        var durationBuckets: [Int: [(ScannedFile, VideoSignature)]] = [:]
        for entry in signatures {
            let rounded = Int(entry.1.durationSec)
            // Put in nearby buckets (±2%)
            let tolerance = max(2, rounded / 50)
            for bucket in (rounded - tolerance)...(rounded + tolerance) {
                durationBuckets[bucket, default: []].append(entry)
            }
        }

        var unionFind = UnionFind<UUID>()
        var verdicts: [AssetPair: VideoSimilarity] = [:]
        let comparisonOptions = VideoComparisonOptions(
            perFrameMatchThreshold:
                options.thresholds.videoFrameDistance
        )

        // Compare within duration buckets only
        var comparedPairs = Set<AssetPair>()
        for (_, bucket) in durationBuckets {
            if bucket.count > options.limits.maxBucketSize {
                logger.warning(
                    "Video bucket exceeds \(options.limits.maxBucketSize) entries, skipping"
                )
                continue
            }
            for i in 0..<bucket.count {
                for j in (i + 1)..<bucket.count {
                    let pair = AssetPair(
                        bucket[i].0.id, bucket[j].0.id
                    )
                    guard !comparedPairs.contains(pair) else {
                        continue
                    }
                    comparedPairs.insert(pair)

                    // Skip if file sizes differ by > 50%
                    let sizeA = bucket[i].0.fileSize
                    let sizeB = bucket[j].0.fileSize
                    let maxSize = max(sizeA, sizeB)
                    let minSize = min(sizeA, sizeB)
                    if maxSize > 0,
                       Double(minSize) / Double(maxSize) < 0.5 {
                        continue
                    }

                    let similarity = videoFingerprinter.compare(
                        bucket[i].1, bucket[j].1,
                        options: comparisonOptions
                    )
                    if similarity.verdict == .duplicate
                        || similarity.verdict == .similar {
                        unionFind.union(
                            bucket[i].0.id, bucket[j].0.id
                        )
                        verdicts[pair] = similarity
                    }
                }
            }
        }

        let sigMap = Dictionary(
            uniqueKeysWithValues: signatures.map { ($0.0.id, $0) }
        )

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

        return groups.compactMap {
            memberIds -> DuplicateGroupResult? in
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

    private static func refineGroup(
        _ memberIds: [UUID],
        pairDistances: [AssetPair: Int],
        threshold: Int
    ) -> [[UUID]] {
        guard memberIds.count > 3 else { return [memberIds] }

        let strictThreshold = max(1, threshold * 6 / 10)

        var adjacency: [UUID: Set<UUID>] = [:]
        for id in memberIds {
            adjacency[id] = []
        }

        for i in 0..<memberIds.count {
            for j in (i + 1)..<memberIds.count {
                let a = memberIds[i]
                let b = memberIds[j]
                let pair = AssetPair(a, b)
                if let dist = pairDistances[pair],
                   dist <= strictThreshold {
                    adjacency[a, default: []].insert(b)
                    adjacency[b, default: []].insert(a)
                }
            }
        }

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

        let maxAvgDistance = Double(threshold) * 0.5
        var result: [[UUID]] = []

        for component in components {
            guard component.count >= 2 else { continue }

            if component.count <= 4 {
                result.append(component)
                continue
            }

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

    private static func extractTightPairs(
        from ids: [UUID],
        pairDistances: [AssetPair: Int],
        threshold: Int
    ) -> [[UUID]] {
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
        allMetadata: [UUID: MediaMetadata],
        options: DetectOptions
    ) -> [ConfidenceSignal] {
        var signals: [ConfidenceSignal] = []
        let weights = options.weights

        // Hash distance signal
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
            // Name similarity signal — Jaccard bigram similarity
            let stem = (meta.fileName as NSString)
                .deletingPathExtension
            let otherStems = allIds
                .filter { $0 != fileId }
                .compactMap { allMetadata[$0]?.fileName }
                .map {
                    ($0 as NSString).deletingPathExtension
                }

            let bestNameScore = otherStems
                .map { Self.bigramSimilarity(stem, $0) }
                .max() ?? 0.0

            signals.append(ConfidenceSignal(
                key: "name",
                weight: weights.name,
                rawScore: bestNameScore,
                contribution: bestNameScore * weights.name,
                rationale: String(
                    format: "Name similarity %.0f%%",
                    bestNameScore * 100
                )
            ))

            // Capture-time signal
            if let captureDate = meta.captureDate {
                let bestTimeScore = allIds
                    .filter { $0 != fileId }
                    .compactMap { allMetadata[$0]?.captureDate }
                    .map { otherDate -> Double in
                        let delta = abs(
                            captureDate.timeIntervalSince(otherDate)
                        )
                        return delta <= 1.0 ? 1.0 : max(
                            0.0, 1.0 - delta / 60.0
                        )
                    }
                    .max() ?? 0.0

                if bestTimeScore > 0 {
                    signals.append(ConfidenceSignal(
                        key: "captureTime",
                        weight: weights.captureTime,
                        rawScore: bestTimeScore,
                        contribution: bestTimeScore
                            * weights.captureTime,
                        rationale: String(
                            format: "Capture time match %.0f%%",
                            bestTimeScore * 100
                        )
                    ))
                }
            }

            // Metadata completeness
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

    /// Normalized Jaccard similarity on character bigrams.
    static func bigramSimilarity(
        _ a: String, _ b: String
    ) -> Double {
        let normA = DetectionAsset.normalizeStem(a)
        let normB = DetectionAsset.normalizeStem(b)

        guard !normA.isEmpty, !normB.isEmpty else { return 0.0 }
        if normA == normB { return 1.0 }

        let bigramsA = Self.characterBigrams(normA)
        let bigramsB = Self.characterBigrams(normB)

        guard !bigramsA.isEmpty, !bigramsB.isEmpty else {
            return 0.0
        }

        let intersection = bigramsA.intersection(bigramsB).count
        let union = bigramsA.union(bigramsB).count

        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    private static func characterBigrams(
        _ str: String
    ) -> Set<String> {
        let chars = Array(str)
        guard chars.count >= 2 else {
            return chars.isEmpty ? [] : [String(chars)]
        }
        var bigrams = Set<String>()
        for i in 0..<(chars.count - 1) {
            bigrams.insert(String(chars[i...i + 1]))
        }
        return bigrams
    }

    private func buildVideoSignals(
        fileId: UUID,
        verdicts: [AssetPair: VideoSimilarity],
        allIds: [UUID],
        metadata: MediaMetadata?
    ) -> [ConfidenceSignal] {
        var signals: [ConfidenceSignal] = []

        let bestVerdict = allIds
            .filter { $0 != fileId }
            .compactMap { verdicts[AssetPair(fileId, $0)] }
            .min(by: {
                ($0.averageDistance ?? 999)
                    < ($1.averageDistance ?? 999)
            })

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

            let durationScore = verdict.durationDeltaRatio < 0.02
                ? 1.0
                : max(0.0, 1.0 - verdict.durationDeltaRatio)
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

    private func keeperScore(
        meta: MediaMetadata?,
        size: Int64
    ) -> Double {
        guard let meta else {
            return Double(size) / 1_000_000_000.0
        }
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
            parent[root] = parent[parent[root]!]
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
