import SwiftUI
import SwiftData

/// Virtualized group list with filter bar, stats, and search.
public struct GroupListView: View {
    @Bindable public var viewModel: GroupListViewModel
    @Bindable public var detailViewModel: GroupDetailViewModel
    @Environment(\.modelContext) private var modelContext
    public let modelContainer: ModelContainer

    public init(
        viewModel: GroupListViewModel,
        detailViewModel: GroupDetailViewModel,
        modelContainer: ModelContainer
    ) {
        self.viewModel = viewModel
        self.detailViewModel = detailViewModel
        self.modelContainer = modelContainer
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
                onBatchApproveExact: {
                    viewModel.batchApproveExactMatches(
                        context: modelContext
                    )
                }
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
        .onChange(of: viewModel.listMode) { _, mode in
            if mode != .list {
                viewModel.loadThumbnails(
                    for: viewModel.filteredGroups
                )
            }
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

