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
                .disabled(!bridge.shortcutsEnabled)

            Button("Skip") { bridge.skip?() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!bridge.shortcutsEnabled)

            Button("Not Duplicate") {
                bridge.markNotDuplicate?()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!bridge.shortcutsEnabled)

            Divider()

            Button("Next Group") { bridge.selectNext?() }
                .keyboardShortcut("j", modifiers: [.control])
                .disabled(!bridge.shortcutsEnabled)

            Button("Previous Group") {
                bridge.selectPrevious?()
            }
            .keyboardShortcut("k", modifiers: [.control])
            .disabled(!bridge.shortcutsEnabled)

            Button("Next Undecided") {
                bridge.selectNextUndecided?()
            }
            .keyboardShortcut("u", modifiers: [.control])
            .disabled(!bridge.shortcutsEnabled)
        }
    }
}
