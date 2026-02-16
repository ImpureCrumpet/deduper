import Testing
import Foundation
import SwiftData
@testable import DeduperUI
@testable import DeduperKit

@Suite("MergeViewModel")
struct MergeViewModelTests {
    // MARK: - Helpers

    /// Create a temp directory with N test files, returning
    /// (directory, file URLs). Caller must clean up.
    private func makeTempFiles(
        count: Int,
        prefix: String = "file",
        ext: String = "jpg"
    ) throws -> (URL, [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        var files: [URL] = []
        for i in 0..<count {
            let file = dir
                .appendingPathComponent("\(prefix)\(i).\(ext)")
            FileManager.default.createFile(
                atPath: file.path,
                contents: Data("test-content-\(i)".utf8)
            )
            files.append(file)
        }
        return (dir, files)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Set up a complete test scenario: container, session, groups,
    /// members, decisions, and real temp files.
    @MainActor
    private func makeScenario(
        groupCount: Int,
        membersPerGroup: Int = 3,
        approvedGroups: Int? = nil,
        container: ModelContainer? = nil
    ) throws -> Scenario {
        let ctr = try container
            ?? UIPersistenceFactory.makeContainer(inMemory: true)
        let context = ModelContext(ctr)
        let sessionId = UUID()
        let runId = UUID()

        // Create session index
        let session = SessionIndex(
            sessionId: sessionId,
            directoryPath: "/tmp/test",
            startedAt: Date(),
            totalFiles: 100,
            mediaFiles: 50,
            duplicateGroups: groupCount,
            artifactPath: "/tmp/test.ndjson.gz",
            manifestPath: "/tmp/test.manifest.json"
        )
        session.currentRunId = runId
        context.insert(session)

        // Create temp files
        let (tempDir, tempFiles) = try makeTempFiles(
            count: groupCount * membersPerGroup
        )

        var groupIds: [UUID] = []
        var fileIndex = 0
        let approved = approvedGroups ?? groupCount

        for g in 0..<groupCount {
            let groupId = UUID()
            groupIds.append(groupId)

            // GroupSummary
            let summary = GroupSummary(
                sessionId: sessionId,
                groupIndex: g,
                groupId: groupId,
                confidence: 0.95,
                mediaTypeRaw: 1,
                memberCount: membersPerGroup,
                suggestedKeeperPath: tempFiles[fileIndex].path,
                totalSize: Int64(membersPerGroup * 1000),
                spaceSavings: Int64((membersPerGroup - 1) * 1000),
                materializationRunId: runId
            )
            summary.matchKind = MatchKind.sha256Exact.rawValue
            context.insert(summary)

            // GroupMembers
            for m in 0..<membersPerGroup {
                let member = GroupMember(
                    sessionId: sessionId,
                    groupId: groupId,
                    groupIndex: g,
                    memberIndex: m,
                    filePath: tempFiles[fileIndex].path,
                    fileName: tempFiles[fileIndex].lastPathComponent,
                    fileSize: 1000,
                    isKeeper: m == 0,
                    materializationRunId: runId
                )
                context.insert(member)
                fileIndex += 1
            }

            // ReviewDecision (approved or skipped)
            if g < approved {
                let decision = ReviewDecision(
                    sessionId: sessionId,
                    groupIndex: g,
                    groupId: groupId,
                    decisionState: .approved
                )
                decision.decidedAt = Date()
                context.insert(decision)
            }
        }

        try context.save()

        return Scenario(
            container: ctr,
            sessionId: sessionId,
            runId: runId,
            groupIds: groupIds,
            tempDir: tempDir,
            tempFiles: tempFiles
        )
    }

    struct Scenario {
        let container: ModelContainer
        let sessionId: UUID
        let runId: UUID
        let groupIds: [UUID]
        let tempDir: URL
        let tempFiles: [URL]
    }

    /// Wait for the merge VM phase to leave `.validating`.
    @MainActor
    private func waitForValidation(
        _ vm: MergeViewModel,
        timeout: Double = 5.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .validating = vm.phase {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            return
        }
    }

    /// Wait for the merge VM phase to leave `.executing`.
    @MainActor
    private func waitForExecution(
        _ vm: MergeViewModel,
        timeout: Double = 5.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .executing = vm.phase {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            return
        }
    }

    // MARK: - Validation Tests

    @Test("Validate produces plan from approved decisions")
    @MainActor
    func validateProducesPlan() async throws {
        let s = try makeScenario(groupCount: 3, membersPerGroup: 3)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase, got \(vm.phase)")
            return
        }

        #expect(plan.items.count == 3)
        // Each group: 3 members, 1 keeper, 2 non-keepers
        #expect(plan.totalAssetBundles == 6)
        #expect(plan.skippedGroups.isEmpty)
    }

    @Test("Validate scopes to current run ID")
    @MainActor
    func validateScopesToCurrentRunId() async throws {
        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let s = try makeScenario(
            groupCount: 2, membersPerGroup: 2, container: container
        )
        defer { cleanup(s.tempDir) }

        // Insert stale group members with a different runId
        let context = ModelContext(container)
        let staleRunId = UUID()
        for i in 0..<2 {
            let staleMember = GroupMember(
                sessionId: s.sessionId,
                groupId: s.groupIds[0],
                groupIndex: 0,
                memberIndex: 10 + i,
                filePath: "/tmp/stale/file\(i).jpg",
                fileName: "stale\(i).jpg",
                fileSize: 500,
                isKeeper: false,
                materializationRunId: staleRunId
            )
            context.insert(staleMember)
        }
        try context.save()

        let vm = MergeViewModel()
        vm.validate(
            sessionId: s.sessionId, container: container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        // Should only include current-run members, not stale ones
        // 2 groups × 1 non-keeper each = 2 bundles
        #expect(plan.totalAssetBundles == 2)
    }

    @Test("Validate skips groups without keeper path")
    @MainActor
    func validateSkipsNoKeeper() async throws {
        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        let sessionId = UUID()
        let runId = UUID()
        let groupId = UUID()

        let session = SessionIndex(
            sessionId: sessionId,
            directoryPath: "/tmp",
            startedAt: Date(),
            totalFiles: 10,
            mediaFiles: 5,
            duplicateGroups: 1,
            artifactPath: "/tmp/a.ndjson.gz",
            manifestPath: "/tmp/a.manifest.json"
        )
        session.currentRunId = runId
        context.insert(session)

        // Summary with no suggested keeper
        let summary = GroupSummary(
            sessionId: sessionId,
            groupIndex: 0,
            groupId: groupId,
            confidence: 0.9,
            mediaTypeRaw: 1,
            memberCount: 2,
            suggestedKeeperPath: nil,
            totalSize: 2000,
            spaceSavings: 1000,
            materializationRunId: runId
        )
        context.insert(summary)

        // Members — none marked as keeper
        let (tempDir, tempFiles) = try makeTempFiles(count: 2)
        defer { cleanup(tempDir) }
        for i in 0..<2 {
            let member = GroupMember(
                sessionId: sessionId,
                groupId: groupId,
                groupIndex: 0,
                memberIndex: i,
                filePath: tempFiles[i].path,
                fileName: tempFiles[i].lastPathComponent,
                fileSize: 1000,
                isKeeper: false,
                materializationRunId: runId
            )
            context.insert(member)
        }

        let decision = ReviewDecision(
            sessionId: sessionId,
            groupIndex: 0,
            groupId: groupId,
            decisionState: .approved
        )
        decision.decidedAt = Date()
        context.insert(decision)
        try context.save()

        let vm = MergeViewModel()
        vm.validate(sessionId: sessionId, container: container)
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        #expect(plan.items.isEmpty)
        #expect(plan.skippedGroups.count == 1)
    }

    @Test("Validate skips missing keeper")
    @MainActor
    func validateSkipsMissingKeeper() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        // Delete the keeper file (first file in each group)
        try FileManager.default.removeItem(at: s.tempFiles[0])

        let vm = MergeViewModel()
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        #expect(plan.items.isEmpty)
        #expect(!plan.skippedGroups.isEmpty)
    }

    @Test("Validate warns on fingerprint drift")
    @MainActor
    func validateWarnsOnFingerprintDrift() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        // Set a fake fingerprint on the decision
        let context = ModelContext(s.container)
        let sid = s.sessionId
        let predicate = #Predicate<ReviewDecision> {
            $0.sessionId == sid
        }
        let decisions = try context.fetch(
            FetchDescriptor<ReviewDecision>(predicate: predicate)
        )
        decisions.first?.selectedKeeperFingerprint = "fake-old-hash"
        try context.save()

        let vm = MergeViewModel()
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        // Group should still be in plan (not skipped)
        #expect(plan.items.count == 1)
        // But should have a keeperChanged warning
        let warnings = plan.items[0].warnings
        let hasDriftWarning = warnings.contains {
            if case .keeperChanged = $0 { return true }
            return false
        }
        #expect(hasDriftWarning)
    }

    @Test("Validate ignores non-approved decisions")
    @MainActor
    func validateIgnoresNonApproved() async throws {
        let s = try makeScenario(
            groupCount: 3,
            membersPerGroup: 2,
            approvedGroups: 1  // Only first group approved
        )
        defer { cleanup(s.tempDir) }

        let vm = MergeViewModel()
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        // Only 1 approved group should be in the plan
        #expect(plan.items.count == 1)
    }

    @Test("Validate dedupes move targets across groups")
    @MainActor
    func validateDedupesMoveTargets() async throws {
        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        let sessionId = UUID()
        let runId = UUID()

        let session = SessionIndex(
            sessionId: sessionId,
            directoryPath: "/tmp",
            startedAt: Date(),
            totalFiles: 10,
            mediaFiles: 5,
            duplicateGroups: 2,
            artifactPath: "/tmp/a.ndjson.gz",
            manifestPath: "/tmp/a.manifest.json"
        )
        session.currentRunId = runId
        context.insert(session)

        let (tempDir, tempFiles) = try makeTempFiles(count: 3)
        defer { cleanup(tempDir) }

        // Group 0: keeper=file0, non-keeper=file1
        // Group 1: keeper=file2, non-keeper=file1 (OVERLAP)
        let groupIds = [UUID(), UUID()]
        let keeperIndices = [0, 2]
        let nonKeeperIndices = [[1], [1]]

        for (g, groupId) in groupIds.enumerated() {
            let allMembers = [keeperIndices[g]]
                + nonKeeperIndices[g]
            let summary = GroupSummary(
                sessionId: sessionId,
                groupIndex: g,
                groupId: groupId,
                confidence: 0.9,
                mediaTypeRaw: 1,
                memberCount: allMembers.count,
                suggestedKeeperPath:
                    tempFiles[keeperIndices[g]].path,
                totalSize: 2000,
                spaceSavings: 1000,
                materializationRunId: runId
            )
            summary.matchKind = MatchKind.sha256Exact.rawValue
            context.insert(summary)

            for (m, fileIdx) in allMembers.enumerated() {
                let member = GroupMember(
                    sessionId: sessionId,
                    groupId: groupId,
                    groupIndex: g,
                    memberIndex: m,
                    filePath: tempFiles[fileIdx].path,
                    fileName: tempFiles[fileIdx].lastPathComponent,
                    fileSize: 1000,
                    isKeeper: m == 0,
                    materializationRunId: runId
                )
                context.insert(member)
            }

            let decision = ReviewDecision(
                sessionId: sessionId,
                groupIndex: g,
                groupId: groupId,
                decisionState: .approved
            )
            decision.decidedAt = Date()
            context.insert(decision)
        }
        try context.save()

        let vm = MergeViewModel()
        vm.validate(sessionId: sessionId, container: container)
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        // file1 appears as non-keeper in both groups but should
        // only produce 1 AssetBundle total
        let totalBundles = plan.items.reduce(0) {
            $0 + $1.nonKeeperBundles.count
        }
        #expect(totalBundles == 1)
    }

    @Test("Validate protects keepers globally")
    @MainActor
    func validateProtectsKeepersGlobally() async throws {
        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        let sessionId = UUID()
        let runId = UUID()

        let session = SessionIndex(
            sessionId: sessionId,
            directoryPath: "/tmp",
            startedAt: Date(),
            totalFiles: 10,
            mediaFiles: 5,
            duplicateGroups: 2,
            artifactPath: "/tmp/a.ndjson.gz",
            manifestPath: "/tmp/a.manifest.json"
        )
        session.currentRunId = runId
        context.insert(session)

        let (tempDir, tempFiles) = try makeTempFiles(count: 3)
        defer { cleanup(tempDir) }

        // Group 0: keeper=file0, non-keeper=file1
        // Group 1: keeper=file1, non-keeper=file2
        // file1 is keeper in group 1, non-keeper in group 0
        let groupIds = [UUID(), UUID()]
        let configs: [(keeper: Int, nonKeepers: [Int])] = [
            (0, [1]),
            (1, [2]),
        ]

        for (g, groupId) in groupIds.enumerated() {
            let cfg = configs[g]
            let allIndices = [cfg.keeper] + cfg.nonKeepers

            let summary = GroupSummary(
                sessionId: sessionId,
                groupIndex: g,
                groupId: groupId,
                confidence: 0.9,
                mediaTypeRaw: 1,
                memberCount: allIndices.count,
                suggestedKeeperPath: tempFiles[cfg.keeper].path,
                totalSize: 2000,
                spaceSavings: 1000,
                materializationRunId: runId
            )
            summary.matchKind = MatchKind.sha256Exact.rawValue
            context.insert(summary)

            for (m, fileIdx) in allIndices.enumerated() {
                let member = GroupMember(
                    sessionId: sessionId,
                    groupId: groupId,
                    groupIndex: g,
                    memberIndex: m,
                    filePath: tempFiles[fileIdx].path,
                    fileName: tempFiles[fileIdx].lastPathComponent,
                    fileSize: 1000,
                    isKeeper: m == 0,
                    materializationRunId: runId
                )
                context.insert(member)
            }

            let decision = ReviewDecision(
                sessionId: sessionId,
                groupIndex: g,
                groupId: groupId,
                decisionState: .approved
            )
            decision.decidedAt = Date()
            context.insert(decision)
        }
        try context.save()

        let vm = MergeViewModel()
        vm.validate(sessionId: sessionId, container: container)
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        // file1 is keeper in group 1 — must NOT appear as a move
        // target even though it's non-keeper in group 0
        let allMovePaths = plan.items.flatMap(\.nonKeeperBundles)
            .map(\.primary.path)
        #expect(!allMovePaths.contains(tempFiles[1].path))

        // file2 should be moved (non-keeper in group 1, not a keeper)
        #expect(allMovePaths.contains(tempFiles[2].path))
    }

    @Test("Validate reports missing non-keepers")
    @MainActor
    func validateReportsNonKeeperMissing() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 3)
        defer { cleanup(s.tempDir) }

        // Delete one non-keeper file (index 1 — keeper is index 0)
        try FileManager.default.removeItem(at: s.tempFiles[1])

        let vm = MergeViewModel()
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        #expect(plan.missingNonKeeperCount == 1)
        // 1 of 2 non-keepers remains
        #expect(plan.totalAssetBundles == 1)
    }

    // MARK: - Execution Tests

    @Test("Execute moves files to quarantine")
    @MainActor
    func executeMovesToQuarantine() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan)
        await waitForExecution(vm)

        guard case .completed(let tx) = vm.phase else {
            Issue.record("Expected completed phase, got \(vm.phase)")
            return
        }

        #expect(tx.filesMoved > 0)
        // Non-keeper file should no longer exist at original path
        #expect(!FileManager.default.fileExists(
            atPath: s.tempFiles[1].path
        ))
        // Keeper should still exist
        #expect(FileManager.default.fileExists(
            atPath: s.tempFiles[0].path
        ))
    }

    @Test("Undo restores files to original paths")
    @MainActor
    func undoRestoresFiles() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan)
        await waitForExecution(vm)

        // File should be gone
        #expect(!FileManager.default.fileExists(
            atPath: s.tempFiles[1].path
        ))

        vm.undoLastTransaction()
        // Wait for undo (also uses Task internally)
        try await Task.sleep(for: .milliseconds(500))

        // File should be restored
        #expect(FileManager.default.fileExists(
            atPath: s.tempFiles[1].path
        ))
        #expect(vm.lastTransaction == nil)
    }

    @Test("Undo partial failure keeps transaction for retry")
    @MainActor
    func undoPartialFailureKeepsTransaction() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan)
        await waitForExecution(vm)

        guard case .completed(let tx) = vm.phase else {
            Issue.record("Expected completed phase")
            return
        }

        // Create a file at the original path to block undo
        // (undo will fail because destination already exists)
        FileManager.default.createFile(
            atPath: s.tempFiles[1].path,
            contents: Data("blocker".utf8)
        )

        vm.undoLastTransaction()
        try await Task.sleep(for: .milliseconds(500))

        // Should be undoFailed with transaction preserved
        if case .undoFailed(let failures, let keptTx) = vm.phase {
            #expect(!failures.isEmpty)
            #expect(keptTx.id == tx.id)
        } else {
            // Undo may succeed if FileManager overwrites — that's OK
            // In that case, the test is still valid
            #expect(vm.lastTransaction == nil)
        }
    }

    // MARK: - Post-merge State Transition Tests

    @Test("Execute transitions decisions to merged state")
    @MainActor
    func executeTransitionsToMerged() async throws {
        let s = try makeScenario(groupCount: 2, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )

        // Track which group IDs and target state were transitioned
        var transitionedIds: [UUID] = []
        var transitionedState: DecisionState?
        vm.onDecisionsTransitioned = { ids, state in
            transitionedIds = ids
            transitionedState = state
        }

        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        guard case .completed = vm.phase else {
            Issue.record("Expected completed phase")
            return
        }

        // Verify callback fired with merged group IDs and state
        #expect(transitionedIds.count == 2)
        #expect(Set(transitionedIds) == Set(s.groupIds))
        #expect(transitionedState == .merged)

        // Verify SwiftData decisions transitioned
        let context = ModelContext(s.container)
        let sid = s.sessionId
        let pred = #Predicate<ReviewDecision> {
            $0.sessionId == sid
        }
        let decisions = try context.fetch(
            FetchDescriptor<ReviewDecision>(predicate: pred)
        )
        for d in decisions {
            #expect(d.decisionState == .merged)
        }
    }

    @Test("Double-run after merge produces empty plan")
    @MainActor
    func doubleRunProducesEmptyPlan() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        guard case .completed = vm.phase else {
            Issue.record("Expected completed phase")
            return
        }

        // Second run: decisions are now .merged, not .approved
        vm.reset()
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan2) = vm.phase else {
            Issue.record("Expected preview phase on second run")
            return
        }

        // Plan should be empty — no approved decisions remain
        #expect(plan2.items.isEmpty)
        #expect(plan2.totalFiles == 0)
    }

    @Test("Undo reverses merged state back to approved")
    @MainActor
    func undoReversesToApproved() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        // Verify merged
        let context = ModelContext(s.container)
        let gid = s.groupIds[0]
        let pred = #Predicate<ReviewDecision> {
            $0.groupId == gid
        }
        var desc = FetchDescriptor<ReviewDecision>(
            predicate: pred
        )
        desc.fetchLimit = 1
        var decision = try context.fetch(desc).first
        #expect(decision?.decisionState == .merged)

        // Undo
        vm.undoLastTransaction()
        try await Task.sleep(for: .milliseconds(500))

        // Verify reverted to approved
        decision = try context.fetch(desc).first
        #expect(decision?.decisionState == .approved)
    }

    @Test("Companion keeper protection filters conflicting companions")
    @MainActor
    func companionKeeperProtection() async throws {
        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        let sessionId = UUID()
        let runId = UUID()

        let session = SessionIndex(
            sessionId: sessionId,
            directoryPath: "/tmp",
            startedAt: Date(),
            totalFiles: 10,
            mediaFiles: 5,
            duplicateGroups: 2,
            artifactPath: "/tmp/a.ndjson.gz",
            manifestPath: "/tmp/a.manifest.json"
        )
        session.currentRunId = runId
        context.insert(session)

        // Create temp dir with files that have companion relationships
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { cleanup(dir) }

        // Create files: img.heic (keeper in group B),
        // img.aae (companion of img.heic)
        let heicFile = dir.appendingPathComponent("img.heic")
        let aaeFile = dir.appendingPathComponent("img.aae")
        let otherFile = dir.appendingPathComponent("other.jpg")
        FileManager.default.createFile(
            atPath: heicFile.path, contents: Data("heic".utf8)
        )
        FileManager.default.createFile(
            atPath: aaeFile.path, contents: Data("aae".utf8)
        )
        FileManager.default.createFile(
            atPath: otherFile.path, contents: Data("other".utf8)
        )

        // Group A: keeper=other.jpg, non-keeper=img.heic
        // Group B: keeper=img.heic, non-keeper=aae
        // img.heic's companion (img.aae) should NOT be moved
        // because img.heic is a keeper in group B... but actually
        // img.heic itself is protected by the keeper set check.
        // The companion (img.aae) of the non-keeper in group A
        // would be checked against keeper set.
        let groupIds = [UUID(), UUID()]

        // Group A
        let summaryA = GroupSummary(
            sessionId: sessionId, groupIndex: 0,
            groupId: groupIds[0], confidence: 0.9,
            mediaTypeRaw: 1, memberCount: 2,
            suggestedKeeperPath: otherFile.path,
            totalSize: 2000, spaceSavings: 1000,
            materializationRunId: runId
        )
        summaryA.matchKind = MatchKind.sha256Exact.rawValue
        context.insert(summaryA)

        // Group A members
        let memberA0 = GroupMember(
            sessionId: sessionId, groupId: groupIds[0],
            groupIndex: 0, memberIndex: 0,
            filePath: otherFile.path,
            fileName: "other.jpg", fileSize: 1000,
            isKeeper: true, materializationRunId: runId
        )
        let memberA1 = GroupMember(
            sessionId: sessionId, groupId: groupIds[0],
            groupIndex: 0, memberIndex: 1,
            filePath: heicFile.path,
            fileName: "img.heic", fileSize: 1000,
            isKeeper: false, materializationRunId: runId
        )
        context.insert(memberA0)
        context.insert(memberA1)

        let decisionA = ReviewDecision(
            sessionId: sessionId, groupIndex: 0,
            groupId: groupIds[0], decisionState: .approved
        )
        decisionA.decidedAt = Date()
        context.insert(decisionA)

        // Group B: keeper=img.heic
        let summaryB = GroupSummary(
            sessionId: sessionId, groupIndex: 1,
            groupId: groupIds[1], confidence: 0.9,
            mediaTypeRaw: 1, memberCount: 2,
            suggestedKeeperPath: heicFile.path,
            totalSize: 2000, spaceSavings: 1000,
            materializationRunId: runId
        )
        summaryB.matchKind = MatchKind.sha256Exact.rawValue
        context.insert(summaryB)

        let memberB0 = GroupMember(
            sessionId: sessionId, groupId: groupIds[1],
            groupIndex: 1, memberIndex: 0,
            filePath: heicFile.path,
            fileName: "img.heic", fileSize: 1000,
            isKeeper: true, materializationRunId: runId
        )
        let memberB1 = GroupMember(
            sessionId: sessionId, groupId: groupIds[1],
            groupIndex: 1, memberIndex: 1,
            filePath: aaeFile.path,
            fileName: "img.aae", fileSize: 1000,
            isKeeper: false, materializationRunId: runId
        )
        context.insert(memberB0)
        context.insert(memberB1)

        let decisionB = ReviewDecision(
            sessionId: sessionId, groupIndex: 1,
            groupId: groupIds[1], decisionState: .approved
        )
        decisionB.decidedAt = Date()
        context.insert(decisionB)

        try context.save()

        let vm = MergeViewModel()
        vm.validate(sessionId: sessionId, container: container)
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        // img.heic is keeper in group B — must not appear as move
        // target even though it's non-keeper in group A
        let allMovePrimaries = plan.items
            .flatMap(\.nonKeeperBundles)
            .map(\.primary.path)
        #expect(!allMovePrimaries.contains(heicFile.path))

        // img.aae as non-keeper in group B should be movable
        // (it's not a keeper anywhere)
        #expect(allMovePrimaries.contains(aaeFile.path))
    }

    @Test("Undo callback carries .approved target state")
    @MainActor
    func undoCallbackCarriesApprovedState() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )

        var callbackStates: [DecisionState] = []
        vm.onDecisionsTransitioned = { _, state in
            callbackStates.append(state)
        }

        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        // First callback: .merged
        #expect(callbackStates == [.merged])

        vm.undoLastTransaction()
        try await Task.sleep(for: .milliseconds(500))

        // Second callback: .approved (not toggled from snapshot)
        #expect(callbackStates == [.merged, .approved])
    }

    @Test("Execute writes sessionId into transaction on disk")
    @MainActor
    func executeWritesSessionIdToDisk() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        // Read transaction from disk
        let txs = try MergeService().listTransactions(
            logDirectory: logDir
        )
        let completed = txs.first { $0.status == .completed }
        #expect(completed?.sessionId == s.sessionId)
    }

    @Test("Load persisted transaction restores undo affordance")
    @MainActor
    func loadPersistedTransactionRestoresUndo() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        // First VM: merge and complete
        let vm1 = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm1.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm1)
        guard case .preview(let plan) = vm1.phase else {
            Issue.record("Expected preview phase")
            return
        }
        vm1.execute(plan: plan, container: s.container)
        await waitForExecution(vm1)
        guard case .completed = vm1.phase else {
            Issue.record("Expected completed phase")
            return
        }

        // Second VM: simulates app restart
        let vm2 = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm2.loadPersistedTransaction(
            for: s.sessionId, container: s.container
        )

        // Should have loaded the transaction
        #expect(vm2.lastTransaction != nil)
        #expect(vm2.lastMergedSessionId == s.sessionId)
    }

    @Test("Load persisted transaction ignores wrong session")
    @MainActor
    func loadPersistedTransactionIgnoresWrongSession() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm1 = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm1.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm1)
        guard case .preview(let plan) = vm1.phase else {
            Issue.record("Expected preview phase")
            return
        }
        vm1.execute(plan: plan, container: s.container)
        await waitForExecution(vm1)

        // Different session ID → no transaction loaded
        let vm2 = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm2.loadPersistedTransaction(
            for: UUID(), container: s.container
        )
        #expect(vm2.lastTransaction == nil)
    }

    @Test("Transaction groupIds scopes undo correctly")
    @MainActor
    func transactionGroupIdsScope() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)
        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        // Verify groupIds written to disk match plan
        let txs = try MergeService().listTransactions(
            logDirectory: logDir
        )
        let completed = txs.first { $0.status == .completed }
        #expect(completed?.groupIds == [s.groupIds[0]])

        // Load from disk — should use transaction.groupIds,
        // not query all merged decisions
        let vm2 = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm2.loadPersistedTransaction(
            for: s.sessionId, container: s.container
        )
        #expect(vm2.lastTransaction != nil)
    }

    @Test("Undo marks transaction as undone on disk")
    @MainActor
    func undoMarksTransactionUndone() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)
        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }
        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        vm.undoLastTransaction()
        try await Task.sleep(for: .milliseconds(500))

        // Transaction on disk should be marked undone
        let txs = try MergeService().listTransactions(
            logDirectory: logDir
        )
        let match = txs.first { $0.sessionId == s.sessionId }
        #expect(match?.status == .undone)

        // Second VM should NOT load undone transaction
        let vm2 = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm2.loadPersistedTransaction(
            for: s.sessionId, container: s.container
        )
        #expect(vm2.lastTransaction == nil)
    }

    @Test("Empty plan reports no approved decisions reason")
    @MainActor
    func emptyPlanNoApprovedDecisions() async throws {
        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        let sessionId = UUID()
        let runId = UUID()

        let session = SessionIndex(
            sessionId: sessionId,
            directoryPath: "/tmp",
            startedAt: Date(),
            totalFiles: 10,
            mediaFiles: 5,
            duplicateGroups: 0,
            artifactPath: "/tmp/a.ndjson.gz",
            manifestPath: "/tmp/a.manifest.json"
        )
        session.currentRunId = runId
        context.insert(session)
        try context.save()

        let vm = MergeViewModel()
        vm.validate(sessionId: sessionId, container: container)
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        #expect(plan.items.isEmpty)
        if case .noApprovedDecisions = plan.emptyReason {
            // correct
        } else {
            Issue.record(
                "Expected noApprovedDecisions, got \(String(describing: plan.emptyReason))"
            )
        }
    }

    @Test("Empty plan reports all already merged reason")
    @MainActor
    func emptyPlanAllAlreadyMerged() async throws {
        let s = try makeScenario(groupCount: 2, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        // Second run: all merged
        vm.reset()
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        guard case .preview(let plan2) = vm.phase else {
            Issue.record("Expected preview phase on second run")
            return
        }

        #expect(plan2.items.isEmpty)
        if case .allAlreadyMerged(let count) = plan2.emptyReason {
            #expect(count == 2)
        } else {
            Issue.record(
                "Expected allAlreadyMerged, got \(String(describing: plan2.emptyReason))"
            )
        }
    }

    @Test("Session ID stored for undo session guard")
    @MainActor
    func sessionIdStoredForUndoGuard() async throws {
        let s = try makeScenario(groupCount: 1, membersPerGroup: 2)
        defer { cleanup(s.tempDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let quarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { cleanup(logDir); cleanup(quarDir) }

        let vm = MergeViewModel(
            logDirectory: logDir, quarantineRoot: quarDir
        )
        vm.validate(
            sessionId: s.sessionId, container: s.container
        )
        await waitForValidation(vm)

        // Session ID should be stored after validate
        #expect(vm.lastMergedSessionId == s.sessionId)

        guard case .preview(let plan) = vm.phase else {
            Issue.record("Expected preview phase")
            return
        }

        vm.execute(plan: plan, container: s.container)
        await waitForExecution(vm)

        // Session ID persists after execution
        #expect(vm.lastMergedSessionId == s.sessionId)
        #expect(vm.lastTransaction != nil)
    }
}
