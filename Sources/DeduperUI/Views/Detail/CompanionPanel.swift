import SwiftUI

/// Displays companion/sidecar files for a member.
public struct CompanionPanel: View {
    public let companions: [String]

    public init(companions: [String]) {
        self.companions = companions
    }

    public var body: some View {
        if !companions.isEmpty {
            GroupBox("Companion Files") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(companions, id: \.self) { path in
                        let url = URL(fileURLWithPath: path)
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}
