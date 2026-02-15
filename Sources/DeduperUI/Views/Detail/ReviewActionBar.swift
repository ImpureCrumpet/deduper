import SwiftUI

/// Toolbar with review decision buttons.
/// Keyboard shortcuts are handled by `TriageCommands` via focused values,
/// not by button-level `.keyboardShortcut()` modifiers.
public struct ReviewActionBar: View {
    public let decisionState: DecisionState
    public let members: [MemberDetail]
    public let onApprove: () -> Void
    public let onSkip: () -> Void
    public let onNotDuplicate: () -> Void
    public let onChangeKeeper: (String) -> Void
    @Binding public var showRename: Bool

    public init(
        decisionState: DecisionState,
        members: [MemberDetail],
        onApprove: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onNotDuplicate: @escaping () -> Void,
        onChangeKeeper: @escaping (String) -> Void,
        showRename: Binding<Bool> = .constant(false)
    ) {
        self.decisionState = decisionState
        self.members = members
        self.onApprove = onApprove
        self.onSkip = onSkip
        self.onNotDuplicate = onNotDuplicate
        self.onChangeKeeper = onChangeKeeper
        self._showRename = showRename
    }

    public var body: some View {
        HStack(spacing: 12) {
            DecisionStateBadge(state: decisionState)

            Spacer()

            renameToggle
            approveButton
            skipButton
            changeKeeperMenu
            notDuplicateButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var approveButton: some View {
        Button(action: onApprove) {
            Label("Approve", systemImage: "checkmark.circle.fill")
        }
        .disabled(members.isEmpty)
        .help("Approve — accept suggested keeper (⏎)")
    }

    private var skipButton: some View {
        Button(action: onSkip) {
            Label("Skip", systemImage: "forward.fill")
        }
        .disabled(members.isEmpty)
        .help("Skip — decide later (⌘→)")
    }

    private var changeKeeperMenu: some View {
        Menu {
            ForEach(
                members.filter({ !$0.isKeeper }),
                id: \.id
            ) { member in
                Button(member.fileName) {
                    onChangeKeeper(member.path)
                }
            }
        } label: {
            Label(
                "Change Keeper",
                systemImage: "arrow.left.arrow.right"
            )
        }
        .disabled(members.count < 2)
        .help("Change which file is the keeper")
    }

    private var renameToggle: some View {
        Button {
            showRename.toggle()
        } label: {
            Label(
                "Rename",
                systemImage: showRename
                    ? "pencil.circle.fill" : "pencil.circle"
            )
        }
        .disabled(members.isEmpty)
        .help("Toggle rename editor")
    }

    private var notDuplicateButton: some View {
        Button(action: onNotDuplicate) {
            Label("Not Duplicate", systemImage: "xmark.circle")
        }
        .disabled(members.isEmpty)
        .help("Mark as not duplicate (⌫)")
    }
}
