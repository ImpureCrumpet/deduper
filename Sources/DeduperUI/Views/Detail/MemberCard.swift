import SwiftUI
import AppKit

/// Card displaying a single member in a duplicate group.
public struct MemberCard: View {
    public let member: MemberDetail

    @State private var showPreview = false

    public init(member: MemberDetail) {
        self.member = member
    }

    public var body: some View {
        VStack(spacing: 6) {
            // Thumbnail or placeholder — double-click for Quick Look
            thumbnailView
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if member.fileExists {
                        showPreview = true
                    }
                }
                .popover(isPresented: $showPreview) {
                    QuickLookPreview(
                        url: URL(fileURLWithPath: member.path)
                    )
                    .frame(width: 600, height: 600)
                }

            // File name
            Text(member.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            // File size
            Text(formatBytes(member.fileSize))
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Badges
            HStack(spacing: 4) {
                if member.isKeeper {
                    Text("Keeper")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
                if !member.fileExists {
                    Text("Missing")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
                if !member.companions.isEmpty {
                    Text("\(member.companions.count) sidecars")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.1))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(member.isKeeper
                    ? Color.green.opacity(0.05)
                    : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    member.isKeeper ? .green.opacity(0.3) : .clear,
                    lineWidth: 1
                )
        )
        .contextMenu {
            if member.fileExists {
                Button {
                    showPreview = true
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }

                Button {
                    let url = URL(
                        fileURLWithPath: member.path
                    )
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [url]
                    )
                } label: {
                    Label(
                        "Reveal in Finder",
                        systemImage: "folder"
                    )
                }

                Divider()
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    member.path, forType: .string
                )
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    member.fileName, forType: .string
                )
            } label: {
                Label(
                    "Copy Filename",
                    systemImage: "doc.on.clipboard"
                )
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let data = member.thumbnailData,
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if !member.fileExists {
            ZStack {
                Color(.windowBackgroundColor)
                VStack(spacing: 4) {
                    Image(systemName: "questionmark.folder")
                        .font(.title2)
                    Text("File Missing")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        } else {
            ZStack {
                Color(.windowBackgroundColor)
                ProgressView()
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
