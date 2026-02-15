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
public final class TriageActionBridge: ObservableObject {
    // MARK: - State
    @Published public var isActive: Bool = false

    // MARK: - Review actions
    public var approve: (() -> Void)?
    public var skip: (() -> Void)?
    public var markNotDuplicate: (() -> Void)?

    // MARK: - Navigation actions
    public var selectNext: (() -> Void)?
    public var selectPrevious: (() -> Void)?
    public var selectNextUndecided: (() -> Void)?

    public init() {}

    /// Called by the detail view when review-ready state changes.
    public func activate(
        approve: @escaping () -> Void,
        skip: @escaping () -> Void,
        markNotDuplicate: @escaping () -> Void,
        selectNext: @escaping () -> Void,
        selectPrevious: @escaping () -> Void,
        selectNextUndecided: @escaping () -> Void
    ) {
        self.approve = approve
        self.skip = skip
        self.markNotDuplicate = markNotDuplicate
        self.selectNext = selectNext
        self.selectPrevious = selectPrevious
        self.selectNextUndecided = selectNextUndecided
        self.isActive = true
    }

    public func deactivate() {
        isActive = false
        approve = nil
        skip = nil
        markNotDuplicate = nil
        selectNext = nil
        selectPrevious = nil
        selectNextUndecided = nil
    }
}
