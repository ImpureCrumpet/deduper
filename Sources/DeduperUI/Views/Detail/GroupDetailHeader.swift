import SwiftUI
import DeduperKit

/// Header for group detail showing confidence, match kind, and member count.
public struct GroupDetailHeader: View {
    public let groupIndex: Int
    public let confidence: Double
    public let matchBasis: String
    public let matchKind: String
    public let memberCount: Int

    public init(
        groupIndex: Int,
        confidence: Double,
        matchBasis: String,
        matchKind: String = "perceptual",
        memberCount: Int
    ) {
        self.groupIndex = groupIndex
        self.confidence = confidence
        self.matchBasis = matchBasis
        self.matchKind = matchKind
        self.memberCount = memberCount
    }

    private var matchKindDisplay: String {
        MatchKind(rawValue: matchKind)?.displayName
            ?? matchBasis.capitalized
    }

    private var isLegacy: Bool {
        matchKind == MatchKind.legacyUnknown.rawValue
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Group \(groupIndex)")
                    .font(.title2.bold())

                ConfidenceBadge(confidence: confidence)

                Text(matchKindDisplay)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())

                Text("\(memberCount) members")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if isLegacy {
                Label(
                    "Legacy artifact — re-scan for exact/perceptual classification",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.bottom, 4)
    }
}
