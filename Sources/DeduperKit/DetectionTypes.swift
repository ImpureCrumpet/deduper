import Foundation
import os

// MARK: - Match Kind

/// Discriminator for the type of match that produced a duplicate group.
/// Stored in artifacts and GroupSummary for safe batch operations.
public enum MatchKind: String, Codable, Sendable, CaseIterable {
    /// Byte-identical files confirmed by SHA256 digest.
    case sha256Exact
    /// Perceptual hash similarity (dHash/pHash).
    case perceptual
    /// Video fingerprint heuristic match.
    case videoHeuristic
    /// V1 artifact without explicit matchKind — re-scan for classification.
    case legacyUnknown

    public var displayName: String {
        switch self {
        case .sha256Exact: "Exact (SHA256)"
        case .perceptual: "Perceptual"
        case .videoHeuristic: "Video"
        case .legacyUnknown: "Legacy (re-scan for classification)"
        }
    }

    /// Cases suitable for user-facing filter pickers.
    /// Excludes `.legacyUnknown` which is an artifact-version state,
    /// not a meaningful match category.
    public static var filterableCases: [MatchKind] {
        allCases.filter { $0 != .legacyUnknown }
    }
}

// MARK: - Detection Options

public struct DetectOptions: Sendable, Equatable {
    public struct Thresholds: Sendable, Equatable {
        public let imageDistance: Int
        public let videoFrameDistance: Int
        public let durationTolerancePct: Double
        public let confidenceDuplicate: Double
        public let confidenceSimilar: Double

        public init(
            imageDistance: Int = 5,
            videoFrameDistance: Int = 5,
            durationTolerancePct: Double = 0.02,
            confidenceDuplicate: Double = 0.85,
            confidenceSimilar: Double = 0.60
        ) {
            self.imageDistance = imageDistance
            self.videoFrameDistance = videoFrameDistance
            self.durationTolerancePct = durationTolerancePct
            self.confidenceDuplicate = confidenceDuplicate
            self.confidenceSimilar = confidenceSimilar
        }
    }

    public struct Limits: Sendable, Equatable {
        public let maxComparisonsPerBucket: Int
        public let maxBucketSize: Int
        public let timeBudgetMs: Int

        public init(
            maxComparisonsPerBucket: Int = 10_000,
            maxBucketSize: Int = 256,
            timeBudgetMs: Int = 20_000
        ) {
            self.maxComparisonsPerBucket = maxComparisonsPerBucket
            self.maxBucketSize = maxBucketSize
            self.timeBudgetMs = timeBudgetMs
        }
    }

    public struct Policies: Sendable, Equatable {
        public let enableRAWJPEG: Bool
        public let enableLivePhoto: Bool
        public let enableSidecarLink: Bool
        public let ignoredPairs: Set<AssetPair>

        public init(
            enableRAWJPEG: Bool = true,
            enableLivePhoto: Bool = true,
            enableSidecarLink: Bool = true,
            ignoredPairs: Set<AssetPair> = []
        ) {
            self.enableRAWJPEG = enableRAWJPEG
            self.enableLivePhoto = enableLivePhoto
            self.enableSidecarLink = enableSidecarLink
            self.ignoredPairs = ignoredPairs
        }
    }

    public struct ConfidenceWeights: Sendable, Equatable {
        public let checksum: Double
        public let hash: Double
        public let metadata: Double
        public let name: Double
        public let captureTime: Double
        public let policyBonus: Double

        public init(
            checksum: Double = 0.50,
            hash: Double = 0.30,
            metadata: Double = 0.10,
            name: Double = 0.05,
            captureTime: Double = 0.03,
            policyBonus: Double = 0.05
        ) {
            guard checksum >= 0, hash >= 0, metadata >= 0, name >= 0, captureTime >= 0, policyBonus >= 0 else {
                fatalError("ConfidenceWeights: all weights must be non-negative")
            }
            guard checksum <= 1.0 else {
                fatalError("ConfidenceWeights: checksum weight should not exceed 1.0")
            }

            self.checksum = checksum
            self.hash = hash
            self.metadata = metadata
            self.name = name
            self.captureTime = captureTime
            self.policyBonus = policyBonus
        }

        /// Creates a new ConfidenceWeights with specified overrides
        public func withOverrides(
            checksum: Double? = nil,
            hash: Double? = nil,
            metadata: Double? = nil,
            name: Double? = nil,
            captureTime: Double? = nil,
            policyBonus: Double? = nil
        ) -> ConfidenceWeights {
            return ConfidenceWeights(
                checksum: checksum ?? self.checksum,
                hash: hash ?? self.hash,
                metadata: metadata ?? self.metadata,
                name: name ?? self.name,
                captureTime: captureTime ?? self.captureTime,
                policyBonus: policyBonus ?? self.policyBonus
            )
        }

        /// Validates the total potential score doesn't exceed reasonable bounds
        public var isValid: Bool {
            let totalPotential = checksum + hash + metadata + name + captureTime + policyBonus
            return totalPotential <= 2.0
        }

        /// Returns a normalized version where weights sum to 1.0 (excluding checksum which is binary)
        public var normalized: ConfidenceWeights {
            let total = hash + metadata + name + captureTime + policyBonus
            guard total > 0 else { return self }
            let factor = (1.0 - checksum) / total
            return ConfidenceWeights(
                checksum: checksum,
                hash: hash * factor,
                metadata: metadata * factor,
                name: name * factor,
                captureTime: captureTime * factor,
                policyBonus: policyBonus * factor
            )
        }
    }

    public let thresholds: Thresholds
    public let limits: Limits
    public let policies: Policies
    public let weights: ConfidenceWeights
    /// When true, skip perceptual hashing and only detect exact SHA256 matches.
    public let exactOnly: Bool
    /// When true, include video files in detection. Default false at scale.
    public let includeVideos: Bool

    public init(
        thresholds: Thresholds = Thresholds(),
        limits: Limits = Limits(),
        policies: Policies = Policies(),
        weights: ConfidenceWeights = ConfidenceWeights(),
        exactOnly: Bool = false,
        includeVideos: Bool = false
    ) {
        self.thresholds = thresholds
        self.limits = limits
        self.policies = policies
        self.weights = weights
        self.exactOnly = exactOnly
        self.includeVideos = includeVideos
    }
}

// MARK: - Candidate Scoping

public enum CandidateScope: Sendable, Equatable {
    case all
    case subset(fileIds: Set<UUID>)
    case folder(URL)
    case bucket(CandidateKey)
}

public struct CandidateKey: Sendable, Hashable, Equatable, Codable {
    public let mediaType: MediaType
    public let signature: String

    public init(mediaType: MediaType, signature: String) {
        self.mediaType = mediaType
        self.signature = signature
    }
}

public struct BucketStats: Sendable, Equatable, Codable {
    public let size: Int
    public let skippedByPolicy: Int
    public let estimatedComparisons: Int

    public init(size: Int, skippedByPolicy: Int, estimatedComparisons: Int) {
        self.size = size
        self.skippedByPolicy = skippedByPolicy
        self.estimatedComparisons = estimatedComparisons
    }
}

public struct CandidateBucket: Sendable, Equatable, Codable {
    public let key: CandidateKey
    public let fileIds: [UUID]
    public let heuristic: String
    public let stats: BucketStats

    public init(key: CandidateKey, fileIds: [UUID], heuristic: String, stats: BucketStats) {
        self.key = key
        self.fileIds = fileIds
        self.heuristic = heuristic
        self.stats = stats
    }
}

// MARK: - Confidence & Evidence

public struct AssetPair: Sendable, Hashable, Equatable {
    public let a: UUID
    public let b: UUID

    public init(_ a: UUID, _ b: UUID) {
        if a.uuidString <= b.uuidString {
            self.a = a
            self.b = b
        } else {
            self.a = b
            self.b = a
        }
    }
}

public struct ConfidenceSignal: Sendable, Equatable, Codable {
    public let key: String
    public let weight: Double
    public let rawScore: Double
    public let contribution: Double
    public let rationale: String

    public init(key: String, weight: Double, rawScore: Double, contribution: Double, rationale: String) {
        self.key = key
        self.weight = weight
        self.rawScore = rawScore
        self.contribution = contribution
        self.rationale = rationale
    }
}

public struct ConfidencePenalty: Sendable, Equatable, Codable {
    public let key: String
    public let value: Double
    public let rationale: String

    public init(key: String, value: Double, rationale: String) {
        self.key = key
        self.value = value
        self.rationale = rationale
    }
}

public struct ConfidenceBreakdown: Sendable, Equatable {
    public let score: Double
    public let signals: [ConfidenceSignal]
    public let penalties: [ConfidencePenalty]

    public init(score: Double, signals: [ConfidenceSignal], penalties: [ConfidencePenalty]) {
        self.score = score
        self.signals = signals
        self.penalties = penalties
    }
}

public struct DuplicateGroupMember: Sendable, Equatable {
    public let fileId: UUID
    public let confidence: Double
    public let signals: [ConfidenceSignal]
    public let penalties: [ConfidencePenalty]
    public let rationale: [String]
    public let fileSize: Int64

    public init(
        fileId: UUID,
        confidence: Double,
        signals: [ConfidenceSignal],
        penalties: [ConfidencePenalty],
        rationale: [String],
        fileSize: Int64 = 0
    ) {
        self.fileId = fileId
        self.confidence = confidence
        self.signals = signals
        self.penalties = penalties
        self.rationale = rationale
        self.fileSize = fileSize
    }
}

public struct DuplicateGroupResult: Sendable, Equatable {
    public let groupId: UUID
    public let members: [DuplicateGroupMember]
    public let confidence: Double
    public let rationaleLines: [String]
    public let keeperSuggestion: UUID?
    public let incomplete: Bool
    public let mediaType: MediaType

    public var id: UUID { groupId }
    public var spacePotentialSaved: Int64 {
        members.map { $0.fileSize }.reduce(0, +) * Int64(members.count - 1)
    }

    public init(
        groupId: UUID,
        members: [DuplicateGroupMember],
        confidence: Double,
        rationaleLines: [String],
        keeperSuggestion: UUID?,
        incomplete: Bool,
        mediaType: MediaType = .photo
    ) {
        self.groupId = groupId
        self.members = members
        self.confidence = confidence
        self.rationaleLines = rationaleLines
        self.keeperSuggestion = keeperSuggestion
        self.incomplete = incomplete
        self.mediaType = mediaType
    }

    public static func == (lhs: DuplicateGroupResult, rhs: DuplicateGroupResult) -> Bool {
        return lhs.groupId == rhs.groupId &&
               lhs.members == rhs.members &&
               lhs.confidence == rhs.confidence &&
               lhs.rationaleLines == rhs.rationaleLines &&
               lhs.keeperSuggestion == rhs.keeperSuggestion &&
               lhs.incomplete == rhs.incomplete &&
               lhs.mediaType == rhs.mediaType
    }
}

extension DuplicateGroupResult: Identifiable {}

public struct GroupRationale: Sendable, Equatable {
    public let groupId: UUID
    public let members: [DuplicateGroupMember]
    public let confidence: Double
    public let rationaleLines: [String]
    public let incomplete: Bool

    public init(group: DuplicateGroupResult) {
        self.groupId = group.groupId
        self.members = group.members
        self.confidence = group.confidence
        self.rationaleLines = group.rationaleLines
        self.incomplete = group.incomplete
    }
}

public struct PixelSize: Sendable, Equatable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct DetectionAsset: Sendable, Equatable, Codable {
    public let id: UUID
    public let url: URL?
    public let mediaType: MediaType
    public let fileName: String
    public let fileSize: Int64
    public let checksum: String?
    public let dimensions: PixelSize?
    public let duration: Double?
    public let captureDate: Date?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let imageHashes: [HashAlgorithm: UInt64]
    public let videoSignature: VideoSignature?

    public init(
        id: UUID,
        url: URL?,
        mediaType: MediaType,
        fileName: String,
        fileSize: Int64,
        checksum: String? = nil,
        dimensions: PixelSize? = nil,
        duration: Double? = nil,
        captureDate: Date? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        imageHashes: [HashAlgorithm: UInt64] = [:],
        videoSignature: VideoSignature? = nil
    ) {
        self.id = id
        self.url = url
        self.mediaType = mediaType
        self.fileName = fileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.dimensions = dimensions
        self.duration = duration
        self.captureDate = captureDate
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.imageHashes = imageHashes
        self.videoSignature = videoSignature
    }

    public var fileExtension: String {
        let ext = (fileName as NSString).pathExtension
        return ext.lowercased()
    }

    public var nameStem: String {
        return DetectionAsset.normalizeStem((fileName as NSString).deletingPathExtension)
    }

    public static func normalizeStem(_ stem: String) -> String {
        var normalized = stem.lowercased()
        normalized = normalized.replacingOccurrences(of: "_", with: " ")
        normalized = normalized.replacingOccurrences(of: "-", with: " ")
        normalized = normalized.replacingOccurrences(of: "copy", with: "")
        normalized = normalized.replacingOccurrences(of: "(1)", with: "")
        normalized = normalized.replacingOccurrences(of: "(2)", with: "")
        normalized = normalized.replacingOccurrences(of: "(3)", with: "")
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }
}

public struct ImageDistanceResult: Sendable, Equatable {
    public let distance: Int?
    public let algorithm: HashAlgorithm?
    public let rationale: [String]
}

public struct VideoDistanceResult: Sendable, Equatable {
    public let meanDistance: Double?
    public let maxDistance: Int?
    public let comparedFrames: Int
    public let mismatchedFrames: Int
    public let rationale: [String]
}

public struct AudioDistanceResult: Sendable, Equatable {
    public let checksumMatch: Bool
    public let durationMatch: Bool
    public let fileSizeMatch: Bool
    public let metadataMatch: Bool
    public let rationale: [String]
}

// MARK: - Detection Metrics

public struct DetectionMetrics: Sendable, Equatable {
    public let totalAssets: Int
    public let totalComparisons: Int
    public let naiveComparisons: Int
    public let reductionPercentage: Double
    public let bucketsCreated: Int
    public let averageBucketSize: Double
    public let timeElapsedMs: Int
    public let incompleteGroups: Int

    public init(
        totalAssets: Int,
        totalComparisons: Int,
        naiveComparisons: Int,
        reductionPercentage: Double,
        bucketsCreated: Int,
        averageBucketSize: Double,
        timeElapsedMs: Int,
        incompleteGroups: Int
    ) {
        self.totalAssets = totalAssets
        self.totalComparisons = totalComparisons
        self.naiveComparisons = naiveComparisons
        self.reductionPercentage = reductionPercentage
        self.bucketsCreated = bucketsCreated
        self.averageBucketSize = averageBucketSize
        self.timeElapsedMs = timeElapsedMs
        self.incompleteGroups = incompleteGroups
    }
}
