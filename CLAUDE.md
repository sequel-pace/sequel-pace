# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sequel PAce is a PostgreSQL-focused macOS database client, forked from Sequel Ace (which itself forked Sequel Pro). The MySQL backend has been replaced with a PostgreSQL driver (libpq) while preserving the native macOS Cocoa interface.

## Build & Run

Prerequisites: Xcode 15+, `brew install postgresql@17` (or @15/@16).

```bash
# Build (debug) and launch
./Scripts/build.sh debug

# Build release
./Scripts/build.sh release

# Run unit tests
./Scripts/build.sh tests

# Clean
./Scripts/build.sh clean

# Archive for distribution
./Scripts/build.sh archive
```

The build script auto-detects PostgreSQL versions (17→14) and architecture (arm64/x86_64). It injects the correct `HEADER_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS`, and `-lpq` linker flags.

Xcode schemes: `Sequel PAce Debug` (development), `Sequel PAce Release` (production), `Unit Tests`.

## Linting

SwiftLint is configured via `.swiftlint.yml`. Key rules:
- `force_unwrapping` and `implicitly_unwrapped_optional` are opt-in (errors)
- Custom rule: use `.isNotEmpty` instead of `!isEmpty`
- Custom rule: implement `init(coder:)` properly instead of using `fatalError`
- Function body length limit: 120 lines, cyclomatic complexity limit: 20

## CI

GitHub Actions (`.github/workflows/ci_pr_tests.yml`) runs `./Scripts/build.sh tests` on every PR using macOS 15 / Xcode 16.2.

## Architecture

### Language Mix
~345 Objective-C files (.h/.m) form the bulk of the codebase, inherited from Sequel Pro/Ace. ~42 Swift files provide newer additions. Swift↔ObjC bridging is via `Source/Sequel-PAce-Bridging-Header.h`.

### Key Layers

**PostgreSQL Connection Layer** (`Frameworks/SPPostgresFramework/Source/`):
Custom Objective-C wrapper around libpq. `SPPostgresConnection` manages connections, queries, encoding, and reconnection. Result types include `SPPostgresResult`, `SPPostgresStreamingResult`, and `SPPostgresStreamingResultStore` for memory-efficient large result set handling. `SPPostgresGeometryData` handles PostGIS geometry types.

**Query Builder** (`Frameworks/QueryKit/Source/`):
`QKQuery` — programmatic SQL query construction (SELECT, INSERT, UPDATE, DELETE) with parameters, ordering, and PostgreSQL-specific quoting. Uses `tickQuotedString` for identifier quoting (not backticks).

**Main Application** (`Source/`):
- `Controllers/MainViewControllers/SPDatabaseDocument` — central document controller, one per database connection tab
- `Controllers/MainViewControllers/SPCustomQuery` — custom SQL query editor
- `Controllers/MainViewControllers/TableContent/SPTableContent` — table data browsing/editing
- `Controllers/MainViewControllers/TableStructure/SPTableStructure` — table column management
- `Controllers/MainViewControllers/ConnectionView/SPConnectionController` — connection setup (host, SSH tunnel)
- `Controllers/SubviewControllers/SPTablesList` — database object sidebar (tables, views, functions, sequences)
- `Controllers/SubviewControllers/SPFunctionEditorController` — PostgreSQL function editor
- `Controllers/SubviewControllers/SPSequenceEditorController` — PostgreSQL sequence editor
- `Controllers/SPAppController` — application delegate (split across .h/.m/.swift)
- `Controllers/Window/SPWindowController` + `TabManager` — multi-tab window management

**UI** (`Source/Interfaces/`):
XIB-based Interface Builder files. Main window layout is in `MainWindow.xib` and `DBView.xib`. Connection dialog in `ConnectionView.xib`.

**Parsing** (`Source/Other/Parsing/`):
`SPSQLParser` — SQL tokenization/parsing. `SPCSVParser` — CSV import. `SPJSONFormatter` — JSON display. `SPSyntaxParser` — query editor syntax highlighting.

**Data Export/Import** (`Source/Controllers/DataExport/`, `Source/Controllers/DataImport/`):
CSV, SQL, XML export with pluggable exporter architecture.

### PostgreSQL-Specific Conventions
- SQL identifiers use double-quote quoting (`"identifier"`) via `tickQuotedString`, not MySQL-style backticks
- Schema-aware: objects are referenced as `schema.object` where needed
- Connection uses libpq directly (`PGconn`), not an ORM

### Localization
Managed via Crowdin (`crowdin.yml`). String files in `Resources/Localization/`. Base language is English (`en.lproj`).

## Scripts

- `Scripts/build.sh` — CLI build/test/run/archive
- `Scripts/setup_libpq.sh` — copies libpq into `Frameworks/PostgreSQL.framework` with correct install names
- `Scripts/embed_libpq.sh` — embeds libpq for distribution
- `Scripts/generate-changelog.sh` — generates CHANGELOG.md from git history

## Release Process

Fastlane lanes handle versioning and release preparation:
- `fastlane prepare_release` — create release branch, bump build number, generate changelog, open PR
- `fastlane prepare_release_bump_patch_version` — same with patch version bump
- Version numbers are incremented across three xcodeproj files: main project, QueryKit, and SPPostgres
