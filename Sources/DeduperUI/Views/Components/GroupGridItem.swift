import SwiftUI
import AppKit

/// Grid card showing a keeper thumbnail, group info, and decision state.
public struct GroupGridItem: View {
    public let group: GroupSummary
    public let decisionState: DecisionState?
    public let thumbnail: NSImage?
    public let isSelected: Bool

    public init(
        group: GroupSummary,
        decisionState: DecisionState? = nil,
        thumbnail: NSImage? = nil,
        isSelected: Bool = false
    ) {
        self.group = group
        self.decisionState = decisionState
        self.thumbnail = thumbnail
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Thumbnail area
            ZStack(alignment: .topLeading) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 120,
                            maxHeight: 120
                        )
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.quaternary.opacity(0.3))
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 120,
                            maxHeight: 120
                        )
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                }

                // Decision badge overlay
                if let state = decisionState, state != .undecided {
                    Image(systemName: state.systemImage)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(state.badgeColor)
                        .clipShape(Circle())
                        .padding(6)
                }
            }

            // Info area
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Group \(group.groupIndex)")
                        .font(.caption.bold())
                        .lineLimit(1)
                    Spacer()
                    ConfidenceBadge(confidence: group.confidence)
                }

                if let keeper = group.suggestedKeeperPath {
                    Text(
                        URL(fileURLWithPath: keeper)
                            .lastPathComponent
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                HStack(spacing: 4) {
                    Text("\(group.memberCount) files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatBytes(group.spaceSavings))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : .clear,
                    lineWidth: 2
                )
        )
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        .contextMenu {
            if let keeper = group.suggestedKeeperPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: keeper)]
                    )
                } label: {
                    Label(
                        "Reveal in Finder",
                        systemImage: "folder"
                    )
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        keeper, forType: .string
                    )
                } label: {
                    Label(
                        "Copy Keeper Path",
                        systemImage: "doc.on.doc"
                    )
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
