import Foundation
import AppKit
import SwiftData
import DeduperKit
import os

/// Lightweight snapshot of a review decision for fast list rendering.
public struct DecisionSnapshot: Sendable {
    public let state: DecisionState
    public let decidedAt: Date?

    public init(state: DecisionState, decidedAt: Date?) {
        self.state = state
        self.decidedAt = decidedAt
    }
}

/// View mode for the group list panel.
public enum GroupListMode: String, CaseIterable, Sendable {
    case list = "List"
    case listThumbnails = "List + Thumbnails"
    case grid = "Grid"

    public var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .listThumbnails: "list.bullet.below.rectangle"
        case .grid: "square.grid.2x2"
        }
    }
}

/// Sort options for the group list.
public enum GroupSortOrder: String, CaseIterable, Sendable {
    case confidence = "Confidence"
    case spaceSavings = "Space Savings"
    case memberCount = "Member Count"
    case totalSize = "Total Size"
}

/// Auto-advance behavior after a review decision.
public enum AutoAdvanceMode: String, CaseIterable, Sendable {
    case nextUndecided = "Next Undecided"
    case nextInList = "Next in List"
    case off = "Off"
}

/// Drives the group list view with filtering, sorting, and search.
@MainActor
@Observable
public final class GroupListViewModel {
    private static let logger = Logger(
        subsystem: "app.deduper.ui", category: "group-list"
    )

    // All groups for current session (unfiltered)
    public private(set) var allGroups: [GroupSummary] = []

    // Filtered + sorted subset
    public private(set) var filteredGroups: [GroupSummary] = []

    // Selection
    public var selectedGroupId: UUID?

    // View mode
    public var listMode: GroupListMode = .list

    // Filters
    public var sortOrder: GroupSortOrder = .confidence {
        didSet { applyFilters() }
    }
    public var sortAscending: Bool = false {
        didSet { applyFilters() }
    }
    public var searchText: String = "" {
        didSet { applyFilters() }
    }
    public var mediaTypeFilter: Int16? = nil {
        didSet { applyFilters(); normalizeSelection() }
    }
    public var showLargeGroupsOnly: Bool = false {
        didSet { applyFilters(); normalizeSelection() }
    }
    public var showMixedFormatOnly: Bool = false {
        didSet { applyFilters(); normalizeSelection() }
    }
    public var matchKindFilter: String? = nil {
        didSet { applyFilters(); normalizeSelection() }
    }
    public var decisionStateFilter: DecisionState? = nil {
        didSet { applyFilters(); normalizeSelection() }
    }

    // Auto-advance
    public var autoAdvanceMode: AutoAdvanceMode = .nextUndecided

    // Decision index (one-fetch, keyed by groupId)
    public private(set) var decisionByGroupId:
        [UUID: DecisionSnapshot] = [:]
    public var reviewedCount: Int {
        decisionByGroupId.values.count {
            $0.state != .undecided
        }
    }

    // Thumbnail cache for list/grid (keyed by keeper path)
    public private(set) var thumbnailByGroupId: [UUID: NSImage] = [:]
    private let thumbnailService = ThumbnailService()

    // Stats
    public var totalGroups: Int { allGroups.count }
    public var totalSpaceSavings: Int64 {
        allGroups.reduce(0) { $0 + $1.spaceSavings }
    }
    public var filteredCount: Int { filteredGroups.count }

    /// Count of undecided exact-match groups (for batch approve).
    public var undecidedExactCount: Int {
        allGroups.count { group in
            group.matchKind == MatchKind.sha256Exact.rawValue
                && (decisionByGroupId[group.groupId]?.state
                    ?? .undecided) == .undecided
        }
    }

    public init() {}

    /// Load all GroupSummary rows for the current materialization run.
    public func loadGroups(
        sessionId: UUID,
        currentRunId: UUID?,
        context: ModelContext
    ) {
        guard let runId = currentRunId else {
            allGroups = []
            applyFilters()
            return
        }

        let predicate = #Predicate<GroupSummary> {
            $0.sessionId == sessionId
                && $0.materializationRunId == runId
        }
        let descriptor = FetchDescriptor<GroupSummary>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.groupIndex)]
        )

        do {
            allGroups = try context.fetch(descriptor)
        } catch {
            Self.logger.error(
                "Failed to fetch groups: \(error)"
            )
            allGroups = []
        }

        applyFilters()
    }

    /// Clear groups when session changes or is deselected.
    public func clear() {
        allGroups = []
        filteredGroups = []
        selectedGroupId = nil
        decisionByGroupId = [:]
        thumbnailByGroupId = [:]
    }

    /// Load thumbnails for visible groups (keeper path).
    /// Called when view mode requires thumbnails.
    public func loadThumbnails(for groups: [GroupSummary]) {
        for group in groups {
            guard thumbnailByGroupId[group.groupId] == nil,
                  let path = group.suggestedKeeperPath
            else { continue }
            let gid = group.groupId
            Task {
                let size: ThumbnailService.ThumbnailSize =
                    self.listMode == .grid
                    ? .detail : .list
                let image = await thumbnailService.thumbnail(
                    for: path, size: size
                )
                if let image {
                    self.thumbnailByGroupId[gid] = image
                }
            }
        }
    }

    /// Bulk-fetch all decisions for session into the in-memory map.
    public func loadDecisionIndex(
        sessionId: UUID,
        context: ModelContext
    ) {
        let sid = sessionId
        let predicate = #Predicate<ReviewDecision> {
            $0.sessionId == sid
        }
        let descriptor = FetchDescriptor<ReviewDecision>(
            predicate: predicate
        )

        do {
            let decisions = try context.fetch(descriptor)
            var map: [UUID: DecisionSnapshot] = [:]
            map.reserveCapacity(decisions.count)
            for d in decisions {
                map[d.groupId] = DecisionSnapshot(
                    state: d.decisionState,
                    decidedAt: d.decidedAt
                )
            }
            decisionByGroupId = map
        } catch {
            Self.logger.error(
                "Failed to fetch decisions: \(error)"
            )
            decisionByGroupId = [:]
        }

        applyFilters()
        normalizeSelection()
    }

    /// Non-interactive map hydration for loading from store or tests.
    /// Does NOT refilter or normalize selection. For interactive
    /// decisions, use `commitDecision(groupId:snapshot:)`.
    func hydrateDecisionSnapshot(
        groupId: UUID,
        snapshot: DecisionSnapshot
    ) {
        decisionByGroupId[groupId] = snapshot
    }

    /// Centralized decision transaction: updates the in-memory map,
    /// computes the auto-advance target (pre-refilter), refilters,
    /// normalizes selection, and overrides with the advance target.
    ///
    /// This is the single public entry point for interactive decisions.
    public func commitDecision(
        groupId: UUID,
        snapshot: DecisionSnapshot
    ) {
        decisionByGroupId[groupId] = snapshot
        let advanceTarget = computeAutoAdvanceTarget()
        applyFilters()
        // Prefer advance target if still valid post-refilter;
        // otherwise normalize to first-or-nil (one assignment).
        if let target = advanceTarget,
           filteredGroups.contains(where: {
               $0.groupId == target
           }) {
            selectedGroupId = target
        } else {
            normalizeSelection()
        }
    }

    /// Batch-approve all undecided SHA256 exact-match groups.
    /// Returns count of groups approved.
    @discardableResult
    public func batchApproveExactMatches(
        context: ModelContext
    ) -> Int {
        let targets = allGroups.filter { group in
            group.matchKind == MatchKind.sha256Exact.rawValue
                && (decisionByGroupId[group.groupId]?.state
                    ?? .undecided) == .undecided
        }

        guard !targets.isEmpty else { return 0 }

        for group in targets {
            let gid = group.groupId
            let predicate = #Predicate<ReviewDecision> {
                $0.groupId == gid
            }
            var descriptor = FetchDescriptor<ReviewDecision>(
                predicate: predicate
            )
            descriptor.fetchLimit = 1

            let decision: ReviewDecision
            if let existing = try? context.fetch(descriptor).first {
                decision = existing
            } else {
                decision = ReviewDecision(
                    sessionId: group.sessionId,
                    groupIndex: group.groupIndex,
                    groupId: group.groupId
                )
                context.insert(decision)
            }

            decision.decisionState = .approved
            decision.decidedAt = Date()

            decisionByGroupId[group.groupId] = DecisionSnapshot(
                state: .approved, decidedAt: decision.decidedAt
            )
        }

        do {
            try context.save()
        } catch {
            Self.logger.error(
                "Batch approve save failed: \(error)"
            )
        }

        applyFilters()
        normalizeSelection()
        return targets.count
    }

    /// Recompute filteredGroups from allGroups based on current filters.
    public func applyFilters() {
        var result = allGroups

        // Media type filter
        if let mediaType = mediaTypeFilter {
            result = result.filter { $0.mediaTypeRaw == mediaType }
        }

        // Risk flag filters
        if showLargeGroupsOnly {
            result = result.filter { $0.isLargeGroup }
        }
        if showMixedFormatOnly {
            result = result.filter { $0.isMixedFormat }
        }

        // Match kind filter
        if let kind = matchKindFilter {
            result = result.filter { $0.matchKind == kind }
        }

        // Decision state filter
        if let stateFilter = decisionStateFilter {
            result = result.filter { group in
                let state = decisionByGroupId[group.groupId]?.state
                    ?? .undecided
                return state == stateFilter
            }
        }

        // Search text (matches against suggested keeper path)
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { group in
                group.suggestedKeeperPath?.lowercased()
                    .contains(query) ?? false
            }
        }

        // Sort
        result.sort { a, b in
            let cmp: Bool
            switch sortOrder {
            case .confidence:
                cmp = a.confidence > b.confidence
            case .spaceSavings:
                cmp = a.spaceSavings > b.spaceSavings
            case .memberCount:
                cmp = a.memberCount > b.memberCount
            case .totalSize:
                cmp = a.totalSize > b.totalSize
            }
            return sortAscending ? !cmp : cmp
        }

        filteredGroups = result
    }

    /// Ensures `selectedGroupId` is valid in `filteredGroups`.
    /// Called after decision-driven transitions (commitDecision,
    /// loadDecisionIndex, batchApprove) and discrete filter changes
    /// (mediaType, matchKind, decisionState, etc.) — but NOT after
    /// searchText changes, to avoid detail pane churn while typing.
    private func normalizeSelection() {
        guard let current = selectedGroupId else { return }
        if !filteredGroups.contains(where: {
            $0.groupId == current
        }) {
            selectedGroupId = filteredGroups.first?.groupId
        }
    }

    // MARK: - Navigation

    /// Select the next group in the filtered list.
    public func selectNextGroup() {
        guard !filteredGroups.isEmpty else { return }
        guard let currentId = selectedGroupId,
              let idx = filteredGroups.firstIndex(
                  where: { $0.groupId == currentId }
              )
        else {
            selectedGroupId = filteredGroups.first?.groupId
            return
        }
        let nextIdx = filteredGroups.index(after: idx)
        if nextIdx < filteredGroups.endIndex {
            selectedGroupId = filteredGroups[nextIdx].groupId
        }
    }

    /// Select the previous group in the filtered list.
    public func selectPreviousGroup() {
        guard !filteredGroups.isEmpty else { return }
        guard let currentId = selectedGroupId,
              let idx = filteredGroups.firstIndex(
                  where: { $0.groupId == currentId }
              )
        else {
            selectedGroupId = filteredGroups.last?.groupId
            return
        }
        if idx > filteredGroups.startIndex {
            let prevIdx = filteredGroups.index(before: idx)
            selectedGroupId = filteredGroups[prevIdx].groupId
        }
    }

    /// Select the next undecided group. Returns false if none remain.
    @discardableResult
    public func selectNextUndecided() -> Bool {
        let startIdx: Int
        if let currentId = selectedGroupId,
           let idx = filteredGroups.firstIndex(
               where: { $0.groupId == currentId }
           ) {
            startIdx = filteredGroups.index(after: idx)
        } else {
            startIdx = filteredGroups.startIndex
        }

        // Search forward from current position
        for i in startIdx..<filteredGroups.endIndex {
            let gid = filteredGroups[i].groupId
            let state = decisionByGroupId[gid]?.state ?? .undecided
            if state == .undecided {
                selectedGroupId = gid
                return true
            }
        }

        // Wrap around from beginning
        let endIdx = min(
            startIdx, filteredGroups.endIndex
        )
        for i in filteredGroups.startIndex..<endIdx {
            let gid = filteredGroups[i].groupId
            let state = decisionByGroupId[gid]?.state ?? .undecided
            if state == .undecided {
                selectedGroupId = gid
                return true
            }
        }

        return false
    }

    /// Perform auto-advance after a decision. Call BEFORE applyFilters()
    /// when the decided group may disappear from the filtered list.
    /// Returns the next group ID to select, or nil for no change.
    public func computeAutoAdvanceTarget() -> UUID? {
        switch autoAdvanceMode {
        case .off:
            return nil
        case .nextInList:
            guard let currentId = selectedGroupId,
                  let idx = filteredGroups.firstIndex(
                      where: { $0.groupId == currentId }
                  )
            else { return nil }
            let nextIdx = filteredGroups.index(after: idx)
            if nextIdx < filteredGroups.endIndex {
                return filteredGroups[nextIdx].groupId
            }
            // At end — try previous
            if idx > filteredGroups.startIndex {
                return filteredGroups[
                    filteredGroups.index(before: idx)
                ].groupId
            }
            return nil
        case .nextUndecided:
            guard let currentId = selectedGroupId,
                  let idx = filteredGroups.firstIndex(
                      where: { $0.groupId == currentId }
                  )
            else { return nil }
            // Search forward, skipping current
            let startIdx = filteredGroups.index(after: idx)
            for i in startIdx..<filteredGroups.endIndex {
                let gid = filteredGroups[i].groupId
                let state = decisionByGroupId[gid]?.state
                    ?? .undecided
                if state == .undecided {
                    return gid
                }
            }
            // Wrap from beginning
            for i in filteredGroups.startIndex..<idx {
                let gid = filteredGroups[i].groupId
                let state = decisionByGroupId[gid]?.state
                    ?? .undecided
                if state == .undecided {
                    return gid
                }
            }
            return nil
        }
    }
}
