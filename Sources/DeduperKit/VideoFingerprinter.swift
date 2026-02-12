import Foundation
import AVFoundation
import CoreGraphics
import os
import CoreMedia

// MARK: - Video Types

public struct VideoSignature: Sendable, Equatable, Codable {
    public let durationSec: Double
    public let width: Int
    public let height: Int
    public let frameHashes: [UInt64]
    public let sampleTimesSec: [Double]
    public let computedAt: Date

    public init(
        durationSec: Double,
        width: Int,
        height: Int,
        frameHashes: [UInt64],
        sampleTimesSec: [Double] = [],
        computedAt: Date = Date()
    ) {
        self.durationSec = durationSec
        self.width = width
        self.height = height
        self.frameHashes = frameHashes
        self.sampleTimesSec = sampleTimesSec
        self.computedAt = computedAt
    }
}

public struct VideoFingerprintConfig: Sendable, Equatable {
    public let middleSampleMinimumDuration: Double
    public let endSampleOffset: Double
    public let generatorMaxDimension: Int
    public let preferredTimescale: Int32
    /// Maximum number of scene-representative frames to keep.
    public let maxSceneFrames: Int
    /// Hamming distance threshold for consecutive frame deduplication.
    /// Frames within this distance of the previous frame are considered
    /// the same scene and deduplicated.
    public let sceneDedupThreshold: Int
    /// Sampling interval in seconds for scene detection pass.
    /// Shorter = more accurate scene detection but slower.
    public let sceneSampleInterval: Double

    public static let `default` = VideoFingerprintConfig(
        middleSampleMinimumDuration: 2.0,
        endSampleOffset: 1.0,
        generatorMaxDimension: 720,
        preferredTimescale: 600,
        maxSceneFrames: 20,
        sceneDedupThreshold: 5,
        sceneSampleInterval: 2.0
    )

    public init(
        middleSampleMinimumDuration: Double = 2.0,
        endSampleOffset: Double = 1.0,
        generatorMaxDimension: Int = 720,
        preferredTimescale: Int32 = 600,
        maxSceneFrames: Int = 20,
        sceneDedupThreshold: Int = 5,
        sceneSampleInterval: Double = 2.0
    ) {
        self.middleSampleMinimumDuration = middleSampleMinimumDuration
        self.endSampleOffset = endSampleOffset
        self.generatorMaxDimension = generatorMaxDimension
        self.preferredTimescale = preferredTimescale
        self.maxSceneFrames = maxSceneFrames
        self.sceneDedupThreshold = sceneDedupThreshold
        self.sceneSampleInterval = sceneSampleInterval
    }

    public var shortClipDurationThreshold: Double {
        return middleSampleMinimumDuration
    }
}

public struct VideoComparisonOptions: Sendable, Equatable {
    public let perFrameMatchThreshold: Int
    public let maxMismatchedFramesForDuplicate: Int
    public let durationToleranceSeconds: Double
    public let durationToleranceFraction: Double

    public static let `default` = VideoComparisonOptions(
        perFrameMatchThreshold: 5,
        maxMismatchedFramesForDuplicate: 1,
        durationToleranceSeconds: 2.0,
        durationToleranceFraction: 0.02
    )

    public init(
        perFrameMatchThreshold: Int = 5,
        maxMismatchedFramesForDuplicate: Int = 1,
        durationToleranceSeconds: Double = 2.0,
        durationToleranceFraction: Double = 0.02
    ) {
        self.perFrameMatchThreshold = perFrameMatchThreshold
        self.maxMismatchedFramesForDuplicate = maxMismatchedFramesForDuplicate
        self.durationToleranceSeconds = durationToleranceSeconds
        self.durationToleranceFraction = durationToleranceFraction
    }
}

public enum VideoComparisonVerdict: Sendable, Equatable {
    case duplicate
    case similar
    case different
    case insufficientData
}

public struct VideoFrameDistance: Sendable, Equatable {
    public let index: Int
    public let timeA: Double?
    public let timeB: Double?
    public let hashA: UInt64?
    public let hashB: UInt64?
    public let distance: Int?
}

public struct VideoSimilarity: Sendable, Equatable {
    public let verdict: VideoComparisonVerdict
    public let durationDelta: Double
    public let durationDeltaRatio: Double
    public let frameDistances: [VideoFrameDistance]
    public let averageDistance: Double?
    public let maxDistance: Int?
    public let mismatchedFrameCount: Int
}

// MARK: - Video Signature Cache

actor VideoSignatureCache {
    private struct CachedEntry {
        let signature: VideoSignature
        let fileSize: Int64?
        let modifiedAt: Date?
    }

    private var storage: [URL: CachedEntry] = [:]

    func get(url: URL, fileSize: Int64?, modifiedAt: Date?) -> VideoSignature? {
        guard let cached = storage[url] else { return nil }
        if cached.fileSize == fileSize && cached.modifiedAt == modifiedAt {
            return cached.signature
        }
        return nil
    }

    func store(signature: VideoSignature, url: URL, fileSize: Int64?, modifiedAt: Date?) {
        storage[url] = CachedEntry(signature: signature, fileSize: fileSize, modifiedAt: modifiedAt)
    }

    func clear() { storage.removeAll() }
}

// MARK: - Frame Generation

public protocol VideoFrameGeneratorProtocol: Sendable {
    func generateFrames(asset: AVAsset, times: [CMTime]) async throws -> [(CGImage, CMTime)]
}

public struct AVAssetVideoFrameGenerator: VideoFrameGeneratorProtocol, Sendable {
    private let maxDimension: CGFloat

    public init(maxDimension: CGFloat = 720) {
        self.maxDimension = maxDimension
    }

    public func generateFrames(asset: AVAsset, times: [CMTime]) async throws -> [(CGImage, CMTime)] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if maxDimension > 0 {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }

        var frames: [(CGImage, CMTime)] = []
        for cmTime in times {
            var actualTime = CMTime.invalid
            let image = try generator.copyCGImage(at: cmTime, actualTime: &actualTime)
            frames.append((image, actualTime))
        }
        return frames
    }
}

// MARK: - Video Fingerprinter

public struct VideoFingerprinter: Sendable {
    private let logger = Logger(subsystem: "app.deduper", category: "video")
    private let config: VideoFingerprintConfig
    private let imageHasher: ImageHashingService
    private let cache: VideoSignatureCache
    private let frameGenerator: VideoFrameGeneratorProtocol

    public init(
        config: VideoFingerprintConfig = .default,
        imageHasher: ImageHashingService = ImageHashingService(),
        frameGenerator: VideoFrameGeneratorProtocol? = nil
    ) {
        self.config = config
        self.imageHasher = imageHasher
        self.cache = VideoSignatureCache()
        self.frameGenerator = frameGenerator ?? AVAssetVideoFrameGenerator(maxDimension: CGFloat(config.generatorMaxDimension))
    }

    // MARK: - Fingerprinting

    /// Computes a video signature for the provided URL.
    /// - Parameter url: Local file URL of the video asset.
    /// - Returns: A populated VideoSignature or nil if frames could not be sampled.
    public func fingerprint(url: URL) async -> VideoSignature? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
        let modifiedAt = attributes?[.modificationDate] as? Date
        let canCache = fileSize != nil || modifiedAt != nil

        if canCache,
           let cached = await cache.get(url: url, fileSize: fileSize, modifiedAt: modifiedAt) {
            logger.debug("Video fingerprint cache hit for \(url.lastPathComponent, privacy: .public)")
            return cached
        }

        let asset = AVAsset(url: url)

        do {
            let (isReadable, hasProtectedContent) = try await asset.load(.isReadable, .hasProtectedContent)
            guard isReadable, !hasProtectedContent else {
                logger.info("Skipping unreadable or protected asset: \(url.lastPathComponent, privacy: .public)")
                return nil
            }

            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                logger.debug("Asset has invalid duration: \(url.lastPathComponent, privacy: .public)")
                return nil
            }

            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                logger.debug("No video track found for: \(url.lastPathComponent, privacy: .public)")
                return nil
            }

            let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)

            // Dense sampling for scene detection
            let targetTimes = denseSampleTimes(for: durationSeconds)
            let cmTimes = targetTimes.map { time in
                CMTimeMakeWithSeconds(time, preferredTimescale: config.preferredTimescale)
            }

            let generatedFrames: [(CGImage, CMTime)]
            do {
                generatedFrames = try await frameGenerator.generateFrames(asset: asset, times: cmTimes)
            } catch {
                logger.error("Frame generation failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }

            // Hash all sampled frames
            var allHashes: [UInt64] = []
            var allTimes: [Double] = []

            for (index, (image, actualTime)) in generatedFrames.enumerated() {
                if let dHash = imageHasher.computeHashes(from: image).first(where: { $0.algorithm == .dHash }) {
                    allHashes.append(dHash.hash)
                    let actual = CMTimeGetSeconds(actualTime)
                    allTimes.append(actual.isFinite ? actual : targetTimes[index])
                }
            }

            guard !allHashes.isEmpty else {
                logger.info("No frame hashes computed for \(url.lastPathComponent, privacy: .public)")
                return nil
            }

            // Deduplicate consecutive similar frames (scene detection)
            let scenes = deduplicateScenes(
                hashes: allHashes,
                times: allTimes
            )
            let hashes = scenes.map(\.hash)
            let actualTimes = scenes.map(\.time)

            logger.debug(
                "Video \(url.lastPathComponent, privacy: .public): \(allHashes.count) frames → \(scenes.count) scenes"
            )

            let signature = VideoSignature(
                durationSec: durationSeconds,
                width: Int(abs(transformedSize.width)),
                height: Int(abs(transformedSize.height)),
                frameHashes: hashes,
                sampleTimesSec: actualTimes,
                computedAt: Date()
            )

            if canCache {
                await cache.store(signature: signature, url: url, fileSize: fileSize, modifiedAt: modifiedAt)
            }

            return signature
        } catch {
            logger.error("Failed to load asset properties: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Comparison

    /// Compares two video signatures and returns per-frame distances alongside an aggregate verdict.
    public func compare(
        _ a: VideoSignature,
        _ b: VideoSignature,
        options: VideoComparisonOptions = .default
    ) -> VideoSimilarity {
        let longest = max(a.frameHashes.count, b.frameHashes.count)
        var frameDistances: [VideoFrameDistance] = []
        var consideredDistances: [Int] = []
        var mismatched = 0

        for index in 0..<longest {
            let hashA = index < a.frameHashes.count ? a.frameHashes[index] : nil
            let hashB = index < b.frameHashes.count ? b.frameHashes[index] : nil
            let timeA = index < a.sampleTimesSec.count ? a.sampleTimesSec[index] : nil
            let timeB = index < b.sampleTimesSec.count ? b.sampleTimesSec[index] : nil

            var distance: Int?
            if let hashA, let hashB {
                distance = imageHasher.hammingDistance(hashA, hashB)
                consideredDistances.append(distance!)
                if distance! > options.perFrameMatchThreshold {
                    mismatched += 1
                }
            } else if (hashA != nil) != (hashB != nil) {
                mismatched += 1
            }

            let frameDistance = VideoFrameDistance(
                index: index,
                timeA: timeA,
                timeB: timeB,
                hashA: hashA,
                hashB: hashB,
                distance: distance
            )
            frameDistances.append(frameDistance)
        }

        let durationDelta = abs(a.durationSec - b.durationSec)
        let maxDuration = max(a.durationSec, b.durationSec)
        let tolerance = max(options.durationToleranceSeconds, maxDuration * options.durationToleranceFraction)
        let durationWithinTolerance = durationDelta <= tolerance

        guard !consideredDistances.isEmpty else {
            return VideoSimilarity(
                verdict: .insufficientData,
                durationDelta: durationDelta,
                durationDeltaRatio: maxDuration > 0 ? durationDelta / maxDuration : 0,
                frameDistances: frameDistances,
                averageDistance: nil,
                maxDistance: nil,
                mismatchedFrameCount: mismatched
            )
        }

        let totalDistance = consideredDistances.reduce(0, +)
        let averageDistance = Double(totalDistance) / Double(consideredDistances.count)
        let maxDistance = consideredDistances.max()

        let verdict: VideoComparisonVerdict
        if durationWithinTolerance {
            if mismatched == 0 {
                verdict = .duplicate
            } else if mismatched <= options.maxMismatchedFramesForDuplicate {
                verdict = .similar
            } else {
                verdict = .different
            }
        } else {
            verdict = mismatched == 0 ? .similar : .different
        }

        return VideoSimilarity(
            verdict: verdict,
            durationDelta: durationDelta,
            durationDeltaRatio: maxDuration > 0 ? durationDelta / maxDuration : 0,
            frameDistances: frameDistances,
            averageDistance: averageDistance,
            maxDistance: maxDistance,
            mismatchedFrameCount: mismatched
        )
    }

    // MARK: - Sample Times

    /// Generate dense sample times for scene detection.
    /// For short clips (< 4s), uses start/middle/end.
    /// For longer videos, samples every `sceneSampleInterval` seconds.
    private func denseSampleTimes(for duration: Double) -> [Double] {
        // Short clips: use legacy 3-point sampling
        if duration < config.sceneSampleInterval * 2 {
            return legacySampleTimes(for: duration)
        }

        var times: [Double] = [0.0]
        var t = config.sceneSampleInterval
        while t < duration - config.endSampleOffset {
            times.append(t)
            t += config.sceneSampleInterval
        }
        // Always include a near-end sample
        let endSample = max(duration - config.endSampleOffset, 0.0)
        if let last = times.last, abs(last - endSample) > 0.5 {
            times.append(endSample)
        }
        return times
    }

    /// Legacy 3-point sampling (start, middle, end) for short clips.
    private func legacySampleTimes(for duration: Double) -> [Double] {
        var samples: [Double] = [0.0]
        if duration >= config.middleSampleMinimumDuration {
            samples.append(duration / 2.0)
        }
        if duration > 0 {
            let endSample = max(duration - config.endSampleOffset, 0.0)
            samples.append(endSample)
        }

        let sorted = samples.sorted()
        var deduped: [Double] = []
        let tolerance: Double = 0.05
        for time in sorted {
            if let last = deduped.last, abs(last - time) < tolerance {
                continue
            }
            deduped.append(min(max(time, 0.0), duration))
        }

        if deduped.count == 1 && duration > 0 {
            let fallback = max(duration - min(duration, 0.1), 0.0)
            if abs(deduped[0] - fallback) > tolerance {
                deduped.append(fallback)
            }
        }

        return deduped
    }

    // MARK: - Scene-Aware Deduplication

    /// Deduplicate consecutive frames that belong to the same scene.
    /// Returns indices of frames to keep (first frame of each scene cluster).
    private func deduplicateScenes(
        hashes: [UInt64],
        times: [Double]
    ) -> [(hash: UInt64, time: Double)] {
        guard !hashes.isEmpty else { return [] }

        var scenes: [(hash: UInt64, time: Double)] = [
            (hashes[0], times.isEmpty ? 0 : times[0])
        ]

        for i in 1..<hashes.count {
            let prevHash = scenes.last!.hash
            let distance = imageHasher.hammingDistance(hashes[i], prevHash)
            if distance > config.sceneDedupThreshold {
                // New scene detected
                let time = i < times.count ? times[i] : 0
                scenes.append((hashes[i], time))
            }
        }

        // Cap at maxSceneFrames by evenly sampling
        if scenes.count > config.maxSceneFrames {
            let step = Double(scenes.count) / Double(config.maxSceneFrames)
            var sampled: [(hash: UInt64, time: Double)] = []
            var idx = 0.0
            while sampled.count < config.maxSceneFrames
                    && Int(idx) < scenes.count {
                sampled.append(scenes[Int(idx)])
                idx += step
            }
            return sampled
        }

        return scenes
    }

    // MARK: - Cache Management

    public func clearCache() async {
        await cache.clear()
    }
}
