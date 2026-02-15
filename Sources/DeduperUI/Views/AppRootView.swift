import SwiftUI
import SwiftData

/// Root view with three-column NavigationSplitView layout.
/// Sidebar: session list. Content: group list. Detail: group detail.
public struct AppRootView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var sessionVM = SessionListViewModel()
    @State private var groupVM = GroupListViewModel()
    @State private var detailVM = GroupDetailViewModel()
    @State private var mergeVM = MergeViewModel()
    @State private var showMergeSheet = false

    @State private var columnVisibility: NavigationSplitViewVisibility =
        .all

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(viewModel: sessionVM)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } content: {
            GroupListView(
                viewModel: groupVM,
                detailViewModel: detailVM,
                modelContainer: modelContext.container,
                onMergeApproved: {
                    showMergeSheet = true
                }
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
            GroupDetailView(
                viewModel: detailVM,
                onSelectNext: { groupVM.selectNextGroup() },
                onSelectPrevious: { groupVM.selectPreviousGroup() },
                onSelectNextUndecided: {
                    groupVM.selectNextUndecided()
                }
            )
        }
        .navigationTitle("Deduper")
        .onChange(of: sessionVM.selectedSessionId) { _, newId in
            handleSessionChange(newId)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let progress = sessionVM.materializationProgress {
                    ProgressView(value: progress)
                        .frame(width: 100)
                        .help("Materializing groups...")
                }
            }
            ToolbarItem(placement: .automatic) {
                if let tx = mergeVM.lastTransaction,
                   mergeVM.lastMergedSessionId
                       == sessionVM.selectedSessionId {
                    Button {
                        mergeVM.undoLastTransaction()
                    } label: {
                        Label(
                            "Undo Merge (\(tx.filesMoved) files)",
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                }
            }
        }
        .onAppear { configureMergeCallback() }
        .sheet(isPresented: $showMergeSheet, onDismiss: {
            mergeVM.reset()
        }) {
            if let sid = sessionVM.selectedSessionId {
                MergeSheet(
                    viewModel: mergeVM,
                    sessionId: sid,
                    modelContainer: modelContext.container
                )
            }
        }
    }

    private var selectedSession: SessionIndex? {
        guard let id = sessionVM.selectedSessionId else {
            return nil
        }
        return sessionVM.sessions.first {
            $0.sessionId == id
        }
    }

    @discardableResult
    private func configureMergeCallback() -> Bool {
        mergeVM.onDecisionsTransitioned = {
            (groupIds: [UUID], targetState: DecisionState) in
            for gid in groupIds {
                groupVM.hydrateDecisionSnapshot(
                    groupId: gid,
                    snapshot: DecisionSnapshot(
                        state: targetState,
                        decidedAt: Date()
                    )
                )
            }
            groupVM.applyFilters()
        }
        return true
    }

    private func handleSessionChange(_ sessionId: UUID?) {
        groupVM.clear()
        detailVM.clear()

        guard let sessionId else { return }

        sessionVM.ensureMaterialized(
            sessionId: sessionId,
            container: modelContext.container
        ) { [modelContext] in
            // Fetch fresh from store to get updated currentRunId
            let sid = sessionId
            let pred = #Predicate<SessionIndex> {
                $0.sessionId == sid
            }
            var desc = FetchDescriptor<SessionIndex>(
                predicate: pred
            )
            desc.fetchLimit = 1
            let runId = try? modelContext.fetch(desc)
                .first?.currentRunId
            groupVM.loadGroups(
                sessionId: sessionId,
                currentRunId: runId,
                context: modelContext
            )
            groupVM.loadDecisionIndex(
                sessionId: sessionId,
                context: modelContext
            )
            // Resume: auto-select first undecided if partial progress
            if groupVM.reviewedCount > 0,
               groupVM.reviewedCount < groupVM.totalGroups {
                groupVM.selectNextUndecided()
            }
        }
    }
}
