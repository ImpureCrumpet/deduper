import SwiftUI

/// Settings view with cache management.
public struct SettingsView: View {
    @State private var clearingCache = false
    private let thumbnailService = ThumbnailService()

    public init() {}

    public var body: some View {
        Form {
            Section("Cache") {
                HStack {
                    Text("Thumbnail cache")
                    Spacer()
                    Button("Clear") {
                        Task {
                            clearingCache = true
                            await thumbnailService.clearCache()
                            clearingCache = false
                        }
                    }
                    .disabled(clearingCache)
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent(
                    "Engine",
                    value: "DeduperKit"
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}
