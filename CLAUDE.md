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
- `MergeService` -- Move-to-trash with JSON transaction logging + undo
- `Persistence.swift` -- SwiftData models (`ScanSession`, `HashedFile`) + container factory

### Concurrency model

Swift 6 strict concurrency. `Sendable` value types for services. Actor isolation for `HashIndexService` and `VideoSignatureCache`. TaskGroup with bounded concurrency for parallel hashing.

### Safety invariants

- Move-to-trash by default, never permanent deletion
- Transaction logging for all file operations with rollback
- Protected path detection (system folders)
- No modification of files outside user-selected directories

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

Uses Swift Testing framework (`@Test` macro, not XCTest). Fixtures in `Tests/DeduperKitTests/Fixtures/`. Test targets: `DeduperKitTests`.

SwiftData uses in-memory containers for tests via `PersistenceFactory.makeContainer(inMemory: true)`.
