import SwiftUI
import SwiftData

/// Detail pane: comparison-first layout with metadata diff and member details.
public struct GroupDetailView: View {
    @Bindable public var viewModel: GroupDetailViewModel
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var triageBridge: TriageActionBridge

    /// Navigation closures delegated from the list VM.
    public var onSelectNext: (() -> Void)?
    public var onSelectPrevious: (() -> Void)?
    public var onSelectNextUndecided: (() -> Void)?

    public init(
        viewModel: GroupDetailViewModel,
        onSelectNext: (() -> Void)? = nil,
        onSelectPrevious: (() -> Void)? = nil,
        onSelectNextUndecided: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onSelectNext = onSelectNext
        self.onSelectPrevious = onSelectPrevious
        self.onSelectNextUndecided = onSelectNextUndecided
    }

    public var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading group...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if viewModel.members.isEmpty {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "square.dashed",
                    description: Text(
                        "Select a group to view its members."
                    )
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Review zone
                        VStack(alignment: .leading, spacing: 16) {
                            GroupDetailHeader(
                                groupIndex: viewModel.groupIndex,
                                confidence: viewModel.confidence,
                                matchBasis: viewModel.matchBasis,
                                matchKind: viewModel.matchKind,
                                memberCount: viewModel.members.count
                            )

                            ReviewActionBar(
                                decisionState: viewModel
                                    .currentDecision,
                                members: viewModel.members,
                                onApprove: {
                                    viewModel.approve(
                                        context: modelContext
                                    )
                                },
                                onSkip: {
                                    viewModel.skip(
                                        context: modelContext
                                    )
                                },
                                onNotDuplicate: {
                                    viewModel.markNotDuplicate(
                                        context: modelContext
                                    )
                                },
                                onChangeKeeper: { path in
                                    viewModel.changeKeeper(
                                        to: path,
                                        context: modelContext
                                    )
                                },
                                showRename: $viewModel.showRename
                            )

                            if viewModel.members.count >= 2 {
                                ComparisonView(
                                    members: viewModel.members
                                )
                            }

                            MetadataDiffPanel(
                                members: viewModel.members
                            )
                        }

                        // Editing zone — when rename is active,
                        // bridge deactivates to suppress shortcuts.
                        if viewModel.showRename,
                           let keeper = viewModel.members.first(
                               where: { $0.isKeeper }
                           ) {
                            RenameEditor(
                                template: $viewModel.renameTemplate,
                                keeperFileName: keeper.fileName,
                                companionFileNames: keeper.companions
                                    .map {
                                        URL(fileURLWithPath: $0)
                                            .lastPathComponent
                                    },
                                onSave: {
                                    viewModel.saveRenameTemplate(
                                        context: modelContext
                                    )
                                }
                            )
                        }

                        EvidencePanel(
                            groupRationale: viewModel.groupRationale,
                            members: viewModel.members,
                            incomplete: viewModel.incomplete
                        )

                        DisclosureGroup("Member Details") {
                            MemberThumbnailGrid(
                                members: viewModel.members
                            )

                            ForEach(viewModel.members) { member in
                                FileInfoPanel(member: member)
                                CompanionPanel(
                                    companions: member.companions
                                )
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .onChange(of: isReviewReady) { _, ready in
            syncBridge(ready: ready)
        }
        .onChange(of: viewModel.currentGroupId) { _, _ in
            syncBridge(ready: isReviewReady)
        }
        .onAppear {
            syncBridge(ready: isReviewReady)
        }
        .onDisappear {
            triageBridge.deactivate()
        }
    }

    /// True when the detail has members and rename is not active.
    private var isReviewReady: Bool {
        !viewModel.isLoading
            && !viewModel.members.isEmpty
            && !viewModel.showRename
    }

    /// Activates or deactivates the triage bridge.
    private func syncBridge(ready: Bool) {
        if ready {
            triageBridge.activate(
                approve: {
                    viewModel.approve(context: modelContext)
                },
                skip: {
                    viewModel.skip(context: modelContext)
                },
                markNotDuplicate: {
                    viewModel.markNotDuplicate(
                        context: modelContext
                    )
                },
                selectNext: { onSelectNext?() },
                selectPrevious: { onSelectPrevious?() },
                selectNextUndecided: {
                    onSelectNextUndecided?()
                }
            )
        } else {
            triageBridge.deactivate()
        }
    }
}
