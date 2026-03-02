import SwiftUI

/// Shared observable that bridges triage actions from the detail
/// view to the menu-bar Commands system.
///
/// Owned by the App as `@StateObject`, injected into the view
/// hierarchy via `@EnvironmentObject`, and read by
/// `TriageCommands` via `@ObservedObject`. When the detail view
/// has review-ready content, it sets `isActive = true` and
/// populates the action closures. When not ready (loading, empty,
/// rename editor open), it sets `isActive = false`.
///
/// This approach avoids the unreliable `@FocusedValue` /
/// `@FocusedObject` → Commands re-evaluation path on macOS.
@MainActor
public final class TriageActionBridge: ObservableObject {
    // MARK: - State
    @Published public var isActive: Bool = false
    /// When true, menu key equivalents are disabled (e.g. while
    /// typing in search field or other text input).
    @Published public var suppressShortcuts: Bool = false

    /// True only when the bridge is active and shortcuts are not
    /// suppressed by a text input gaining focus.
    public var shortcutsEnabled: Bool {
        isActive && !suppressShortcuts
    }

    // MARK: - Review actions
    public var approve: (() -> Void)?
    public var skip: (() -> Void)?
    public var markNotDuplicate: (() -> Void)?

    // MARK: - Navigation actions
    public var selectNext: (() -> Void)?
    public var selectPrevious: (() -> Void)?
    public var selectNextUndecided: (() -> Void)?

    // MARK: - Quick Look
    /// Opens Quick Look for the currently focused member.
    /// Populated when a member with an existing file is selected.
    public var quickLook: (() -> Void)?

    public init() {}

    /// Called by the detail view when review-ready state changes.
    public func activate(
        approve: @escaping () -> Void,
        skip: @escaping () -> Void,
        markNotDuplicate: @escaping () -> Void,
        selectNext: @escaping () -> Void,
        selectPrevious: @escaping () -> Void,
        selectNextUndecided: @escaping () -> Void,
        quickLook: (() -> Void)? = nil
    ) {
        self.approve = approve
        self.skip = skip
        self.markNotDuplicate = markNotDuplicate
        self.selectNext = selectNext
        self.selectPrevious = selectPrevious
        self.selectNextUndecided = selectNextUndecided
        self.quickLook = quickLook
        self.isActive = true
    }

    public func deactivate() {
        isActive = false
        suppressShortcuts = false
        approve = nil
        skip = nil
        markNotDuplicate = nil
        selectNext = nil
        selectPrevious = nil
        selectNextUndecided = nil
        quickLook = nil
    }
}
