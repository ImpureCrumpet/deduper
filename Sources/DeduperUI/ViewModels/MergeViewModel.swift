import Foundation
import DeduperKit
import SwiftData
import os

// MARK: - Plan Types

/// Validation warning for a single group in the merge plan.
public enum MergeValidationWarning: Sendable, Identifiable {
    case noKeeperDetermined(groupIndex: Int)
    case keeperMissing(groupIndex: Int, path: String)
    case keeperNotMember(groupIndex: Int, path: String)
    case keeperChanged(groupIndex: Int, path: String)
    case nonKeeperMissing(groupIndex: Int, count: Int)
    case keeperConflict(groupIndex: Int, path: String)
    case protectedPath(groupIndex: Int, path: String)
    case companionIsKeeper(groupIndex: Int, path: String)

    public var id: String {
        switch self {
        case .noKeeperDetermined(let i): "noKeeper-\(i)"
        case .keeperMissing(let i, _): "keeperMissing-\(i)"
        case .keeperNotMember(let i, _): "keeperNotMember-\(i)"
        case .keeperChanged(let i, _): "keeperChanged-\(i)"
        case .nonKeeperMissing(let i, _): "nonKeeperMissing-\(i)"
        case .keeperConflict(let i, _): "keeperConflict-\(i)"
        case .protectedPath(let i, _): "protectedPath-\(i)"
        case .companionIsKeeper(let i, _): "companionKeeper-\(i)"
        }
    }

    public var isSkip: Bool {
        switch self {
        case .noKeeperDetermined, .keeperMissing: true
        default: false
        }
    }

    public var message: String {
        switch self {
        case .noKeeperDetermined(let i):
            "Group \(i): no keeper could be determined"
        case .keeperMissing(let i, let p):
            "Group \(i): keeper missing — \(URL(fileURLWithPath: p).lastPathComponent)"
        case .keeperNotMember(let i, let p):
            "Group \(i): selected keeper not in group — \(URL(fileURLWithPath: p).lastPathComponent)"
        case .keeperChanged(let i, let p):
            "Group \(i): keeper modified since review — \(URL(fileURLWithPath: p).lastPathComponent)"
        case .nonKeeperMissing(let i, let c):
            "Group \(i): \(c) file(s) already missing"
        case .keeperConflict(let i, let p):
            "Group \(i): file is keeper elsewhere — \(URL(fileURLWithPath: p).lastPathComponent)"
        case .protectedPath(let i, let p):
            "Group \(i): protected system path — \(URL(fileURLWithPath: p).lastPathComponent)"
        case .companionIsKeeper(let i, let p):
            "Group \(i): companion is keeper elsewhere — \(URL(fileURLWithPath: p).lastPathComponent)"
        }
    }
}

/// Per-group validation result ready for merge.
public struct MergePlanItem: Identifiable, Sendable {
    public let id: UUID  // groupId
    public let groupIndex: Int
    public let keeperPath: String
    public let nonKeeperBundles: [AssetBundle]
    public let warnings: [MergeValidationWarning]

    public var totalFiles: Int {
        nonKeeperBundles.reduce(0) { $0 + $1.allFiles.count }
    }
}

/// Why the merge plan is empty. Computed during validation where
/// SwiftData context is available — not inferred in the view.
public enum MergeEmptyReason: Sendable {
    case noApprovedDecisions
    case allAlreadyMerged(count: Int)
    case allSkippedDuringValidation
}

/// Complete validated merge plan.
public struct MergePlan: Sendable {
    public let items: [MergePlanItem]
    public let skippedGroups: [MergeValidationWarning]
    public let missingNonKeeperCount: Int
    /// Non-nil when `items.isEmpty`, explains why.
    public let emptyReason: MergeEmptyReason?

    public var totalAssetBundles: Int {
        items.reduce(0) { $0 + $1.nonKeeperBundles.count }
    }

    public var totalFiles: Int {
        items.reduce(0) { $0 + $1.totalFiles }
    }

    public var companionCount: Int {
        items.reduce(0) { sum, item in
            sum + item.nonKeeperBundles.reduce(0) {
                $0 + $1.companions.count
            }
        }
    }
}

/// Phase of the merge flow state machine.
public enum MergePhase {
    case idle
    case validating
    case preview(MergePlan)
    case executing
    case completed(MergeTransaction)
    case failed(String)
    case undoFailed(
        failures: [String], transaction: MergeTransaction
    )
}

// MARK: - ViewModel

/// Coordinates merge validation, execution, and undo.
/// Fetch SwiftData on main actor, build plan off-main.
@MainActor
@Observable
public final class MergeViewModel {
    private static let logger = Logger(
        subsystem: "app.deduper.ui", category: "merge"
    )

    public var phase: MergePhase = .idle
    public var lastTransaction: MergeTransaction?

    private let mergeService = MergeService()
    private let companionResolver = CompanionResolver()
    private let logDirectory: URL?
    private let quarantineRoot: URL?
    private var validateTask: Task<Void, Never>?
    private var executeTask: Task<Void, Never>?
    /// Group IDs from the last successful merge, for undo reversal.
    private var lastMergedGroupIds: [UUID]?
    /// Session that was merged — undo only offered when this matches.
    public private(set) var lastMergedSessionId: UUID?
    /// Container reference for undo decision transitions.
    private var lastContainer: ModelContainer?
    private var loadTask: Task<Void, Never>?
    private var loadEpoch: UInt64 = 0

    public init(
        logDirectory: URL? = nil,
        quarantineRoot: URL? = nil
    ) {
        self.logDirectory = logDirectory
        self.quarantineRoot = quarantineRoot
    }

    // MARK: - Validate

    /// Build and validate a merge plan from approved decisions.
    public func validate(
        sessionId: UUID,
        container: ModelContainer
    ) {
        validateTask?.cancel()
        phase = .validating
        lastMergedSessionId = sessionId

        validateTask = Task {
            do {
                // Phase 1: fetch on main actor
                let snapshot = try fetchMergeInputs(
                    sessionId: sessionId,
                    container: container
                )

                try Task.checkCancellation()

                // Phase 2: build plan off-main
                let plan = try await buildPlan(
                    from: snapshot,
                    mergedDecisionCount:
                        snapshot.mergedDecisionCount
                )

                try Task.checkCancellation()

                // Phase 3: publish on main actor
                phase = .preview(plan)
            } catch is CancellationError {
                // Normal cancellation
            } catch {
                Self.logger.error(
                    "Merge validation failed: \(error)"
                )
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Execute

    /// Execute the validated merge plan.
    public func execute(
        plan: MergePlan,
        container: ModelContainer? = nil
    ) {
        executeTask?.cancel()
        phase = .executing

        executeTask = Task {
            do {
                try Task.checkCancellation()

                let assets = plan.items.flatMap(\.nonKeeperBundles)
                guard !assets.isEmpty else {
                    phase = .failed("No files to merge.")
                    return
                }

                let sid = lastMergedSessionId
                let mergedIds = plan.items.map(\.id)
                let transaction = try await Task.detached {
                    try MergeService().moveToQuarantine(
                        assets: assets,
                        sessionId: sid,
                        groupIds: mergedIds,
                        logDirectory: self.logDirectory,
                        quarantineRoot: self.quarantineRoot
                    )
                }.value

                lastTransaction = transaction
                lastMergedGroupIds = mergedIds

                // Only transition to .merged when execution
                // fully succeeded — partial failures keep
                // decisions as .approved so the user can retry.
                if let container, transaction.errorCount == 0 {
                    lastContainer = container
                    transitionToMerged(
                        groupIds: mergedIds,
                        container: container
                    )
                } else if let container {
                    lastContainer = container
                }

                phase = .completed(transaction)
            } catch is CancellationError {
                // Normal cancellation
            } catch {
                Self.logger.error("Merge execution failed: \(error)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Callback for the parent view to update in-memory decision
    /// snapshots after merge/undo transitions. Carries the target
    /// state explicitly — never inferred from current snapshot.
    public var onDecisionsTransitioned:
        (([UUID], DecisionState) -> Void)?

    // MARK: - Undo

    /// Undo the last completed transaction. Two-phase:
    /// Phase A: filesystem restore + mark undone on disk.
    /// Phase B: SwiftData .merged→.approved reconciliation.
    /// If A succeeds but B fails, only B is retryable.
    public func undoLastTransaction() {
        guard let transaction = lastTransaction else { return }

        let logDir = self.logDirectory
        Task {
            // Phase A: filesystem + persisted status
            let failures = await Task.detached {
                MergeService().undo(transaction: transaction)
            }.value

            guard failures.isEmpty else {
                phase = .undoFailed(
                    failures: failures,
                    transaction: transaction
                )
                return
            }

            await Task.detached {
                try? MergeService().markUndone(
                    transaction: transaction,
                    logDirectory: logDir
                )
            }.value

            // Phase B: SwiftData reconciliation
            let reconciled = reconcileDecisions()
            if reconciled {
                lastTransaction = nil
                lastMergedGroupIds = nil
                phase = .idle
            } else {
                // Files restored, log says .undone, but
                // SwiftData still says .merged. Offer retry
                // for reconciliation only.
                phase = .undoFailed(
                    failures: [
                        "Files restored but decision state"
                        + " could not be updated. Retry to"
                        + " reconcile, or restart the app."
                    ],
                    transaction: transaction
                )
            }
        }
    }

    /// Retry only the SwiftData reconciliation step after
    /// undo already succeeded on the filesystem.
    public func retryReconciliation() {
        let reconciled = reconcileDecisions()
        if reconciled {
            lastTransaction = nil
            lastMergedGroupIds = nil
            phase = .idle
        }
        // If still fails, phase stays .undoFailed
    }

    // MARK: - Reset

    public func reset() {
        validateTask?.cancel()
        executeTask?.cancel()
        loadTask?.cancel()
        loadEpoch &+= 1
        phase = .idle
    }

    // MARK: - Persisted Undo

    /// Load a persisted transaction from disk for the given session.
    /// Called on session selection to restore undo affordance across
    /// app launches. Uses epoch guard to cancel stale loads on rapid
    /// session switching.
    public func loadPersistedTransaction(
        for sessionId: UUID,
        container: ModelContainer
    ) {
        // Don't overwrite an in-memory transaction from the
        // current session (already more up-to-date).
        if lastTransaction != nil,
           lastMergedSessionId == sessionId {
            return
        }

        loadTask?.cancel()
        loadEpoch &+= 1
        let expectedEpoch = loadEpoch
        let logDir = self.logDirectory

        loadTask = Task {
            do {
                let transactions = try await Task.detached {
                    try MergeService()
                        .listTransactions(logDirectory: logDir)
                }.value

                // Epoch guard: discard if a newer load started
                guard expectedEpoch == loadEpoch else { return }
                try Task.checkCancellation()

                // Reconcile stranded decisions from CLI
                // undo/purge (idempotent, runs on @MainActor)
                reconcileStrandedDecisions(
                    transactions: transactions,
                    sessionId: sessionId,
                    container: container
                )

                guard let match = transactions.first(where: {
                    $0.sessionId == sessionId
                        && isUndoEligible($0)
                }) else { return }

                // Second epoch guard after eligibility check
                guard expectedEpoch == loadEpoch else { return }

                lastTransaction = match
                lastMergedSessionId = sessionId
                lastContainer = container
                lastMergedGroupIds = match.groupIds
            } catch is CancellationError {
                // Normal cancellation
            } catch {
                Self.logger.error(
                    "Failed to load persisted tx: \(error)"
                )
            }
        }
    }

    // MARK: - Decision Transitions

    /// Transition merged groups from .approved to .merged in SwiftData.
    private func transitionToMerged(
        groupIds: [UUID],
        container: ModelContainer
    ) {
        let context = ModelContext(container)
        for gid in groupIds {
            let id = gid
            let pred = #Predicate<ReviewDecision> {
                $0.groupId == id
            }
            var desc = FetchDescriptor<ReviewDecision>(
                predicate: pred
            )
            desc.fetchLimit = 1
            if let decision = try? context.fetch(desc).first,
               decision.decisionState == .approved {
                decision.decisionState = .merged
                decision.decidedAt = Date()
            }
        }
        do {
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to persist .merged transition: \(error)"
            )
        }

        onDecisionsTransitioned?(groupIds, .merged)
    }

    /// Phase B of undo: transition SwiftData .merged→.approved.
    /// Returns true on success. Safe to retry — idempotent.
    private func reconcileDecisions() -> Bool {
        guard let container = lastContainer,
              let ids = lastMergedGroupIds else { return true }
        let context = ModelContext(container)
        for gid in ids {
            let id = gid
            let pred = #Predicate<ReviewDecision> {
                $0.groupId == id
            }
            var desc = FetchDescriptor<ReviewDecision>(
                predicate: pred
            )
            desc.fetchLimit = 1
            if let decision = try? context.fetch(desc).first,
               decision.decisionState == .merged {
                decision.decisionState = .approved
                decision.decidedAt = Date()
            }
        }
        do {
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to reconcile decisions: \(error)"
            )
            return false
        }

        onDecisionsTransitioned?(ids, .approved)
        return true
    }

    // MARK: - Stranded Decision Reconciliation

    /// Reconcile decisions stranded as `.merged` by CLI undo/purge.
    /// Scans transactions for this session that are `.undone` or
    /// `.purged` with known groupIds, and transitions matching
    /// SwiftData decisions back to `.approved`. Idempotent.
    private func reconcileStrandedDecisions(
        transactions: [MergeTransaction],
        sessionId: UUID,
        container: ModelContainer
    ) {
        let stale = transactions.filter {
            $0.sessionId == sessionId
                && ($0.status == .undone || $0.status == .purged)
                && $0.groupIds != nil
        }
        guard !stale.isEmpty else { return }

        let context = ModelContext(container)
        var reconciledIds: [UUID] = []
        for tx in stale {
            guard let ids = tx.groupIds else { continue }
            for gid in ids {
                let id = gid
                let pred = #Predicate<ReviewDecision> {
                    $0.groupId == id
                }
                var desc = FetchDescriptor<ReviewDecision>(
                    predicate: pred
                )
                desc.fetchLimit = 1
                if let decision = try? context.fetch(desc).first,
                   decision.decisionState == .merged {
                    decision.decisionState = .approved
                    decision.decidedAt = Date()
                    reconciledIds.append(gid)
                }
            }
        }
        guard !reconciledIds.isEmpty else { return }
        try? context.save()
        onDecisionsTransitioned?(reconciledIds, .approved)
    }

    // MARK: - Private: Fetch (main actor)

    /// Sendable snapshot of all data needed to build a merge plan.
    private struct MergeInputSnapshot: Sendable {
        let groups: [GroupSnapshot]
        /// Count of merged decisions (for empty-reason reporting).
        let mergedDecisionCount: Int
    }

    private struct GroupSnapshot: Sendable {
        let groupId: UUID
        let groupIndex: Int
        let suggestedKeeperPath: String?
        let selectedKeeperPath: String?
        let selectedKeeperFingerprint: String?
        let members: [MemberSnapshot]
    }

    private struct MemberSnapshot: Sendable {
        let filePath: String
        let isKeeper: Bool
    }

    private func fetchMergeInputs(
        sessionId: UUID,
        container: ModelContainer
    ) throws -> MergeInputSnapshot {
        let context = ModelContext(container)

        // Fetch session for currentRunId
        let sid = sessionId
        let sessionPred = #Predicate<SessionIndex> {
            $0.sessionId == sid
        }
        var sessionDesc = FetchDescriptor<SessionIndex>(
            predicate: sessionPred
        )
        sessionDesc.fetchLimit = 1

        guard let session = try context.fetch(sessionDesc).first,
              let runId = session.currentRunId
        else {
            throw MergeValidationError.notMaterialized
        }

        // Fetch approved decisions
        let decisionPred = #Predicate<ReviewDecision> {
            $0.sessionId == sid && $0.decisionStateRaw == 1
        }
        let decisions = try context.fetch(
            FetchDescriptor<ReviewDecision>(predicate: decisionPred)
        )

        // For each decision, fetch group summary + members
        var groups: [GroupSnapshot] = []
        for decision in decisions {
            let gid = decision.groupId
            let rid = runId

            // GroupSummary scoped to run
            let summaryPred = #Predicate<GroupSummary> {
                $0.groupId == gid
                    && $0.materializationRunId == rid
            }
            var summaryDesc = FetchDescriptor<GroupSummary>(
                predicate: summaryPred
            )
            summaryDesc.fetchLimit = 1
            let summary = try context.fetch(summaryDesc).first

            // GroupMember scoped to run
            let memberPred = #Predicate<GroupMember> {
                $0.groupId == gid
                    && $0.materializationRunId == rid
            }
            let memberDesc = FetchDescriptor<GroupMember>(
                predicate: memberPred,
                sortBy: [SortDescriptor(\.memberIndex)]
            )
            let memberRows = try context.fetch(memberDesc)

            groups.append(GroupSnapshot(
                groupId: decision.groupId,
                groupIndex: decision.groupIndex,
                suggestedKeeperPath: summary?.suggestedKeeperPath,
                selectedKeeperPath: decision.selectedKeeperPath,
                selectedKeeperFingerprint:
                    decision.selectedKeeperFingerprint,
                members: memberRows.map {
                    MemberSnapshot(
                        filePath: $0.filePath,
                        isKeeper: $0.isKeeper
                    )
                }
            ))
        }

        // Count merged decisions for empty-reason reporting
        let mergedRaw = DecisionState.merged.rawValue
        let mergedPred = #Predicate<ReviewDecision> {
            $0.sessionId == sid && $0.decisionStateRaw == mergedRaw
        }
        let mergedCount = (try? context.fetchCount(
            FetchDescriptor<ReviewDecision>(predicate: mergedPred)
        )) ?? 0

        return MergeInputSnapshot(
            groups: groups,
            mergedDecisionCount: mergedCount
        )
    }

    // MARK: - Private: Build plan (off-main)

    private nonisolated func buildPlan(
        from snapshot: MergeInputSnapshot,
        mergedDecisionCount: Int
    ) async throws -> MergePlan {
        var items: [MergePlanItem] = []
        var skipped: [MergeValidationWarning] = []
        var missingNonKeeperTotal = 0

        // Pass 1: resolve keepers and build per-group data
        var resolved: [ResolvedGroup] = []

        for group in snapshot.groups {
            let result = resolveGroup(group)
            switch result {
            case .skip(let warning):
                skipped.append(warning)
            case .resolved(let rg):
                resolved.append(rg)
            }
        }

        // Pass 2: build global keeper set and dedup move targets
        let keeperSet = Set(
            resolved.map { canonicalize($0.keeperPath) }
        )
        var seenMovePaths = Set<String>()

        for group in resolved {
            var bundles: [AssetBundle] = []
            var warnings = group.warnings
            var missingCount = 0

            for path in group.nonKeeperPaths {
                let canonical = canonicalize(path)

                // Skip if this file is a keeper in another group
                if keeperSet.contains(canonical) {
                    warnings.append(.keeperConflict(
                        groupIndex: group.groupIndex,
                        path: path
                    ))
                    continue
                }

                // Dedup across groups
                guard seenMovePaths.insert(canonical).inserted
                else { continue }

                // Check existence
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(
                    atPath: path
                ) else {
                    missingCount += 1
                    continue
                }

                // Protected path check
                guard !isProtectedPath(url) else {
                    warnings.append(.protectedPath(
                        groupIndex: group.groupIndex,
                        path: path
                    ))
                    continue
                }

                // Resolve companions: filter keepers, dedup,
                // protect, and canonicalize
                let companionSet = CompanionResolver()
                    .resolve(for: url)
                let safeCompanions: [URL] = companionSet.companionURLs
                    .compactMap { companion in
                        let cPath = canonicalize(companion.path)
                        // Keeper protection
                        if keeperSet.contains(cPath) {
                            warnings.append(.companionIsKeeper(
                                groupIndex: group.groupIndex,
                                path: companion.path
                            ))
                            return nil
                        }
                        // Dedup across all moved paths
                        let cURL = URL(fileURLWithPath: cPath)
                        guard seenMovePaths.insert(cPath).inserted
                        else { return nil }
                        // Protected path check
                        guard !isProtectedPath(cURL) else {
                            warnings.append(.protectedPath(
                                groupIndex: group.groupIndex,
                                path: companion.path
                            ))
                            return nil
                        }
                        return cURL
                    }
                bundles.append(AssetBundle(
                    primary: url,
                    companions: safeCompanions
                ))
            }

            if missingCount > 0 {
                warnings.append(.nonKeeperMissing(
                    groupIndex: group.groupIndex,
                    count: missingCount
                ))
                missingNonKeeperTotal += missingCount
            }

            // Only include if there are bundles to move
            if !bundles.isEmpty {
                items.append(MergePlanItem(
                    id: group.groupId,
                    groupIndex: group.groupIndex,
                    keeperPath: group.keeperPath,
                    nonKeeperBundles: bundles,
                    warnings: warnings
                ))
            } else if !warnings.isEmpty {
                // No bundles but had warnings (e.g. all missing)
                skipped.append(contentsOf: warnings)
            }
        }

        let sortedItems = items.sorted {
            $0.groupIndex < $1.groupIndex
        }

        // Compute empty reason when no actionable items
        let emptyReason: MergeEmptyReason?
        if sortedItems.isEmpty {
            if snapshot.groups.isEmpty && mergedDecisionCount > 0 {
                emptyReason = .allAlreadyMerged(
                    count: mergedDecisionCount
                )
            } else if snapshot.groups.isEmpty {
                emptyReason = .noApprovedDecisions
            } else {
                emptyReason = .allSkippedDuringValidation
            }
        } else {
            emptyReason = nil
        }

        return MergePlan(
            items: sortedItems,
            skippedGroups: skipped,
            missingNonKeeperCount: missingNonKeeperTotal,
            emptyReason: emptyReason
        )
    }

    private nonisolated func resolveGroup(
        _ group: GroupSnapshot
    ) -> ResolveResult {
        let idx = group.groupIndex
        var warnings: [MergeValidationWarning] = []
        let memberPaths = group.members.map(\.filePath)
        let canonicalMembers = Set(memberPaths.map { canonicalize($0) })

        // Step 1: resolve keeper
        var keeperPath: String?

        // 1a: user-selected keeper
        if let selected = group.selectedKeeperPath {
            let canonical = canonicalize(selected)
            if canonicalMembers.contains(canonical) {
                keeperPath = selected
            } else {
                warnings.append(.keeperNotMember(
                    groupIndex: idx, path: selected
                ))
                // Fall through to other resolution methods
            }
        }

        // 1b: isKeeper flag on members
        if keeperPath == nil {
            let keepers = group.members.filter(\.isKeeper)
            if keepers.count == 1 {
                keeperPath = keepers[0].filePath
            }
        }

        // 1c: suggested keeper from summary
        if keeperPath == nil, let suggested = group.suggestedKeeperPath {
            let canonical = canonicalize(suggested)
            if canonicalMembers.contains(canonical) {
                keeperPath = suggested
            }
        }

        // No keeper → skip
        guard let keeper = keeperPath else {
            return .skip(.noKeeperDetermined(groupIndex: idx))
        }

        // Step 2: keeper existence
        guard FileManager.default.fileExists(atPath: keeper) else {
            return .skip(.keeperMissing(
                groupIndex: idx, path: keeper
            ))
        }

        // Step 3: fingerprint drift
        if let expected = group.selectedKeeperFingerprint {
            let current = ContentFingerprint.compute(
                for: URL(fileURLWithPath: keeper)
            )
            if current != expected {
                warnings.append(.keeperChanged(
                    groupIndex: idx, path: keeper
                ))
            }
        }

        // Step 4: collect non-keepers
        let canonicalKeeper = canonicalize(keeper)
        let nonKeepers = memberPaths.filter {
            canonicalize($0) != canonicalKeeper
        }

        return .resolved(ResolvedGroup(
            groupId: group.groupId,
            groupIndex: group.groupIndex,
            keeperPath: keeper,
            nonKeeperPaths: nonKeepers,
            warnings: warnings
        ))
    }

    private enum ResolveResult {
        case skip(MergeValidationWarning)
        case resolved(ResolvedGroup)
    }

    private struct ResolvedGroup: Sendable {
        let groupId: UUID
        let groupIndex: Int
        let keeperPath: String
        let nonKeeperPaths: [String]
        let warnings: [MergeValidationWarning]
    }

    // MARK: - Undo Eligibility

    /// Full eligibility check: status + scope + filesystem.
    /// This is THE gate for undo affordances — used in
    /// loadPersistedTransaction, AppRootView toolbar, etc.
    private nonisolated func isUndoEligible(
        _ transaction: MergeTransaction
    ) -> Bool {
        guard transaction.status.isStatusUndoEligible else {
            return false
        }
        guard transaction.groupIds != nil else {
            return false  // scope unknown, can't reconcile
        }
        return transaction.entries.contains {
            guard let tp = $0.trashedPath else { return false }
            return FileManager.default.fileExists(atPath: tp)
        }
    }

    /// Whether the undo button should be shown. Checks full
    /// eligibility: status, scope, and filesystem existence.
    public var canUndo: Bool {
        guard let tx = lastTransaction else { return false }
        return isUndoEligible(tx)
    }

    // MARK: - Helpers

    private nonisolated func canonicalize(_ path: String) -> String {
        PathIdentity.canonical(path)
    }

    /// Duplicates MergeService's protected path check for early
    /// UI-side warning. MergeService also refuses at execution time.
    private nonisolated func isProtectedPath(_ url: URL) -> Bool {
        let path = url.path
        let prefixes = [
            "/System", "/Library", "/usr",
            "/bin", "/sbin", "/Applications",
            "/private/var",
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }
}

// MARK: - Errors

enum MergeValidationError: Error, LocalizedError {
    case notMaterialized

    var errorDescription: String? {
        switch self {
        case .notMaterialized:
            "Session has not been materialized. "
                + "Select the session to trigger materialization."
        }
    }
}
