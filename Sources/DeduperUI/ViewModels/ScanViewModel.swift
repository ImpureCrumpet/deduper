import Foundation
import DeduperKit
import os

/// Drives the scan sheet. Orchestrates scan + detect pipeline
/// via ScanOrchestrator and reports progress to the UI.
@MainActor
@Observable
public final class ScanViewModel {
    private static let logger = Logger(
        subsystem: "app.deduper.ui", category: "scan"
    )

    public var selectedDirectories: [URL] = []
    public var isScanning = false
    public var scanPhase: String = ""
    public var filesScanned: Int = 0
    public var errorMessage: String?
    public var exactOnly: Bool = true
    public var threshold: Double = 0.85
    public var includeVideos: Bool = false

    private var scanTask: Task<UUID?, Never>?

    public init() {}

    /// Add directories from NSOpenPanel.
    public func addDirectories(_ urls: [URL]) {
        for url in urls where !selectedDirectories.contains(url) {
            selectedDirectories.append(url)
        }
    }

    /// Remove a directory from the selection.
    public func removeDirectory(_ url: URL) {
        selectedDirectories.removeAll { $0 == url }
    }

    /// Start the scan pipeline. Returns session ID on success.
    public func startScan() async -> UUID? {
        guard !selectedDirectories.isEmpty else { return nil }

        isScanning = true
        errorMessage = nil
        scanPhase = "Starting scan..."
        filesScanned = 0

        let dirs = selectedDirectories
        let exact = exactOnly
        let thresholdVal = threshold
        let videos = includeVideos

        scanTask = Task {
            do {
                let orchestrator = ScanOrchestrator()
                let options = ScanOrchestrator.Options(
                    exactOnly: exact,
                    threshold: thresholdVal,
                    includeVideos: videos
                )

                let result = try await orchestrator.run(
                    directories: dirs,
                    options: options,
                    hashCacheContainer: DefaultHashCacheProvider()
                ) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch phase {
                        case .scanning(let count):
                            self.filesScanned = count
                            self.scanPhase =
                                "Scanning... \(count) files"
                        case .detecting(let desc):
                            self.scanPhase = desc
                        case .writingArtifact:
                            self.scanPhase = "Writing results..."
                        case .complete(_, let groupCount):
                            self.scanPhase =
                                "Found \(groupCount) groups"
                        }
                    }
                }

                return result.sessionId
            } catch is CancellationError {
                Self.logger.info("Scan cancelled")
                return nil
            } catch {
                Self.logger.error("Scan failed: \(error)")
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
                return nil
            }
        }

        let sessionId = await scanTask?.value
        isScanning = false
        return sessionId
    }

    /// Cancel the in-progress scan.
    public func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        scanPhase = ""
    }
}
