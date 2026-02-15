import SwiftUI
import DeduperKit

/// Side-by-side metadata comparison with quality hints.
/// Green highlight marks the "strongest" value per field.
public struct MetadataDiffPanel: View {
    public let members: [MemberDetail]

    public init(members: [MemberDetail]) {
        self.members = members
    }

    public var body: some View {
        let membersWithMetadata = members.filter {
            $0.metadata != nil
        }
        if membersWithMetadata.count >= 2 {
            GroupBox("Quality Hints") {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, verticalSpacing: 4) {
                        headerRow(membersWithMetadata)

                        Divider()

                        hintRow(
                            "Size",
                            membersWithMetadata,
                            value: { formatBytes($0.fileSize) },
                            rank: { Double($0.fileSize) }
                        )

                        hintRow(
                            "Dimensions",
                            membersWithMetadata,
                            value: {
                                $0.metadata?.dimensions.map {
                                    "\($0.width)×\($0.height)"
                                } ?? "—"
                            },
                            rank: {
                                guard let d = $0.metadata?.dimensions
                                else { return nil }
                                return Double(d.width * d.height)
                            }
                        )

                        hintRow(
                            "Captured",
                            membersWithMetadata,
                            value: {
                                $0.metadata?.captureDate?.formatted(
                                    .dateTime.month().day().year()
                                ) ?? "—"
                            },
                            rank: {
                                // Earliest capture date is preferred
                                // (more likely original). Negate so
                                // smallest date gets highest rank.
                                guard let d = $0.metadata?.captureDate
                                else { return nil }
                                return -d.timeIntervalSince1970
                            }
                        )

                        hintRow(
                            "Camera",
                            membersWithMetadata,
                            value: {
                                $0.metadata?.cameraModel ?? "—"
                            },
                            rank: {
                                // Has camera model > doesn't
                                $0.metadata?.cameraModel != nil
                                    ? 1.0 : nil
                            }
                        )

                        hintRow(
                            "Duration",
                            membersWithMetadata,
                            value: {
                                $0.metadata?.durationSec.map {
                                    formatDuration($0)
                                } ?? "—"
                            },
                            rank: {
                                $0.metadata?.durationSec
                            }
                        )

                        Divider()

                        // Metadata completeness row
                        hintRow(
                            "Completeness",
                            membersWithMetadata,
                            value: {
                                let count = metadataFieldCount($0)
                                return "\(count)/6 fields"
                            },
                            rank: {
                                Double(metadataFieldCount($0))
                            }
                        )
                    }
                    .padding(4)
                }
            }
        }
    }

    // MARK: - Header

    private func headerRow(
        _ members: [MemberDetail]
    ) -> some View {
        GridRow {
            Text("Field")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(members) { m in
                HStack(spacing: 4) {
                    if m.isKeeper {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                    }
                    Text(m.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.bold())
                .frame(minWidth: 120)
            }
        }
    }

    // MARK: - Hint Row

    private func hintRow(
        _ label: String,
        _ members: [MemberDetail],
        value: @escaping (MemberDetail) -> String,
        rank: @escaping (MemberDetail) -> Double?
    ) -> some View {
        let ranks = members.map { rank($0) }
        let maxRank = ranks.compactMap { $0 }.max()
        // Only highlight if there's a clear winner (not all equal)
        let allEqual = Set(ranks.compactMap { $0 }).count <= 1

        return GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(members.enumerated()), id: \.element.id) {
                idx, m in
                let val = value(m)
                let isHint = !allEqual
                    && ranks[idx] != nil
                    && ranks[idx] == maxRank
                Text(val)
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 120, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        isHint
                            ? Color.green.opacity(0.15)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(alignment: .trailing) {
                        if isHint {
                            Image(
                                systemName: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                            .font(.caption2)
                            .padding(.trailing, 2)
                        }
                    }
            }
        }
    }

    // MARK: - Helpers

    private func metadataFieldCount(
        _ member: MemberDetail
    ) -> Int {
        guard let m = member.metadata else { return 0 }
        var count = 0
        if m.dimensions != nil { count += 1 }
        if m.captureDate != nil { count += 1 }
        if m.cameraModel != nil { count += 1 }
        if m.durationSec != nil { count += 1 }
        if m.gpsLat != nil { count += 1 }
        if m.gpsLon != nil { count += 1 }
        return count
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
