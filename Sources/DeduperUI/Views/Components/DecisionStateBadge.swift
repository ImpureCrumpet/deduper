import SwiftUI

/// Colored capsule badge displaying a review decision state.
public struct DecisionStateBadge: View {
    public let state: DecisionState

    public init(state: DecisionState) {
        self.state = state
    }

    public var body: some View {
        Label(state.displayName, systemImage: state.systemImage)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(state.badgeColor.opacity(0.15))
            .foregroundStyle(state.badgeColor)
            .clipShape(Capsule())
    }
}
