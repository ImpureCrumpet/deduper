import Testing
import Foundation
@testable import DeduperUI
@testable import DeduperKit

@Suite("ScanViewModel")
struct ScanViewModelTests {

    // MARK: - State Management (unit tests)

    @Test("Initial state has correct defaults")
    @MainActor
    func initialState() {
        let vm = ScanViewModel()
        #expect(vm.selectedDirectories.isEmpty)
        #expect(!vm.isScanning)
        #expect(vm.scanPhase == "")
        #expect(vm.filesScanned == 0)
        #expect(vm.errorMessage == nil)
        #expect(vm.exactOnly == true)
        #expect(vm.threshold == 0.85)
        #expect(vm.includeVideos == false)
    }

    @Test("addDirectories appends without duplicates")
    @MainActor
    func addDirectoriesDeduplicates() {
        let vm = ScanViewModel()
        let url1 = URL(fileURLWithPath: "/tmp/dir-a")
        let url2 = URL(fileURLWithPath: "/tmp/dir-b")

        vm.addDirectories([url1, url2])
        #expect(vm.selectedDirectories.count == 2)

        // Adding duplicate should not increase count
        vm.addDirectories([url1])
        #expect(vm.selectedDirectories.count == 2)

        // Adding new one should
        let url3 = URL(fileURLWithPath: "/tmp/dir-c")
        vm.addDirectories([url3])
        #expect(vm.selectedDirectories.count == 3)
    }

    @Test("removeDirectory removes matching URL")
    @MainActor
    func removeDirectory() {
        let vm = ScanViewModel()
        let url1 = URL(fileURLWithPath: "/tmp/dir-a")
        let url2 = URL(fileURLWithPath: "/tmp/dir-b")
        vm.addDirectories([url1, url2])

        vm.removeDirectory(url1)
        #expect(vm.selectedDirectories.count == 1)
        #expect(vm.selectedDirectories.first == url2)

        // Removing non-existent URL does nothing
        vm.removeDirectory(url1)
        #expect(vm.selectedDirectories.count == 1)
    }

    @Test("startScan returns nil with empty directories")
    @MainActor
    func startScanEmptyDirs() async {
        let vm = ScanViewModel()
        let result = await vm.startScan()
        #expect(result == nil)
        #expect(!vm.isScanning)
    }

    @Test("cancelScan resets scanning state")
    @MainActor
    func cancelScanResetsState() {
        let vm = ScanViewModel()
        // Simulate mid-scan state
        vm.addDirectories([URL(fileURLWithPath: "/tmp/test")])

        vm.cancelScan()
        #expect(!vm.isScanning)
        #expect(vm.scanPhase == "")
    }

    // MARK: - Integration (real orchestrator, minimal)

    @Test("startScan with duplicate files returns session ID")
    @MainActor
    func startScanSuccessPath() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(
            ".deduper-scanvm-test-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: dir)
        }

        // Create two identical files with a recognized media extension
        let content = Data("identical-content-for-dedup".utf8)
        try content.write(
            to: dir.appendingPathComponent("copy-a.jpg")
        )
        try content.write(
            to: dir.appendingPathComponent("copy-b.jpg")
        )

        let vm = ScanViewModel()
        vm.addDirectories([dir])
        vm.exactOnly = true

        let sessionId = await vm.startScan()
        #expect(sessionId != nil)
        #expect(!vm.isScanning)
        #expect(vm.errorMessage == nil)
    }
}
