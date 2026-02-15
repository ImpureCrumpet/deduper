import SwiftUI

/// A single session row in the sidebar.
public struct SessionRowView: View {
    public let session: SessionIndex

    public init(session: SessionIndex) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Directory name
            Text(directoryName)
                .font(.callout.bold())
                .lineLimit(1)
                .truncationMode(.head)

            // Stats line
            HStack(spacing: 8) {
                Label(
                    "\(session.duplicateGroups)",
                    systemImage: "square.stack.3d.up"
                )
                Label(
                    "\(session.mediaFiles) files",
                    systemImage: "photo.on.rectangle"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Date
            Text(session.startedAt.formatted(
                .dateTime.month(.abbreviated).day().year()
                    .hour().minute()
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var directoryName: String {
        let url = URL(fileURLWithPath: session.directoryPath)
        return url.lastPathComponent
    }
}
