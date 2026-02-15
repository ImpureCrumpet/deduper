import SwiftUI
import DeduperKit

/// Displays confidence signals, penalties, and rationale for a group.
public struct EvidencePanel: View {
    public let groupRationale: [String]
    public let members: [MemberDetail]
    public let incomplete: Bool

    public init(
        groupRationale: [String],
        members: [MemberDetail],
        incomplete: Bool = false
    ) {
        self.groupRationale = groupRationale
        self.members = members
        self.incomplete = incomplete
    }

    private var hasSignalData: Bool {
        members.contains { !$0.signals.isEmpty }
    }

    public var body: some View {
        GroupBox("Evidence") {
            VStack(alignment: .leading, spacing: 12) {
                if !hasSignalData {
                    Label(
                        "Signal data not available — re-scan for"
                        + " detailed evidence.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    // Group rationale
                    if !groupRationale.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Group Rationale")
                                .font(.caption.bold())
                            ForEach(
                                groupRationale, id: \.self
                            ) { line in
                                HStack(alignment: .top, spacing: 4) {
                                    Text("•")
                                    Text(line)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if incomplete {
                        Label(
                            "Incomplete — bucket overflow",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    // Per-member evidence
                    ForEach(members) { member in
                        memberEvidence(member)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func memberEvidence(
        _ member: MemberDetail
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !member.signals.isEmpty {
                    signalTable(member.signals)
                }
                if !member.penalties.isEmpty {
                    penaltyTable(member.penalties)
                }
                if !member.rationale.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rationale")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        ForEach(
                            member.rationale, id: \.self
                        ) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if member.isKeeper {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                }
                Text(member.fileName)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let conf = member.confidence {
                    Text(String(format: "%.0f%%", conf * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func signalTable(
        _ signals: [ConfidenceSignal]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Signals")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ForEach(
                Array(signals.enumerated()), id: \.offset
            ) { _, signal in
                HStack(spacing: 6) {
                    Circle()
                        .fill(signalColor(signal.contribution))
                        .frame(width: 6, height: 6)
                    Text(signal.key)
                        .font(.caption2.bold())
                        .frame(width: 70, alignment: .leading)
                    Text(signal.rationale)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Text(
                        String(
                            format: "+%.2f", signal.contribution
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
                }
            }
        }
    }

    private func penaltyTable(
        _ penalties: [ConfidencePenalty]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Penalties")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ForEach(
                Array(penalties.enumerated()), id: \.offset
            ) { _, penalty in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(penalty.key)
                        .font(.caption2.bold())
                        .frame(width: 70, alignment: .leading)
                    Text(penalty.rationale)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Text(
                        String(format: "%.2f", penalty.value)
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private func signalColor(
        _ contribution: Double
    ) -> Color {
        if contribution >= 0.40 { return .green }
        if contribution >= 0.20 { return .blue }
        return .gray
    }
}
