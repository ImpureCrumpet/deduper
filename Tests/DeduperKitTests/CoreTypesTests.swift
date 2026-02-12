import Testing
import Foundation
@testable import DeduperKit

@Suite("CoreTypes")
struct CoreTypesTests {

    // MARK: - MediaType

    @Test("MediaType has expected extensions")
    func mediaTypeExtensions() {
        #expect(MediaType.photo.commonExtensions.contains("jpg"))
        #expect(MediaType.photo.commonExtensions.contains("heic"))
        #expect(MediaType.video.commonExtensions.contains("mp4"))
        #expect(MediaType.video.commonExtensions.contains("mov"))
        #expect(MediaType.audio.commonExtensions.contains("mp3"))
    }

    // MARK: - ExcludeRule

    @Test("ExcludeRule pathPrefix matches")
    func excludePathPrefix() {
        let rule = ExcludeRule(
            .pathPrefix("/System"),
            description: "System"
        )
        let url = URL(fileURLWithPath: "/System/Library/foo.jpg")
        #expect(rule.matches(url))

        let url2 = URL(fileURLWithPath: "/Users/me/photo.jpg")
        #expect(!rule.matches(url2))
    }

    @Test("ExcludeRule isHidden matches dotfiles")
    func excludeHidden() {
        let rule = ExcludeRule(.isHidden, description: "Hidden")
        #expect(rule.matches(URL(fileURLWithPath: "/a/.hidden.jpg")))
        #expect(!rule.matches(URL(fileURLWithPath: "/a/visible.jpg")))
    }

    @Test("ExcludeRule isSystemBundle matches .app")
    func excludeSystemBundle() {
        let rule = ExcludeRule(.isSystemBundle, description: "Bundles")
        #expect(rule.matches(URL(fileURLWithPath: "/Apps/Foo.app")))
        #expect(rule.matches(URL(fileURLWithPath: "/Lib/Bar.framework")))
        #expect(!rule.matches(URL(fileURLWithPath: "/a/photo.jpg")))
    }

    @Test("ExcludeRule pathContains matches substring")
    func excludePathContains() {
        let rule = ExcludeRule(
            .pathContains("node_modules"),
            description: "npm"
        )
        let url = URL(fileURLWithPath: "/project/node_modules/foo/bar.jpg")
        #expect(rule.matches(url))
    }

    @Test("ExcludeRule isCloudSyncFolder matches iCloud paths")
    func excludeCloudSync() {
        let rule = ExcludeRule(
            .isCloudSyncFolder,
            description: "Cloud"
        )
        let url = URL(
            fileURLWithPath: "/Users/me/Library/Mobile Documents/iCloud/photo.jpg"
        )
        #expect(rule.matches(url))
    }

    // MARK: - MediaMetadata scoring

    @Test("completenessScore is 0.2 for minimal metadata")
    func minimalCompleteness() {
        let meta = MediaMetadata(
            fileName: "test.jpg",
            fileSize: 100,
            mediaType: .photo
        )
        // Only basic file metadata contributes (1 of 5 fields)
        #expect(meta.completenessScore == 0.2)
    }

    @Test("completenessScore increases with more fields")
    func richerCompleteness() {
        let meta = MediaMetadata(
            fileName: "test.jpg",
            fileSize: 100,
            mediaType: .photo,
            captureDate: Date(),
            cameraModel: "iPhone 15",
            gpsLat: 37.7749,
            gpsLon: -122.4194
        )
        // Basic (1) + captureDate (1) + GPS (1) + camera (1) = 4/5
        #expect(meta.completenessScore == 0.8)
    }

    @Test("formatPreferenceScore ranks correctly")
    func formatPreferenceRanking() {
        let raw = MediaMetadata(
            fileName: "a.dng", fileSize: 100, mediaType: .photo,
            inferredUTType: "dng"
        )
        let png = MediaMetadata(
            fileName: "a.png", fileSize: 100, mediaType: .photo,
            inferredUTType: "png"
        )
        let jpeg = MediaMetadata(
            fileName: "a.jpg", fileSize: 100, mediaType: .photo,
            inferredUTType: "jpeg"
        )
        let heic = MediaMetadata(
            fileName: "a.heic", fileSize: 100, mediaType: .photo,
            inferredUTType: "heic"
        )

        #expect(raw.formatPreferenceScore > png.formatPreferenceScore)
        #expect(png.formatPreferenceScore > jpeg.formatPreferenceScore)
        #expect(jpeg.formatPreferenceScore > heic.formatPreferenceScore)
    }

    // MARK: - URL extensions

    @Test("URL.matches works with glob patterns")
    func urlGlobMatching() {
        let url = URL(fileURLWithPath: "/photos/vacation/beach.jpg")
        #expect(url.matches(pattern: "*.jpg"))
        #expect(!url.matches(pattern: "*.png"))
        #expect(url.matches(pattern: "*vacation*"))
    }

    // MARK: - ScanOptions

    @Test("ScanOptions defaults are reasonable")
    func scanOptionsDefaults() {
        let opts = ScanOptions()
        #expect(opts.excludes.isEmpty)
        #expect(!opts.followSymlinks)
        #expect(opts.concurrency > 0)
        #expect(opts.incremental)
    }

    @Test("ScanOptions clamps concurrency")
    func scanOptionsConcurrency() {
        let opts = ScanOptions(concurrency: 999)
        #expect(
            opts.concurrency <= ProcessInfo.processInfo.activeProcessorCount
        )

        let opts2 = ScanOptions(concurrency: 0)
        #expect(opts2.concurrency >= 1)
    }

    // MARK: - UnionFind

    @Test("UnionFind groups connected elements")
    func unionFindBasic() {
        var uf = UnionFind<String>()
        uf.union("a", "b")
        uf.union("b", "c")
        uf.union("d", "e")

        let groups = uf.allGroups()
        #expect(groups.count == 2)

        let sizes = groups.map(\.count).sorted()
        #expect(sizes == [2, 3])
    }

    @Test("UnionFind single elements form singleton groups")
    func unionFindSingletons() {
        var uf = UnionFind<Int>()
        _ = uf.find(1)
        _ = uf.find(2)
        _ = uf.find(3)

        let groups = uf.allGroups()
        #expect(groups.count == 3)
    }

    @Test("UnionFind union is idempotent")
    func unionFindIdempotent() {
        var uf = UnionFind<Int>()
        uf.union(1, 2)
        uf.union(1, 2)
        uf.union(2, 1)

        let groups = uf.allGroups()
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }
}
