import Testing
import Foundation
import CoreGraphics
import AVFoundation
import CoreMedia
@testable import DeduperKit

@Suite("VideoFingerprinter")
struct VideoFingerprinterTests {

    // MARK: - Comparison Tests (using synthetic signatures)

    @Test("Identical signatures produce duplicate verdict")
    func identicalSignatures() {
        let fingerprinter = VideoFingerprinter()
        let sig = VideoSignature(
            durationSec: 10.0,
            width: 1920,
            height: 1080,
            frameHashes: [100, 200, 300],
            sampleTimesSec: [0.0, 5.0, 9.0]
        )

        let result = fingerprinter.compare(sig, sig)
        #expect(result.verdict == .duplicate)
        #expect(result.mismatchedFrameCount == 0)
        #expect(result.averageDistance == 0.0)
    }

    @Test("Similar signatures with small differences produce similar verdict")
    func similarSignatures() {
        let fingerprinter = VideoFingerprinter()
        let sigA = VideoSignature(
            durationSec: 10.0,
            width: 1920,
            height: 1080,
            frameHashes: [100, 200, 300],
            sampleTimesSec: [0.0, 5.0, 9.0]
        )
        // Flip a few bits in one frame hash
        let sigB = VideoSignature(
            durationSec: 10.0,
            width: 1920,
            height: 1080,
            frameHashes: [100, UInt64(200) ^ 0b111111, 300],
            sampleTimesSec: [0.0, 5.0, 9.0]
        )

        let result = fingerprinter.compare(sigA, sigB)
        let isSimilarOrDuplicate = result.verdict == VideoComparisonVerdict.similar
            || result.verdict == VideoComparisonVerdict.duplicate
        #expect(isSimilarOrDuplicate)
        #expect(result.mismatchedFrameCount <= 1)
    }

    @Test("Very different signatures produce different verdict")
    func differentSignatures() {
        let fingerprinter = VideoFingerprinter()
        let sigA = VideoSignature(
            durationSec: 10.0,
            width: 1920,
            height: 1080,
            frameHashes: [0, 0, 0],
            sampleTimesSec: [0.0, 5.0, 9.0]
        )
        let sigB = VideoSignature(
            durationSec: 10.0,
            width: 1920,
            height: 1080,
            frameHashes: [UInt64.max, UInt64.max, UInt64.max],
            sampleTimesSec: [0.0, 5.0, 9.0]
        )

        let result = fingerprinter.compare(sigA, sigB)
        #expect(result.verdict == .different)
        #expect(result.mismatchedFrameCount == 3)
    }

    @Test("Duration mismatch affects verdict")
    func durationMismatch() {
        let fingerprinter = VideoFingerprinter()
        let sigA = VideoSignature(
            durationSec: 10.0,
            width: 1920,
            height: 1080,
            frameHashes: [100, 200, 300],
            sampleTimesSec: [0.0, 5.0, 9.0]
        )
        let sigB = VideoSignature(
            durationSec: 60.0,
            width: 1920,
            height: 1080,
            frameHashes: [100, 200, 300],
            sampleTimesSec: [0.0, 30.0, 59.0]
        )

        let result = fingerprinter.compare(sigA, sigB)
        // Even with matching hashes, large duration diff prevents duplicate
        #expect(result.verdict != .duplicate)
        #expect(result.durationDelta == 50.0)
    }

    @Test("Empty frame hashes produce insufficient data")
    func emptyFrameHashes() {
        let fingerprinter = VideoFingerprinter()
        let sigA = VideoSignature(
            durationSec: 5.0, width: 640, height: 480,
            frameHashes: [], sampleTimesSec: []
        )
        let sigB = VideoSignature(
            durationSec: 5.0, width: 640, height: 480,
            frameHashes: [], sampleTimesSec: []
        )

        let result = fingerprinter.compare(sigA, sigB)
        #expect(result.verdict == .insufficientData)
    }

    @Test("Mismatched frame count still compares available frames")
    func mismatchedFrameCount() {
        let fingerprinter = VideoFingerprinter()
        let sigA = VideoSignature(
            durationSec: 10.0, width: 1920, height: 1080,
            frameHashes: [100, 200], sampleTimesSec: [0.0, 5.0]
        )
        let sigB = VideoSignature(
            durationSec: 10.0, width: 1920, height: 1080,
            frameHashes: [100, 200, 300],
            sampleTimesSec: [0.0, 5.0, 9.0]
        )

        let result = fingerprinter.compare(sigA, sigB)
        #expect(result.frameDistances.count == 3)
    }

    // MARK: - VideoSignature value type

    @Test("VideoSignature equality")
    func signatureEquality() {
        let sig1 = VideoSignature(
            durationSec: 5.0, width: 640, height: 480,
            frameHashes: [1, 2, 3]
        )
        let sig2 = VideoSignature(
            durationSec: 5.0, width: 640, height: 480,
            frameHashes: [1, 2, 3]
        )
        #expect(sig1.frameHashes == sig2.frameHashes)
        #expect(sig1.durationSec == sig2.durationSec)
    }

    // MARK: - Real File Fixture Tests

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test("Fingerprint real MOV file")
    func fingerprintRealVideo() async {
        let fingerprinter = VideoFingerprinter()
        let sig = await fingerprinter.fingerprint(
            url: fixtureURL("short-video.mov")
        )

        let signature = try! #require(sig)
        #expect(signature.durationSec > 0)
        #expect(signature.width > 0)
        #expect(signature.height > 0)
        #expect(!signature.frameHashes.isEmpty)
    }

    @Test("Fingerprinting same file twice produces same hashes")
    func fingerprintConsistency() async {
        let fingerprinter = VideoFingerprinter()
        let url = fixtureURL("short-video.mov")

        let sig1 = await fingerprinter.fingerprint(url: url)
        await fingerprinter.clearCache()
        let sig2 = await fingerprinter.fingerprint(url: url)

        let s1 = try! #require(sig1)
        let s2 = try! #require(sig2)
        #expect(s1.frameHashes == s2.frameHashes)
        #expect(s1.durationSec == s2.durationSec)
    }

    @Test("Two different videos produce different signatures")
    func differentVideosFingerprints() async {
        let fingerprinter = VideoFingerprinter()

        let sig1 = await fingerprinter.fingerprint(
            url: fixtureURL("short-video.mov")
        )
        let sig2 = await fingerprinter.fingerprint(
            url: fixtureURL("short-video-2.mov")
        )

        let s1 = try! #require(sig1)
        let s2 = try! #require(sig2)

        // Different recordings should have different signatures
        let result = fingerprinter.compare(s1, s2)
        // They are different screen recordings, not duplicates
        #expect(
            result.verdict == .different
            || result.verdict == .similar
        )
    }
}
