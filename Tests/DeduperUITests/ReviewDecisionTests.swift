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

    // MARK: - Export/Import (AD-003)

    @Test("toStoredForm roundtrip preserves all fields")
    @MainActor
    func storedFormRoundtrip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let sessionId = UUID()
        let groupId = UUID()
        let decision = ReviewDecision(
            sessionId: sessionId,
            groupIndex: 3,
            groupId: groupId,
            decisionState: .approved
        )
        decision.selectedKeeperPath = "/tmp/photo.jpg"
        decision.selectedKeeperFingerprint = "sha256:abc"
        decision.selectedKeeperFileSize = 4096
        decision.artifactIdentity = "scan.ndjson.gz:2025-06-01"
        decision.notes = "Looks correct"
        decision.decidedAt = Date(
            timeIntervalSinceReferenceDate: 700_000_000
        )
        context.insert(decision)
        try context.save()

        let stored = decision.toStoredForm()

        // Encode to JSON and decode back
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stored)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            StoredReviewDecision.self, from: data
        )

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.sessionId == sessionId)
        #expect(decoded.groupIndex == 3)
        #expect(decoded.groupId == groupId)
        #expect(decoded.decisionState == DecisionState.approved.rawValue)
        #expect(decoded.selectedKeeperPath == "/tmp/photo.jpg")
        #expect(decoded.selectedKeeperFingerprint == "sha256:abc")
        #expect(decoded.selectedKeeperFileSize == 4096)
        #expect(
            decoded.artifactIdentity == "scan.ndjson.gz:2025-06-01"
        )
        #expect(decoded.notes == "Looks correct")
        #expect(decoded.decidedAt != nil)
    }

    @Test("from() imports stored decision into context")
    @MainActor
    func fromImportsCorrectly() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let stored = StoredReviewDecision(
            sessionId: UUID(),
            groupIndex: 2,
            groupId: UUID(),
            decisionState: DecisionState.skipped.rawValue,
            selectedKeeperPath: "/tmp/keeper.jpg",
            notes: "Imported"
        )

        let result = try ReviewDecision.from(stored, context: context)
        #expect(result != nil)
        try context.save()

        #expect(result?.decisionState == .skipped)
        #expect(result?.selectedKeeperPath == "/tmp/keeper.jpg")
        #expect(result?.notes == "Imported")
        #expect(result?.groupIndex == 2)
    }

    @Test("from() returns nil on conflict")
    @MainActor
    func fromDetectsConflict() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let groupId = UUID()
        let existing = ReviewDecision(
            sessionId: UUID(),
            groupIndex: 0,
            groupId: groupId
        )
        context.insert(existing)
        try context.save()

        let stored = StoredReviewDecision(
            sessionId: UUID(),
            groupIndex: 0,
            groupId: groupId,
            decisionState: DecisionState.approved.rawValue
        )

        let result = try ReviewDecision.from(stored, context: context)
        #expect(result == nil)
    }

    @Test("exportSession and importSession roundtrip")
    @MainActor
    func exportImportRoundtrip() throws {
        let sourceContainer = try makeContainer()
        let sourceContext = ModelContext(sourceContainer)

        let sessionId = UUID()
        for i in 0..<3 {
            let d = ReviewDecision(
                sessionId: sessionId,
                groupIndex: i,
                groupId: UUID(),
                decisionState: i == 0 ? .approved : .skipped
            )
            d.notes = "Decision \(i)"
            sourceContext.insert(d)
        }
        try sourceContext.save()

        let exported = try ReviewDecision.exportSession(
            sessionId: sessionId, context: sourceContext
        )

        // Import into a fresh container
        let destContainer = try makeContainer()
        let destContext = ModelContext(destContainer)

        let imported = try ReviewDecision.importSession(
            from: exported, context: destContext
        )
        #expect(imported == 3)

        // Verify all decisions present
        let all = try destContext.fetch(
            FetchDescriptor<ReviewDecision>()
        )
        #expect(all.count == 3)

        let approvedCount = all.filter {
            $0.decisionState == .approved
        }.count
        #expect(approvedCount == 1)
    }

    @Test("importSession skips duplicates on second import")
    @MainActor
    func importSkipsDuplicates() throws {
        let sourceContainer = try makeContainer()
        let sourceContext = ModelContext(sourceContainer)

        let sessionId = UUID()
        let d = ReviewDecision(
            sessionId: sessionId,
            groupIndex: 0,
            groupId: UUID(),
            decisionState: .approved
        )
        sourceContext.insert(d)
        try sourceContext.save()

        let exported = try ReviewDecision.exportSession(
            sessionId: sessionId, context: sourceContext
        )

        let destContainer = try makeContainer()
        let destContext = ModelContext(destContainer)

        let first = try ReviewDecision.importSession(
            from: exported, context: destContext
        )
        #expect(first == 1)

        let second = try ReviewDecision.importSession(
            from: exported, context: destContext
        )
        #expect(second == 0)

        let all = try destContext.fetch(
            FetchDescriptor<ReviewDecision>()
        )
        #expect(all.count == 1)
    }
}
