import SwiftUI
import AppKit

/// Sheet for initiating a new scan: folder picker + options + progress.
public struct ScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ScanViewModel()

    public let onScanComplete: (UUID) -> Void

    public init(onScanComplete: @escaping (UUID) -> Void) {
        self.onScanComplete = onScanComplete
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text("New Scan")
                .font(.title2.bold())

            if viewModel.isScanning {
                scanProgressSection
            } else {
                directorySection
                optionsSection
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            buttonBar
        }
        .padding()
        .frame(minWidth: 500, minHeight: 350)
    }

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Directories")
                    .font(.headline)
                Spacer()
                Button("Add Folders...") {
                    showDirectoryPicker()
                }
                .buttonStyle(.borderedProminent)
            }

            if viewModel.selectedDirectories.isEmpty {
                Text("No directories selected")
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 80,
                        alignment: .center
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary.opacity(0.3))
                    )
            } else {
                List {
                    ForEach(
                        viewModel.selectedDirectories,
                        id: \.self
                    ) { url in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(url.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Button {
                                viewModel.removeDirectory(url)
                            } label: {
                                Image(
                                    systemName: "xmark.circle.fill"
                                )
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.bordered)
                .frame(height: 100)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Options")
                .font(.headline)

            Toggle(
                "Exact matches only (SHA256, safest)",
                isOn: $viewModel.exactOnly
            )
            .toggleStyle(.checkbox)
        }
    }

    private var scanProgressSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text(viewModel.scanPhase)
                .font(.headline)

            if viewModel.filesScanned > 0 {
                Text("\(viewModel.filesScanned) files scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var buttonBar: some View {
        HStack {
            Button("Cancel") {
                if viewModel.isScanning {
                    viewModel.cancelScan()
                }
                dismiss()
            }
            .keyboardShortcut(.escape)

            Spacer()

            if !viewModel.isScanning {
                Button("Start Scan") {
                    Task {
                        if let sessionId =
                            await viewModel.startScan() {
                            BookmarkStore.saveAll(
                                urls: viewModel.selectedDirectories
                            )
                            onScanComplete(sessionId)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.return)
                .disabled(viewModel.selectedDirectories.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func showDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message =
            "Select directories to scan for duplicates"

        if panel.runModal() == .OK {
            viewModel.addDirectories(panel.urls)
        }
    }
}
