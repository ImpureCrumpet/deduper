import SwiftUI
import SwiftData

/// Virtualized group list with filter bar, stats, and search.
public struct GroupListView: View {
    @Bindable public var viewModel: GroupListViewModel
    @Bindable public var detailViewModel: GroupDetailViewModel
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var triageBridge: TriageActionBridge
    public let modelContainer: ModelContainer
    public var onMergeApproved: (() -> Void)?

    public init(
        viewModel: GroupListViewModel,
        detailViewModel: GroupDetailViewModel,
        modelContainer: ModelContainer,
        onMergeApproved: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.detailViewModel = detailViewModel
        self.modelContainer = modelContainer
        self.onMergeApproved = onMergeApproved
    }

    private let gridColumns = [
        GridItem(
            .adaptive(minimum: 160, maximum: 220),
            spacing: 8
        ),
    ]

    public var body: some View {
        VStack(spacing: 0) {
            GroupFilterBar(viewModel: viewModel)
            Divider()
            GroupStatsBar(
                totalGroups: viewModel.totalGroups,
                filteredCount: viewModel.filteredCount,
                totalSpaceSavings: viewModel.totalSpaceSavings,
                reviewedCount: viewModel.reviewedCount,
                undecidedExactCount: viewModel.undecidedExactCount,
                approvedCount: approvedCount,
                mergedCount: mergedCount,
                onBatchApproveExact: {
                    viewModel.batchApproveExactMatches(
                        context: modelContext
                    )
                },
                onMergeApproved: onMergeApproved
            )
            Divider()

            switch viewModel.listMode {
            case .list:
                listContent(showThumbnails: false)
            case .listThumbnails:
                listContent(showThumbnails: true)
            case .grid:
                gridContent
            }
        }
        .searchable(
            text: $viewModel.searchText,
            prompt: "Search by filename..."
        )
        .modifier(SearchFocusSuppressor(bridge: triageBridge))
        .overlay {
            if viewModel.allGroups.isEmpty {
                ContentUnavailableView(
                    "No Groups",
                    systemImage: "photo.stack",
                    description: Text(
                        "Select a session to view duplicate groups."
                    )
                )
            } else if viewModel.filteredGroups.isEmpty {
                ContentUnavailableView.search
            }
        }
        .onChange(of: viewModel.selectedGroupId) { _, newId in
            if let newId,
               let group = viewModel.filteredGroups.first(
                   where: { $0.groupId == newId }
               ) {
                detailViewModel.onDecisionChanged = {
                    groupId, snapshot in
                    viewModel.commitDecision(
                        groupId: groupId,
                        snapshot: snapshot
                    )
                }
                detailViewModel.loadGroup(
                    groupSummary: group,
                    container: modelContainer,
                    context: modelContext
                )
            } else {
                detailViewModel.clear()
            }
        }
        // Thumbnails load lazily via onAppear per row/grid item.
        // No bulk prefetch on mode change to avoid unbounded
        // concurrent tasks for large sessions.
    }

    private var approvedCount: Int {
        viewModel.decisionByGroupId.values.count {
            $0.state == .approved
        }
    }

    private var mergedCount: Int {
        viewModel.decisionByGroupId.values.count {
            $0.state == .merged
        }
    }

    // MARK: - List Mode

    private func listContent(
        showThumbnails: Bool
    ) -> some View {
        List(
            viewModel.filteredGroups,
            id: \.groupId,
            selection: $viewModel.selectedGroupId
        ) { group in
            GroupRowView(
                group: group,
                decisionState: viewModel
                    .decisionByGroupId[group.groupId]?.state,
                thumbnail: showThumbnails
                    ? viewModel.thumbnailByGroupId[group.groupId]
                    : nil
            )
            .tag(group.groupId)
            .onAppear {
                if showThumbnails {
                    viewModel.loadThumbnails(for: [group])
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Grid Mode

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(
                    viewModel.filteredGroups, id: \.groupId
                ) { group in
                    GroupGridItem(
                        group: group,
                        decisionState: viewModel
                            .decisionByGroupId[group.groupId]?
                            .state,
                        thumbnail: viewModel
                            .thumbnailByGroupId[group.groupId],
                        isSelected: viewModel.selectedGroupId
                            == group.groupId
                    )
                    .onTapGesture {
                        viewModel.selectedGroupId = group.groupId
                    }
                    .onAppear {
                        viewModel.loadThumbnails(for: [group])
                    }
                }
            }
            .padding(8)
        }
    }
}

/// Modifier that drives `TriageActionBridge.suppressShortcuts`
/// from search-field focus state. `.searchFocused` requires
/// macOS 15+; on macOS 14 we fall back to AppKit text-editing
/// notifications, which suppress shortcuts for any text field
/// (search, rename, etc.).
private struct SearchFocusSuppressor: ViewModifier {
    let bridge: TriageActionBridge

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(
                SearchFocusBinding(bridge: bridge)
            )
        } else {
            content.modifier(
                TextEditSuppressor(bridge: bridge)
            )
        }
    }
}

@available(macOS 15.0, *)
private struct SearchFocusBinding: ViewModifier {
    let bridge: TriageActionBridge
    @FocusState private var searchFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchFocused($searchFocused)
            .onChange(of: searchFocused) { _, focused in
                bridge.suppressShortcuts = focused
            }
    }
}

/// Pre-macOS 15 fallback: suppress shortcuts while any NSControl
/// text field is being edited, using AppKit notifications.
private struct TextEditSuppressor: ViewModifier {
    let bridge: TriageActionBridge

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSControl
                        .textDidBeginEditingNotification
                )
            ) { _ in
                bridge.suppressShortcuts = true
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSControl
                        .textDidEndEditingNotification
                )
            ) { _ in
                bridge.suppressShortcuts = false
            }
    }
}

