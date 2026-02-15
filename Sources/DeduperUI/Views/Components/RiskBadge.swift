import SwiftUI

/// Badge for risk flags on duplicate groups.
public struct RiskBadge: View {
    public let label: String
    public let systemImage: String
    public var color: Color = .orange

    public init(
        label: String,
        systemImage: String,
        color: Color = .orange
    ) {
        self.label = label
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
