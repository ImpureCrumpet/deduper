import SwiftUI

/// Aggregate stats bar showing group counts and potential space savings.
public struct GroupStatsBar: View {
    public let totalGroups: Int
    public let filteredCount: Int
    public let totalSpaceSavings: Int64
    public let reviewedCount: Int
    public let undecidedExactCount: Int
    public let approvedCount: Int
    public let onBatchApproveExact: (() -> Void)?
    public let onMergeApproved: (() -> Void)?

    @State private var showBatchConfirm = false

    public init(
        totalGroups: Int,
        filteredCount: Int,
        totalSpaceSavings: Int64,
        reviewedCount: Int = 0,
        undecidedExactCount: Int = 0,
        approvedCount: Int = 0,
        onBatchApproveExact: (() -> Void)? = nil,
        onMergeApproved: (() -> Void)? = nil
    ) {
        self.totalGroups = totalGroups
        self.filteredCount = filteredCount
        self.totalSpaceSavings = totalSpaceSavings
        self.reviewedCount = reviewedCount
        self.undecidedExactCount = undecidedExactCount
        self.approvedCount = approvedCount
        self.onBatchApproveExact = onBatchApproveExact
        self.onMergeApproved = onMergeApproved
    }

    public var body: some View {
        HStack(spacing: 16) {
            Label(
                "\(filteredCount) of \(totalGroups) groups",
                systemImage: "square.stack.3d.up"
            )
            .font(.caption)

            Label(
                formatBytes(totalSpaceSavings) + " reclaimable",
                systemImage: "externaldrive"
            )
            .font(.caption)

            if totalGroups > 0 {
                Label(
                    "\(reviewedCount) of \(totalGroups) reviewed",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
            }

            Spacer()

            if undecidedExactCount > 0,
               let onBatch = onBatchApproveExact {
                Button {
                    showBatchConfirm = true
                } label: {
                    Label(
                        "Approve \(undecidedExactCount) Exact",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog(
                    "Batch Approve",
                    isPresented: $showBatchConfirm
                ) {
                    Button(
                        "Approve \(undecidedExactCount) exact matches"
                    ) {
                        onBatch()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Approve \(undecidedExactCount) byte-identical"
                        + " (SHA256) matches? This cannot be undone"
                        + " without resetting decisions."
                    )
                }
            }

            if approvedCount > 0, let onMerge = onMergeApproved {
                Button {
                    onMerge()
                } label: {
                    Label(
                        "Merge All \(approvedCount) Approved",
                        systemImage: "arrow.right.doc.on.clipboard"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
