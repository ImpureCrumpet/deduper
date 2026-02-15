import SwiftUI

/// Group row in the group list with confidence badge and risk flags.
public struct GroupRowView: View {
    public let group: GroupSummary
    public let decisionState: DecisionState?
    public let thumbnail: NSImage?

    public init(
        group: GroupSummary,
        decisionState: DecisionState? = nil,
        thumbnail: NSImage? = nil
    ) {
        self.group = group
        self.decisionState = decisionState
        self.thumbnail = thumbnail
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Decision indicator
            if let state = decisionState, state != .undecided {
                Image(systemName: state.systemImage)
                    .foregroundStyle(state.badgeColor)
                    .font(.caption)
            }

            // Thumbnail (when provided)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Left: confidence badge + group info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Group \(group.groupIndex)")
                        .font(.callout.bold())
                    ConfidenceBadge(confidence: group.confidence)
                }

                // Representative path
                if let keeper = group.suggestedKeeperPath {
                    Text(URL(fileURLWithPath: keeper).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Right: stats + risk badges
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(group.memberCount) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatBytes(group.spaceSavings))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    if group.isLargeGroup {
                        RiskBadge(
                            label: "Large",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                    if group.isMixedFormat {
                        RiskBadge(
                            label: "Mixed",
                            systemImage: "doc.on.doc",
                            color: .blue
                        )
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
