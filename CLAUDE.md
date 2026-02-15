# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                              # Build all targets
swift run deduper scan ~/Pictures        # Run CLI scan
swift run deduper merge <session-id>     # Execute merge plan
swift run deduper history                # List past sessions
swift test                               # Run all tests
swift test --filter DeduperKitTests      # Kit tests only
swift test --filter <TestClassName>      # Single test class
xed .                                    # Open in Xcode (recommended for UI work)
```

Dependency: `swift-argument-parser` (CLI only). No other external dependencies.

**SwiftLint**: `brew install swiftlint` then `swiftlint` from project root. Key limits: line length 120/150, function body 50/100 lines, cyclomatic complexity 10/15.

## Architecture

**Swift 6 / macOS 14+ / SwiftUI / SwiftData / Swift Package Manager**

Four targets: `DeduperKit` (library: algorithms + services), `DeduperCLI` (executable: ArgumentParser CLI), `DeduperUI` (library: SwiftUI components), `DeduperApp` (executable: macOS app).

### DeduperKit (core library)

Algorithm files (ported from original codebase):
- `CoreTypes.swift` -- `MediaType`, `ScannedFile`, `ScanOptions`, `ExcludeRule`, `MediaMetadata`
- `DetectionTypes.swift` -- `DetectOptions`, `ConfidenceSignal`, `DuplicateGroupResult`, `DetectionAsset`
- `ImageHashingService.swift` -- dHash, pHash via Accelerate 2D DCT
- `VideoFingerprinter.swift` -- Frame extraction + comparison via AVFoundation
- `HashIndexService.swift` -- BK-tree (insert/search), `HashMatch`

Services:
- `ScanService` -- Async directory scanner, yields `ScanEvent` stream
- `MetadataService` -- EXIF/video/audio metadata extraction (stateless)
- `DetectionService` -- Orchestrates scan -> hash -> index -> compare -> group pipeline
- `MergeService` -- Quarantine-based file removal with WAL transaction logging + undo
- `CompanionResolver` -- Sidecar/Live Photo pair discovery (.aae, .xmp, .thm, .lrv)
- `ScanOrchestrator` -- Shared CLI/UI scan pipeline (scan -> detect -> artifact -> manifest)
- `Persistence.swift` -- SwiftData models (`ScanSession`, `HashedFile`), `SessionArtifact` (NDJSON.gz), `SessionManifest` (JSON), `HashCacheService` (actor)

### DeduperCLI (commands)

- `scan <path>` -- Scan + detect duplicates, write session artifact + manifest
- `merge <session-id>` -- Load session, preview/execute merge plan with quarantine
- `show <session-id>` -- Display duplicate groups for a session
- `undo <session-id>` -- Restore quarantined files from transaction log
- `history` -- List past scan sessions
- `purge <session-id>` -- Permanently delete quarantined files
- `delete-session <session-id>` -- Remove session from SwiftData

### Concurrency model

Swift 6 strict concurrency. `Sendable` value types for services. Actor isolation for `HashIndexService` and `VideoSignatureCache`. TaskGroup with bounded concurrency for parallel hashing.

### Safety invariants

- Quarantine by default (dedicated directory with deterministic undo), OS Trash as fallback
- Write-ahead log (WAL) + NDJSON journal for all file operations with rollback
- Protected path detection (system folders, ~/Library, /Applications, /usr)
- No modification of files outside user-selected directories
- Companion-aware: sidecars and Live Photo pairs move/restore together
- NDJSON.gz session artifacts are canonical source of truth; SwiftData caches for UI speed

## Conventions

- Structs for services (value types, `Sendable`), actors for shared mutable state
- Protocol-oriented design, structs for data models
- Explicit `Sendable` conformance throughout
- OSLog with categories for structured logging
- Custom error types per service (ScanError, MergeError)
- Keep each commit focused on one intent, never use `--no-verify`
- Prefer small, bounded diffs; edit existing modules over creating new ones
- Ask before: crossing package boundaries, deleting files/renaming public symbols, adding dependencies, or touching security/persistence

## Testing

Uses Swift Testing framework (`@Test` macro, not XCTest). Fixtures in `Tests/DeduperKitTests/Fixtures/`. Test targets: `DeduperKitTests`, `DeduperUITests`.

SwiftData uses in-memory containers for tests via `PersistenceFactory.makeContainer(inMemory: true)` (Kit) and `UIPersistenceFactory.makeContainer(inMemory: true)` (UI).

## Architecture Decisions

**AD-001: SwiftData is the interactive substrate, not SessionArtifact.**
`SessionArtifact.readGroups` decompresses the entire gzip, parses all NDJSON lines. This is acceptable for CLI batch operations but not for interactive UI. All UI-side group/member access goes through SwiftData. The artifact is read exactly once during materialization.

**AD-002: App sandbox deferred.**
CLI and app share `~/Library/Application Support/Deduper/` via absolute paths. Sandbox would break this. Stay non-sandboxed (common for pro tools). Revisit when Slice 5 (scan from UI) forces the distribution decision.

**AD-003: ReviewDecision is an exportable artifact independent of SwiftData.**
Even though stored in SwiftData, decisions must export/import as JSON and include `sessionId + artifactIdentity`. This prevents "local database is the only source of human work" and supports auditability. Schema prepared in 1.5, wired in Slice 2.

**AD-004: Quarantine over Trash.**
Dedicated quarantine directory (`~/Library/Application Support/Deduper/quarantine/`) with transaction log for deterministic undo. OS Trash is user-controlled and non-deterministic (emptied at any time, no structured restore). Quarantine preserves relative paths for collision-free restoration.

**AD-005: MatchKind as enum, not confidence threshold.**
`sha256Exact`, `perceptual`, `videoHeuristic` are explicit discriminators. Never compare `confidence >= 1.0` to determine match type. This enables UI batching (exact matches auto-approvable) and correct confidence interpretation.

**AD-006: Explicit schema versions on artifacts.**
Every `StoredDuplicateGroup` has `schemaVersion: Int`. No inferring meaning from nil fields. V2 adds `matchKind`, `membersV2` with per-member signals/penalties/rationale.
