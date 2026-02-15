import Testing
import Foundation
import SwiftData
@testable import DeduperUI
@testable import DeduperKit

@Suite("ReviewDecision")
struct ReviewDecisionTests {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try UIPersistenceFactory.makeContainer(inMemory: true)
    }

    @Test("Create and fetch decision")
    @MainActor
    func createAndFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let groupId = UUID()
        let sessionId = UUID()
        let decision = ReviewDecision(
            sessionId: sessionId,
            groupIndex: 0,
            groupId: groupId
        )
        context.insert(decision)
        try context.save()

        let gid = groupId
        let pred = #Predicate<ReviewDecision> {
            $0.groupId == gid
        }
        let fetched = try context.fetch(
            FetchDescriptor<ReviewDecision>(predicate: pred)
        )
        #expect(fetched.count == 1)
        #expect(fetched[0].decisionState == .undecided)
    }

    @Test("Approve sets state and decidedAt")
    @MainActor
    func approveState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let groupId = UUID()
        let decision = ReviewDecision(
            sessionId: UUID(),
            groupIndex: 0,
            groupId: groupId
        )
        context.insert(decision)
        decision.decisionState = .approved
        decision.decidedAt = Date()
        try context.save()

        let gid = groupId
        let pred = #Predicate<ReviewDecision> {
            $0.groupId == gid
        }
        let fetched = try context.fetch(
            FetchDescriptor<ReviewDecision>(predicate: pred)
        ).first!
        #expect(fetched.decisionState == .approved)
        #expect(fetched.decidedAt != nil)
    }

    @Test("Change keeper stores path and fingerprint fields")
    @MainActor
    func changeKeeperFields() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let decision = ReviewDecision(
            sessionId: UUID(),
            groupIndex: 0,
            groupId: UUID()
        )
        context.insert(decision)

        decision.selectedKeeperPath = "/tmp/test/photo.jpg"
        decision.selectedKeeperFingerprint = "abc123"
        decision.selectedKeeperFileSize = 5000
        decision.decisionState = .approved
        try context.save()

        #expect(decision.selectedKeeperPath == "/tmp/test/photo.jpg")
        #expect(decision.selectedKeeperFingerprint == "abc123")
        #expect(decision.selectedKeeperFileSize == 5000)
    }

    @Test("Decision state transitions")
    @MainActor
    func stateTransitions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let decision = ReviewDecision(
            sessionId: UUID(),
            groupIndex: 0,
            groupId: UUID()
        )
        context.insert(decision)

        #expect(decision.decisionState == .undecided)

        decision.decisionState = .approved
        #expect(decision.decisionStateRaw == 1)

        decision.decisionState = .skipped
        #expect(decision.decisionStateRaw == 2)

        decision.decisionState = .notDuplicate
        #expect(decision.decisionStateRaw == 5)
    }

    @Test("Decision index map builds correctly")
    @MainActor
    func decisionIndexMap() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let sessionId = UUID()
        let groupIds = (0..<5).map { _ in UUID() }

        for (i, gid) in groupIds.enumerated() {
            let d = ReviewDecision(
                sessionId: sessionId,
                groupIndex: i,
                groupId: gid
            )
            if i < 2 {
                d.decisionState = .approved
                d.decidedAt = Date()
            }
            context.insert(d)
        }
        try context.save()

        let vm = GroupListViewModel()
        vm.loadDecisionIndex(
            sessionId: sessionId, context: context
        )

        #expect(vm.decisionByGroupId.count == 5)
        #expect(vm.reviewedCount == 2)

        let approvedState = vm.decisionByGroupId[groupIds[0]]
        #expect(approvedState?.state == .approved)
        #expect(approvedState?.decidedAt != nil)

        let undecidedState = vm.decisionByGroupId[groupIds[3]]
        #expect(undecidedState?.state == .undecided)
    }

    @Test("Update decision map propagates immediately")
    @MainActor
    func updateMapPropagation() throws {
        let vm = GroupListViewModel()
        let groupId = UUID()

        vm.hydrateDecisionSnapshot(
            groupId: groupId,
            snapshot: DecisionSnapshot(
                state: .approved, decidedAt: Date()
            )
        )

        #expect(vm.decisionByGroupId[groupId]?.state == .approved)
        #expect(vm.reviewedCount == 1)
    }

    @Test("DecisionState display properties")
    func displayProperties() {
        #expect(DecisionState.approved.displayName == "Approved")
        #expect(
            DecisionState.approved.systemImage
                == "checkmark.circle.fill"
        )
        #expect(DecisionState.skipped.displayName == "Skipped")
        #expect(
            DecisionState.notDuplicate.displayName
                == "Not Duplicate"
        )
    }

    @Test("Artifact identity stored on decision")
    @MainActor
    func artifactIdentity() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let decision = ReviewDecision(
            sessionId: UUID(),
            groupIndex: 0,
            groupId: UUID()
        )
        context.insert(decision)

        decision.artifactIdentity = "test.ndjson.gz:2025-01-01"
        decision.decisionState = .approved
        try context.save()

        #expect(
            decision.artifactIdentity
                == "test.ndjson.gz:2025-01-01"
        )
    }
}
