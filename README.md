# Deduper

Deduper is a macOS tool for finding and safely cleaning up duplicate media files (photos, screenshots, downloads, exported albums, etc.). It supports a CLI workflow for scanning, review, and merge, plus a native macOS app for visual triage.

What's in this repo:

- `deduper` (CLI): scan, review, merge, undo
- `DeduperApp` (macOS app): triage and merge UI
- `DeduperKit` (library): detection and merge safety primitives

## Why Deduper

Duplicate cleanup tends to fail in two places:

1. Detection is uncertain (near-duplicates, resized exports, edited variants).
2. Cleanup is dangerous (accidentally deleting the real original, losing sidecars, or making changes you cannot reverse).

Deduper treats cleanup as a reversible, transaction-logged operation. By default it prefers moving over deleting, and it keeps companion files together.

## Core Workflow

1. Scan one or more folders to produce a session.
2. Review duplicate groups and the suggested keeper.
3. Preview the merge (dry-run default).
4. Apply the merge to move non-keepers into quarantine or Trash.
5. Undo using a transaction ID if you need to revert.

## What It Does

Deduper scans one or more directories, groups likely duplicates, and suggests a keeper for each group.

Detection includes:

- Exact matches via SHA-256
- Near-duplicate image matching via perceptual hashes
- Optional video heuristics (when enabled)

## Concepts (Terminology)

- Session: The output of a scan (a saved set of results you can review later).
- Group: A set of files Deduper believes represent the same image/video (exact or near-duplicate).
- Keeper: The file Deduper recommends retaining as the canonical copy.
- Companions: Files that should move together (for example sidecars or Live Photo assets) so you do not break an asset pair.

## Safety Model

Deduper aims to be reviewable and reversible:

- `merge` is dry-run by default (no file moves until you pass `--apply`).
- All merge operations are transaction-logged.
- `deduper undo <transaction-id>` restores moved files.
- Companion files are moved together.
- `--use-trash` is available; otherwise Deduper uses quarantine mode.

Practical implication: even if a keeper suggestion is wrong, you can recover quickly via undo.

## Requirements

- macOS 14+
- Swift 6 / Xcode with Swift 6 support

## Quick Start (CLI)

```bash
# Build
swift build

# Scan one or more folders (creates a new session)
swift run deduper scan ~/Pictures ~/Desktop

# List sessions
swift run deduper history

# Show groups for a session
swift run deduper show <session-id>

# Preview merge (dry-run default)
swift run deduper merge <session-id>

# Execute merge (moves non-keepers)
swift run deduper merge <session-id> --apply

# Undo merge
swift run deduper undo --list
swift run deduper undo <transaction-id>
```

Tip: use `--help` at any command level to see flags and defaults.

```bash
swift run deduper --help
swift run deduper scan --help
swift run deduper merge --help
```

## Run The App

```bash
./Scripts/build-app.sh
open build/Deduper.app

# Optional release build
./Scripts/build-app.sh --release
```

## CLI Commands (Reference)

- `deduper scan <paths...>`
  Creates a new scan session from one or more paths.
- `deduper history`
  Lists prior sessions.
- `deduper show <session-id>`
  Displays duplicate groups for a session.
- `deduper merge <session-id>`
  Previews or applies a merge for a session (dry-run unless `--apply`).
- `deduper undo [transaction-id]`
  Lists transactions or reverts a specific transaction.
- `deduper purge <transaction-id>`
  Permanently removes quarantined files for a transaction.
- `deduper delete-session <session-id>`
  Removes stored session data (does not modify your original source files).

For detailed flags:

```bash
swift run deduper <command> --help
```

## Data Paths

Deduper stores scan results and transactions here:

- Sessions/manifests: `~/Library/Application Support/Deduper/sessions/`
- Transactions: `~/Library/Application Support/Deduper/transactions/`

Default merge mode uses a quarantine folder near source files:

- Quarantine: `.deduper_quarantine`

## Project Layout

- `Sources/DeduperKit` core scanning, detection, and merge safety logic
- `Sources/DeduperCLI` command-line interface
- `Sources/DeduperUI` SwiftUI views and view models
- `Sources/DeduperApp` app entry point
- `Tests` unit and integration tests

## Development

Run tests:

```bash
swift test
```

Common dev loop:

```bash
swift build
swift run deduper scan <paths...>
swift run deduper show <session-id>
swift run deduper merge <session-id>        # dry-run
swift run deduper merge <session-id> --apply
```

## Troubleshooting / Notes

- Permissions: scanning protected folders may require granting Terminal or the app Full Disk Access in macOS privacy settings.
- Large folders: first scan is typically I/O bound; review sessions to iterate without rescanning immediately.
- Near-duplicates: perceptual matching can produce false positives for highly similar frames or repeated graphics. Review before applying merges.

## License

MIT (see `LICENSE`).
