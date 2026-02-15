import Testing
import Foundation
import SwiftData
@testable import DeduperUI
@testable import DeduperKit

@Suite("TriageLoop")
struct TriageLoopTests {
    // MARK: - Helpers

    @MainActor
    private func makeVM(
        groupCount: Int
    ) -> (GroupListViewModel, [GroupSummary], ModelContainer) {
        let container = try! UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        let sessionId = UUID()
        let runId = UUID()

        var groups: [GroupSummary] = []
        for i in 0..<groupCount {
            let group = GroupSummary(
                sessionId: sessionId,
                groupIndex: i,
                groupId: UUID(),
                confidence: 0.9 - Double(i) * 0.01,
                mediaTypeRaw: 1,
                memberCount: 2,
                suggestedKeeperPath: "/tmp/g\(i)/file0.jpg",
                totalSize: 2000,
                spaceSavings: 1000,
                materializationRunId: runId
            )
            group.matchKind = MatchKind.sha256Exact.rawValue
            context.insert(group)
            groups.append(group)
        }
        try! context.save()

        let vm = GroupListViewModel()
        vm.loadGroups(
            sessionId: sessionId,
            currentRunId: runId,
            context: context
        )

        return (vm, groups, container)
    }

    // MARK: - Tests

    @Test("commitDecision advances to next undecided")
    @MainActor
    func commitDecisionAdvancesToNextUndecided() {
        let (vm, groups, _) = makeVM(groupCount: 5)
        vm.autoAdvanceMode = .nextUndecided
        vm.selectedGroupId = groups[0].groupId

        vm.commitDecision(
            groupId: groups[0].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        #expect(vm.selectedGroupId == groups[1].groupId)
    }

    @Test("commitDecision with undecided filter removes decided group")
    @MainActor
    func commitDecisionWithUndecidedFilterRemovesDecided() {
        let (vm, groups, _) = makeVM(groupCount: 5)
        vm.autoAdvanceMode = .nextUndecided
        vm.decisionStateFilter = .undecided
        vm.selectedGroupId = groups[0].groupId

        vm.commitDecision(
            groupId: groups[0].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        #expect(vm.filteredGroups.count == 4)
        #expect(!vm.filteredGroups.contains {
            $0.groupId == groups[0].groupId
        })
        #expect(vm.selectedGroupId == groups[1].groupId)
    }

    @Test("commitDecision wraps when at end of list")
    @MainActor
    func commitDecisionWrapsAtEnd() {
        let (vm, groups, _) = makeVM(groupCount: 3)
        vm.autoAdvanceMode = .nextUndecided
        vm.selectedGroupId = groups[2].groupId

        vm.commitDecision(
            groupId: groups[2].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        // Should wrap to first undecided (group 0 or 1)
        #expect(
            vm.selectedGroupId == groups[0].groupId
            || vm.selectedGroupId == groups[1].groupId
        )
    }

    @Test(
        "commitDecision with undecided filter: nil when all decided"
    )
    @MainActor
    func commitDecisionNilWhenAllDecided() {
        let (vm, groups, _) = makeVM(groupCount: 2)
        vm.autoAdvanceMode = .nextUndecided
        vm.decisionStateFilter = .undecided

        // Decide group 0
        vm.selectedGroupId = groups[0].groupId
        vm.commitDecision(
            groupId: groups[0].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        // Should advance to group 1 (only undecided remaining)
        #expect(vm.selectedGroupId == groups[1].groupId)

        // Now decide group 1
        vm.commitDecision(
            groupId: groups[1].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        // Undecided filter active, all decided → filtered list empty
        #expect(vm.filteredGroups.isEmpty)
        // No valid target → selection nil
        #expect(vm.selectedGroupId == nil)
    }

    @Test("batch approve excludes legacyUnknown")
    @MainActor
    func batchApproveExcludesLegacyUnknown() {
        let container = try! UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        let sessionId = UUID()
        let runId = UUID()

        // 3 sha256Exact + 2 legacyUnknown
        var groups: [GroupSummary] = []
        for i in 0..<5 {
            let group = GroupSummary(
                sessionId: sessionId,
                groupIndex: i,
                groupId: UUID(),
                confidence: 0.9,
                mediaTypeRaw: 1,
                memberCount: 2,
                suggestedKeeperPath: "/tmp/g\(i)/file0.jpg",
                totalSize: 2000,
                spaceSavings: 1000,
                materializationRunId: runId
            )
            group.matchKind = i < 3
                ? MatchKind.sha256Exact.rawValue
                : MatchKind.legacyUnknown.rawValue
            context.insert(group)
            groups.append(group)
        }
        try! context.save()

        let vm = GroupListViewModel()
        vm.loadGroups(
            sessionId: sessionId,
            currentRunId: runId,
            context: context
        )

        let count = vm.batchApproveExactMatches(context: context)

        #expect(count == 3)
        // legacyUnknown groups should be untouched
        for i in 3..<5 {
            let state = vm.decisionByGroupId[groups[i].groupId]?
                .state ?? .undecided
            #expect(state == .undecided)
        }
    }

    @Test("applyFilters respects decisionStateFilter")
    @MainActor
    func applyFiltersRespectsDecisionStateFilter() {
        let (vm, groups, _) = makeVM(groupCount: 5)

        // Approve 2 groups
        vm.hydrateDecisionSnapshot(
            groupId: groups[0].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )
        vm.hydrateDecisionSnapshot(
            groupId: groups[1].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        vm.decisionStateFilter = .undecided

        #expect(vm.filteredGroups.count == 3)
    }

    @Test("auto-advance off keeps selection stable")
    @MainActor
    func autoAdvanceOffKeepsSelection() {
        let (vm, groups, _) = makeVM(groupCount: 5)
        vm.autoAdvanceMode = .off
        vm.selectedGroupId = groups[0].groupId

        vm.commitDecision(
            groupId: groups[0].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        // Selection should not have changed
        #expect(vm.selectedGroupId == groups[0].groupId)
    }

    @Test("loadDecisionIndex refilters when decision filter active")
    @MainActor
    func loadDecisionIndexRefilters() throws {
        let container = try UIPersistenceFactory.makeContainer(
            inMemory: true
        )
        let context = ModelContext(container)
        let sessionId = UUID()
        let runId = UUID()

        var groups: [GroupSummary] = []
        for i in 0..<5 {
            let group = GroupSummary(
                sessionId: sessionId,
                groupIndex: i,
                groupId: UUID(),
                confidence: 0.9,
                mediaTypeRaw: 1,
                memberCount: 2,
                suggestedKeeperPath: "/tmp/g\(i)/file.jpg",
                totalSize: 2000,
                spaceSavings: 1000,
                materializationRunId: runId
            )
            group.matchKind = MatchKind.sha256Exact.rawValue
            context.insert(group)
            groups.append(group)
        }

        // Pre-create 2 approved decisions in SwiftData
        for i in 0..<2 {
            let d = ReviewDecision(
                sessionId: sessionId,
                groupIndex: i,
                groupId: groups[i].groupId
            )
            d.decisionState = .approved
            d.decidedAt = Date()
            context.insert(d)
        }
        try context.save()

        let vm = GroupListViewModel()
        vm.loadGroups(
            sessionId: sessionId,
            currentRunId: runId,
            context: context
        )
        vm.decisionStateFilter = .undecided

        // Before loading decisions: all 5 appear undecided
        #expect(vm.filteredGroups.count == 5)

        // After: refilter excludes the 2 approved
        vm.loadDecisionIndex(
            sessionId: sessionId, context: context
        )
        #expect(vm.filteredGroups.count == 3)
    }

    @Test("batchApproveExactMatches normalizes selection")
    @MainActor
    func batchApproveNormalizesSelection() {
        let (vm, groups, container) = makeVM(groupCount: 3)
        let context = ModelContext(container)
        vm.selectedGroupId = groups[0].groupId
        vm.decisionStateFilter = .undecided

        vm.batchApproveExactMatches(context: context)

        // All approved, filtered to undecided → empty
        #expect(vm.filteredGroups.isEmpty)
        #expect(vm.selectedGroupId == nil)
    }

    @Test("commitDecision normalizes stale selection after refilter")
    @MainActor
    func commitDecisionNormalizesAfterRefilter() {
        let (vm, groups, _) = makeVM(groupCount: 5)
        vm.autoAdvanceMode = .off
        vm.decisionStateFilter = .undecided
        vm.selectedGroupId = groups[2].groupId

        vm.commitDecision(
            groupId: groups[2].groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        // Group 2 vanished from filtered list (undecided filter)
        #expect(vm.filteredGroups.count == 4)
        // normalizeSelection should pick first remaining, not nil
        #expect(vm.selectedGroupId == groups[0].groupId)
    }
}
