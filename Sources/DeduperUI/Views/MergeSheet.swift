import SwiftUI
import SwiftData
import DeduperKit

/// Multi-phase sheet for merge preview, execution, and undo.
public struct MergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MergeViewModel
    let sessionId: UUID
    let modelContainer: ModelContainer

    public init(
        viewModel: MergeViewModel,
        sessionId: UUID,
        modelContainer: ModelContainer
    ) {
        self.viewModel = viewModel
        self.sessionId = sessionId
        self.modelContainer = modelContainer
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Merge Duplicates")
                .font(.title2.bold())
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            // Phase content
            Group {
                switch viewModel.phase {
                case .idle, .validating:
                    validatingContent
                case .preview(let plan):
                    previewContent(plan: plan)
                case .executing:
                    executingContent
                case .completed(let tx):
                    completedContent(transaction: tx)
                case .failed(let msg):
                    failedContent(message: msg)
                case .undoFailed(let failures, _):
                    undoFailedContent(failures: failures)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Button bar
            buttonBar
                .padding()
        }
        .frame(minWidth: 550, minHeight: 400)
        .onAppear {
            viewModel.validate(
                sessionId: sessionId,
                container: modelContainer
            )
        }
    }

    // MARK: - Phase Views

    private var validatingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Validating files...")
                .foregroundStyle(.secondary)
        }
    }

    private func previewContent(plan: MergePlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if plan.items.isEmpty {
                emptyPlanContent(plan: plan)
            } else {
                // Summary header
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Merges all approved decisions"
                            + " for this session"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 16) {
                        Label(
                            "\(plan.items.count) groups",
                            systemImage: "square.stack.3d.up"
                        )
                        Label(
                            "\(plan.totalFiles) files",
                            systemImage: "doc"
                        )
                        if plan.companionCount > 0 {
                            Label(
                                "+ \(plan.companionCount) companions",
                                systemImage: "paperclip"
                            )
                        }
                    }
                    .font(.headline)

                    if plan.missingNonKeeperCount > 0 {
                        Label(
                            "\(plan.missingNonKeeperCount) file(s)"
                                + " already missing, will be skipped",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding()

                Divider()

                // Plan items + warnings
                List {
                    if !plan.skippedGroups.isEmpty {
                        Section("Skipped Groups") {
                            ForEach(plan.skippedGroups) { warning in
                                warningRow(warning)
                            }
                        }
                    }

                    Section("Groups to Merge") {
                        ForEach(plan.items) { item in
                            planItemRow(item)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func emptyPlanContent(
        plan: MergePlan
    ) -> some View {
        VStack(spacing: 0) {
            Spacer()
            ContentUnavailableView {
                Label(
                    "Nothing to Merge",
                    systemImage: "checkmark.seal"
                )
            } description: {
                Text(emptyPlanExplanation(plan.emptyReason))
            }
            Spacer()

            if !plan.skippedGroups.isEmpty {
                Divider()
                List {
                    Section("Skipped Groups") {
                        ForEach(plan.skippedGroups) { warning in
                            warningRow(warning)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: 150)
            }
        }
    }

    private func emptyPlanExplanation(
        _ reason: MergeEmptyReason?
    ) -> String {
        switch reason {
        case .noApprovedDecisions:
            "No approved decisions found."
                + " Review and approve groups first."
        case .allAlreadyMerged(let count):
            "All \(count) approved group(s) have already been"
                + " merged."
        case .allSkippedDuringValidation:
            "All groups were skipped during validation."
                + " Check warnings below for details."
        case nil:
            "No actionable groups found for this session."
        }
    }

    private var executingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Moving files to quarantine...")
                .foregroundStyle(.secondary)
        }
    }

    private func completedContent(
        transaction: MergeTransaction
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Merge Complete",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.headline)
                .foregroundStyle(.green)

                HStack(spacing: 16) {
                    Label(
                        "\(transaction.filesMoved) files moved",
                        systemImage: "doc"
                    )
                    if transaction.errorCount > 0 {
                        Label(
                            "\(transaction.errorCount) errors",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)

                Text(
                    "Files have been moved to quarantine."
                        + " You can undo this operation to restore"
                        + " them."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()

            if !transaction.errors.isEmpty {
                Divider()
                List {
                    Section("Errors") {
                        ForEach(
                            transaction.errors,
                            id: \.originalPath
                        ) { error in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    URL(
                                        fileURLWithPath:
                                            error.originalPath
                                    ).lastPathComponent
                                )
                                .font(.caption.monospaced())
                                Text(error.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("Merge Failed")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func undoFailedContent(
        failures: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Undo Partially Failed",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Text(
                    "Some files could not be restored."
                        + " The transaction is preserved for retry."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            List {
                ForEach(failures, id: \.self) { failure in
                    Text(failure)
                        .font(.caption.monospaced())
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Row Views

    private func planItemRow(_ item: MergePlanItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Group \(item.groupIndex)")
                    .font(.caption.bold())
                Spacer()
                Text("\(item.totalFiles) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                URL(fileURLWithPath: item.keeperPath)
                    .lastPathComponent
            )
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

            ForEach(item.warnings) { warning in
                warningBadge(warning)
            }
        }
    }

    private func warningRow(
        _ warning: MergeValidationWarning
    ) -> some View {
        Label {
            Text(warning.message)
                .font(.caption)
        } icon: {
            Image(
                systemName: warning.isSkip
                    ? "xmark.circle" : "exclamationmark.triangle"
            )
            .foregroundStyle(warning.isSkip ? .red : .orange)
        }
    }

    private func warningBadge(
        _ warning: MergeValidationWarning
    ) -> some View {
        HStack(spacing: 4) {
            Image(
                systemName: "exclamationmark.triangle.fill"
            )
            .font(.caption2)
            Text(warning.message)
                .font(.caption2)
        }
        .foregroundStyle(.orange)
    }

    // MARK: - Button Bar

    @ViewBuilder
    private var buttonBar: some View {
        HStack {
            switch viewModel.phase {
            case .idle, .validating:
                Spacer()
                Button("Cancel") { dismiss() }

            case .preview(let plan):
                Spacer()
                if plan.items.isEmpty {
                    Button("Close") { dismiss() }
                } else {
                    Button("Cancel") { dismiss() }
                    Button("Merge \(plan.totalFiles) Files") {
                        viewModel.execute(
                            plan: plan,
                            container: modelContainer
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

            case .executing:
                Spacer()
                // No buttons while executing

            case .completed:
                Button("Undo Merge") {
                    viewModel.undoLastTransaction()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)

            case .failed:
                Spacer()
                Button("Close") { dismiss() }

            case .undoFailed:
                Button("Retry Undo") {
                    viewModel.undoLastTransaction()
                }
                Spacer()
                Button("Close") { dismiss() }
            }
        }
    }
}
