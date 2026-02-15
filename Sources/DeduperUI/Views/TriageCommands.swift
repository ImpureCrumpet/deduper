import SwiftUI

/// Menu-bar commands for triage review shortcuts.
/// Reads actions from a shared `TriageActionBridge` observable.
public struct TriageCommands: Commands {
    @ObservedObject var bridge: TriageActionBridge

    public init(bridge: TriageActionBridge) {
        self._bridge = ObservedObject(wrappedValue: bridge)
    }

    public var body: some Commands {
        CommandMenu("Review") {
            Button("Approve") { bridge.approve?() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!bridge.isActive)

            Button("Skip") { bridge.skip?() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!bridge.isActive)

            Button("Not Duplicate") {
                bridge.markNotDuplicate?()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!bridge.isActive)

            Divider()

            Button("Next Group") { bridge.selectNext?() }
                .keyboardShortcut("j", modifiers: [.control])
                .disabled(!bridge.isActive)

            Button("Previous Group") {
                bridge.selectPrevious?()
            }
            .keyboardShortcut("k", modifiers: [.control])
            .disabled(!bridge.isActive)

            Button("Next Undecided") {
                bridge.selectNextUndecided?()
            }
            .keyboardShortcut("u", modifiers: [.control])
            .disabled(!bridge.isActive)
        }
    }
}
