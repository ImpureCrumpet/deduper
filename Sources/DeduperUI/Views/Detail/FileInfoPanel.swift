import SwiftUI
import DeduperKit

/// Metadata facts panel for a selected member.
/// Labeled "File Info" (not "Evidence") — shows only what's known from
/// file metadata, not detection confidence signals.
public struct FileInfoPanel: View {
    public let member: MemberDetail

    public init(member: MemberDetail) {
        self.member = member
    }

    public var body: some View {
        GroupBox("File Info") {
            Grid(alignment: .leading, verticalSpacing: 4) {
                infoRow("Path", value: member.path)
                infoRow("Size", value: formatBytes(member.fileSize))

                if let meta = member.metadata {
                    if let dims = meta.dimensions {
                        infoRow(
                            "Dimensions",
                            value: "\(dims.width) × \(dims.height)"
                        )
                    }
                    if let date = meta.captureDate {
                        infoRow(
                            "Captured",
                            value: date.formatted(
                                .dateTime.month().day().year()
                                    .hour().minute()
                            )
                        )
                    }
                    if let camera = meta.cameraModel {
                        infoRow("Camera", value: camera)
                    }
                    if let lat = meta.gpsLat,
                       let lon = meta.gpsLon {
                        infoRow(
                            "GPS",
                            value: String(
                                format: "%.4f, %.4f", lat, lon
                            )
                        )
                    }
                    if let duration = meta.durationSec {
                        infoRow(
                            "Duration",
                            value: formatDuration(duration)
                        )
                    }
                    if let uttype = meta.inferredUTType {
                        infoRow("Type", value: uttype)
                    }
                }
            }
            .font(.caption)
        }
    }

    private func infoRow(
        _ label: String, value: String
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
