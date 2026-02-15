import SwiftUI

/// Inline rename editor with mode picker, text fields, and live preview.
public struct RenameEditor: View {
    @Binding public var template: RenameTemplate
    public let keeperFileName: String
    public let companionFileNames: [String]
    public let onSave: () -> Void

    public init(
        template: Binding<RenameTemplate>,
        keeperFileName: String,
        companionFileNames: [String] = [],
        onSave: @escaping () -> Void
    ) {
        self._template = template
        self.keeperFileName = keeperFileName
        self.companionFileNames = companionFileNames
        self.onSave = onSave
    }

    public var body: some View {
        GroupBox("Rename") {
            VStack(alignment: .leading, spacing: 8) {
                // Mode picker
                Picker("Mode", selection: $template.mode) {
                    ForEach(
                        RenameTemplate.Mode.allCases, id: \.self
                    ) { mode in
                        Text(mode.displayLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                // Mode-specific fields
                switch template.mode {
                case .keepOriginal:
                    EmptyView()
                case .prefix:
                    TextField("Prefix", text: $template.value)
                        .textFieldStyle(.roundedBorder)
                case .suffix:
                    TextField("Suffix", text: $template.value)
                        .textFieldStyle(.roundedBorder)
                case .replace:
                    HStack {
                        TextField("Find", text: $template.findText)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField(
                            "Replace",
                            text: $template.replaceText
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                case .custom:
                    TextField("Custom name", text: $template.value)
                        .textFieldStyle(.roundedBorder)
                }

                // Collision policy
                if template.mode != .keepOriginal {
                    HStack {
                        Text("On collision:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(
                            "Collision",
                            selection: $template.collisionPolicy
                        ) {
                            ForEach(
                                RenameTemplate.CollisionPolicy
                                    .allCases, id: \.self
                            ) { policy in
                                Text(policy.displayLabel)
                                    .tag(policy)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }

                // Live preview
                if template.mode != .keepOriginal {
                    Divider()
                    previewSection
                }

                // Actions
                if template.mode != .keepOriginal {
                    HStack {
                        Spacer()
                        Button("Reset") {
                            template = RenameTemplate()
                        }
                        .buttonStyle(.bordered)
                        Button("Apply") {
                            onSave()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(keeperFileName)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .strikethrough()
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(template.preview(for: keeperFileName))
                    .font(.caption.monospacedDigit().bold())
            }

            ForEach(companionFileNames, id: \.self) { companion in
                HStack(spacing: 8) {
                    Text(companion)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(
                        template.previewCompanion(
                            keeperFileName: keeperFileName,
                            companionFileName: companion
                        )
                    )
                    .font(.caption2.monospacedDigit())
                }
            }
        }
    }
}

// MARK: - Display Labels

extension RenameTemplate.Mode {
    var displayLabel: String {
        switch self {
        case .keepOriginal: "Keep"
        case .prefix: "Prefix"
        case .suffix: "Suffix"
        case .replace: "Replace"
        case .custom: "Custom"
        }
    }
}

extension RenameTemplate.CollisionPolicy {
    var displayLabel: String {
        switch self {
        case .appendNumber: "Append number"
        case .skip: "Skip"
        case .block: "Block"
        }
    }
}
