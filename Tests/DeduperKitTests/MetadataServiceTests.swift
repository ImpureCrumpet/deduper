import Testing
import Foundation
@testable import DeduperKit

@Suite("MetadataService")
struct MetadataServiceTests {
    let service = MetadataService()

    private func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle.module
        return bundle.resourceURL!
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    // MARK: - Image Metadata

    @Test("Extracts dimensions from PNG screenshot")
    func extractImageDimensions() async {
        let url = fixtureURL("screenshot-a.png")
        let meta = await service.extractMetadata(from: url)

        #expect(meta.mediaType == .photo)
        #expect(meta.dimensions != nil)
        if let dims = meta.dimensions {
            #expect(dims.width > 0)
            #expect(dims.height > 0)
        }
    }

    @Test("Reports correct file size")
    func reportsFileSize() async {
        let url = fixtureURL("screenshot-a.png")
        let meta = await service.extractMetadata(from: url)

        #expect(meta.fileSize > 0)
        #expect(meta.fileName == "screenshot-a.png")
    }

    @Test("Extracts file dates")
    func extractsDates() async {
        let url = fixtureURL("screenshot-a.png")
        let meta = await service.extractMetadata(from: url)

        // File should have at least a modification date
        #expect(meta.modifiedAt != nil)
    }

    @Test("Infers UTType from extension")
    func infersUTType() async {
        let url = fixtureURL("screenshot-a.png")
        let meta = await service.extractMetadata(from: url)
        #expect(meta.inferredUTType == "png")
    }

    // MARK: - Video Metadata

    @Test("Extracts video duration")
    func extractVideoDuration() async {
        let url = fixtureURL("short-video.mov")
        let meta = await service.extractMetadata(from: url)

        #expect(meta.mediaType == .video)
        #expect(meta.durationSec != nil)
        if let duration = meta.durationSec {
            #expect(duration > 0)
        }
    }

    @Test("Extracts video dimensions")
    func extractVideoDimensions() async {
        let url = fixtureURL("short-video.mov")
        let meta = await service.extractMetadata(from: url)

        #expect(meta.dimensions != nil)
        if let dims = meta.dimensions {
            #expect(dims.width > 0)
            #expect(dims.height > 0)
        }
    }

    // MARK: - Metadata Scoring

    @Test("completenessScore reflects available metadata")
    func completenessScoring() async {
        let url = fixtureURL("screenshot-a.png")
        let meta = await service.extractMetadata(from: url)

        // Score should be > 0 since we have at least basic file info
        #expect(meta.completenessScore > 0)
        // Without GPS/camera, won't be perfect
        #expect(meta.completenessScore <= 1.0)
    }

    @Test("formatPreferenceScore ranks PNG high")
    func formatPreference() async {
        let url = fixtureURL("screenshot-a.png")
        let meta = await service.extractMetadata(from: url)

        #expect(meta.formatPreferenceScore == 0.9)
    }

    // MARK: - Comparison between files

    @Test("Different files produce different metadata")
    func differentFilesProduceDifferentMetadata() async {
        let metaA = await service.extractMetadata(
            from: fixtureURL("screenshot-a.png")
        )
        let metaB = await service.extractMetadata(
            from: fixtureURL("screenshot-b.png")
        )

        // Different files should have different sizes
        #expect(metaA.fileSize != metaB.fileSize)
        #expect(metaA.fileName != metaB.fileName)
    }
}
