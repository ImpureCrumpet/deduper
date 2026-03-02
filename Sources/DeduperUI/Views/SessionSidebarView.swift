import SwiftUI
import SwiftData

/// Session list sidebar. Discovers and lists CLI-created sessions.
public struct SessionSidebarView: View {
    @Bindable public var viewModel: SessionListViewModel
    @Environment(\.modelContext) private var modelContext

    @State private var showingScanSheet = false

    public init(viewModel: SessionListViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List(
            viewModel.sessions,
            id: \.sessionId,
            selection: $viewModel.selectedSessionIds
        ) { session in
            SessionRowView(session: session)
                .tag(session.sessionId)
                .contextMenu {
                    // "Remove" acts on the right-clicked session;
                    // if it's part of a multi-selection, remove all
                    // selected. Otherwise just remove the one.
                    let target: Set<UUID> = viewModel
                        .selectedSessionIds
                        .contains(session.sessionId)
                        ? viewModel.selectedSessionIds
                        : [session.sessionId]
                    Button(role: .destructive) {
                        viewModel.deleteSessions(
                            target,
                            context: modelContext
                        )
                    } label: {
                        Label(
                            target.count > 1
                                ? "Remove \(target.count) Sessions"
                                : "Remove Session",
                            systemImage: "trash"
                        )
                    }
                }
        }
        .listStyle(.sidebar)
        // Sync the active content session to the most-recently
        // clicked item in the multi-select set.
        .onChange(of: viewModel.selectedSessionIds) { _, newIds in
            if let first = newIds.first,
               !viewModel.selectedSessionIds.isEmpty
            {
                // Only update active session when selection changes
                // to a single item or first item of a new selection.
                if newIds.count == 1 {
                    viewModel.selectedSessionId = first
                }
            }
        }
        .overlay {
            if viewModel.sessions.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "folder.badge.questionmark",
                    description: Text(
                        "Click + to scan directories,"
                        + " or run \"deduper scan\" from the CLI."
                    )
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingScanSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .help("New scan")
            }
            ToolbarItem {
                Button {
                    viewModel.loadSessions(context: modelContext)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh sessions")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    viewModel.deleteSessions(
                        viewModel.selectedSessionIds,
                        context: modelContext
                    )
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(viewModel.selectedSessionIds.isEmpty)
                .help(
                    viewModel.selectedSessionIds.count > 1
                        ? "Remove \(viewModel.selectedSessionIds.count) selected sessions"
                        : "Remove selected session"
                )
            }
        }
        .sheet(isPresented: $showingScanSheet) {
            ScanSheet { sessionId in
                viewModel.loadSessions(context: modelContext)
                viewModel.selectedSessionId = sessionId
            }
        }
        .onAppear {
            viewModel.loadSessions(context: modelContext)
        }
    }
}
