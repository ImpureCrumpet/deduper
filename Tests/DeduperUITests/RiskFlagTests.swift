import Testing
import Foundation
@testable import DeduperUI

@Suite("RiskFlags")
struct RiskFlagTests {
    @Test("3 .mov files → isMixedFormat = false")
    func sameFormatNotMixed() {
        let flags = GroupSummary.computeRiskFlags(
            memberCount: 3,
            extensions: Set(["mov"])
        )
        #expect(flags.isMixedFormat == false)
    }

    @Test(".jpg + .png → isMixedFormat = true")
    func differentFormatsMixed() {
        let flags = GroupSummary.computeRiskFlags(
            memberCount: 2,
            extensions: Set(["jpg", "png"])
        )
        #expect(flags.isMixedFormat == true)
    }

    @Test("4+ members → isLargeGroup = true")
    func largeGroupDetected() {
        let flags = GroupSummary.computeRiskFlags(
            memberCount: 4,
            extensions: Set(["jpg"])
        )
        #expect(flags.isLargeGroup == true)
    }

    @Test("3 members → isLargeGroup = false")
    func normalGroupNotLarge() {
        let flags = GroupSummary.computeRiskFlags(
            memberCount: 3,
            extensions: Set(["jpg"])
        )
        #expect(flags.isLargeGroup == false)
    }

    @Test("1 extension, 2 members → no flags")
    func noFlags() {
        let flags = GroupSummary.computeRiskFlags(
            memberCount: 2,
            extensions: Set(["heic"])
        )
        #expect(flags.isLargeGroup == false)
        #expect(flags.isMixedFormat == false)
    }

    @Test("Multiple extensions, many members → both flags")
    func bothFlags() {
        let flags = GroupSummary.computeRiskFlags(
            memberCount: 5,
            extensions: Set(["jpg", "png", "heic"])
        )
        #expect(flags.isLargeGroup == true)
        #expect(flags.isMixedFormat == true)
    }
}
