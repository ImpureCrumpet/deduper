import SwiftUI

/// Color-coded confidence pill.
/// Green ≥ 0.95, yellow ≥ 0.80, orange ≥ 0.60, red < 0.60.
public struct ConfidenceBadge: View {
    public let confidence: Double

    public init(confidence: Double) {
        self.confidence = confidence
    }

    public var body: some View {
        Text(formattedConfidence)
            .font(.caption.monospacedDigit())
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
    }

    private var formattedConfidence: String {
        if confidence >= 1.0 {
            return "100%"
        }
        return "\(Int(confidence * 100))%"
    }

    private var badgeColor: Color {
        switch confidence {
        case 0.95...: .green
        case 0.80...: .yellow
        case 0.60...: .orange
        default: .red
        }
    }
}
