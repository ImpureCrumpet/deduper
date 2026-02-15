import SwiftUI
import DeduperKit

/// Sort and filter controls for the group list.
public struct GroupFilterBar: View {
    @Bindable public var viewModel: GroupListViewModel

    public init(viewModel: GroupListViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: Sort + type pickers
            HStack(spacing: 8) {
                Picker("Sort", selection: $viewModel.sortOrder) {
                    ForEach(
                        GroupSortOrder.allCases, id: \.self
                    ) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Button {
                    viewModel.sortAscending.toggle()
                } label: {
                    Image(systemName: viewModel.sortAscending
                        ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.borderless)
                .help(
                    viewModel.sortAscending
                        ? "Ascending" : "Descending"
                )

                Divider().frame(height: 16)

                Picker("Type", selection: $viewModel.mediaTypeFilter) {
                    Text("All Types")
                        .tag(nil as Int16?)
                    Text("Photos")
                        .tag(MediaType.photo.rawValue as Int16?)
                    Text("Videos")
                        .tag(MediaType.video.rawValue as Int16?)
                    Text("Audio")
                        .tag(MediaType.audio.rawValue as Int16?)
                }
                .pickerStyle(.menu)
                .fixedSize()

                Picker("Basis", selection: $viewModel.matchKindFilter) {
                    Text("All").tag(nil as String?)
                    ForEach(
                        MatchKind.filterableCases, id: \.self
                    ) { kind in
                        Text(kind.displayName).tag(
                            kind.rawValue as String?
                        )
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Spacer()

                // View mode toggle
                Picker("View", selection: $viewModel.listMode) {
                    ForEach(
                        GroupListMode.allCases, id: \.self
                    ) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            // Row 2: Status filter + risk toggles + auto-advance
            HStack(spacing: 12) {
                Picker(
                    "Status",
                    selection: $viewModel.decisionStateFilter
                ) {
                    Text("All").tag(nil as DecisionState?)
                    Text("Pending")
                        .tag(DecisionState.undecided as DecisionState?)
                    Text("Approved")
                        .tag(DecisionState.approved as DecisionState?)
                    Text("Skipped")
                        .tag(DecisionState.skipped as DecisionState?)
                    Text("Not Dup")
                        .tag(
                            DecisionState.notDuplicate
                                as DecisionState?
                        )
                }
                .pickerStyle(.menu)
                .fixedSize()

                Toggle(
                    "Large groups",
                    isOn: $viewModel.showLargeGroupsOnly
                )
                .toggleStyle(.checkbox)
                Toggle(
                    "Mixed format",
                    isOn: $viewModel.showMixedFormatOnly
                )
                .toggleStyle(.checkbox)

                Spacer()

                Picker(
                    "Advance",
                    selection: $viewModel.autoAdvanceMode
                ) {
                    ForEach(
                        AutoAdvanceMode.allCases, id: \.self
                    ) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
