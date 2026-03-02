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
            selection: $viewModel.selectedSessionId
        ) { session in
            SessionRowView(session: session)
                .tag(session.sessionId)
                .contextMenu {
                    Button(role: .destructive) {
                        viewModel.deleteSession(
                            session.sessionId,
                            context: modelContext
                        )
                    } label: {
                        Label(
                            "Remove Session",
                            systemImage: "trash"
                        )
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        viewModel.deleteSession(
                            session.sessionId,
                            context: modelContext
                        )
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
        }
        .listStyle(.sidebar)
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
