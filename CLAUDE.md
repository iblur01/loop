
## Project

**Loop**

Loop is the rebrand and refonte of the "my-whoop" / OpenWhoop proof-of-concept: a local-first iOS client for a personal WHOOP 4.0 band, used by a single user (the developer) as a daily sport/health decision assistant. It positions itself as "compatible with WHOOP 4.0" without WHOOP branding, keeps familiar physiological vocabulary (Recovery, Strain, Sleep, HRV, RHR...), and aims to feel like a real product, not a research POC.

**Core Value:** A trustworthy, personalized calculation engine — sleep sessions correctly segmented, recovery/strain/baselines calibrated to the individual user over time from raw band data — that the UI and future coach features can rely on for daily decisions.

### Constraints

- **Personal scale**: Single user, local SQLite (not built for >1M rows without indexing work) — acceptable for personal use, documented in CONCERNS.md
- **Hybrid architecture**: New calc engine must work fully offline on iOS (local-first trust principle); server pipeline (`server/ingest/`, Python) stays as optional sync/backup path, not a hard dependency
- **No ground truth**: Calibration must be designed to work without WHOOP comparative data; document confidence/uncertainty rather than claiming WHOOP-equivalent accuracy
- **Existing tech stack**: Swift/SwiftUI + GRDB/SQLite on iOS, Python/FastAPI-style analysis pipeline on server (per STACK.md) — rewrite within these, no new platform

## Technology Stack

## Languages

- Swift 5.9+ - iOS app (`Loop/`), widget extension (`LoopWidgets/`), and SPM packages (`Packages/WhoopProtocol/`, `Packages/WhoopStore/`)
- JSON - Protocol schema definition (`protocol/whoop_protocol.json`)

## Runtime

- iOS 17+ (per `loop/project.yml` deploymentTarget; SPM packages target iOS 16+/macOS 13+)
- Swift Package Manager (SPM) - primary for the app and local packages (`Packages/`)

## Frameworks

- SwiftUI - UI framework for the app (`Loop/Features/`)
- Combine - Reactive framework (integrated with SwiftUI)
- CoreBluetooth - Bluetooth LE connectivity (`Loop/Core/BLE/`)
- WidgetKit - Lock screen widgets (`LoopWidgets/`)
- UserNotifications - Push notifications and local alarms (`Loop/Core/LiveActivity/`)
- Charts - Data visualization (imported in multiple view files)
- GRDB.swift 6.0.0+ - SQLite wrapper and ORM (`Packages/WhoopStore/Sources/WhoopStore/`, depends on GRDB via SPM)
- SQLite 3 - Database engine (via GRDB)
- XCTest - Native Swift testing framework (`LoopTests/`)
- XcodeGen - project file generation from `loop/project.yml`

## Key Dependencies

- GRDB.swift 6.0.0+ - Required for all local persistence; provides type-safe, async-first SQLite ORM (`Packages/WhoopStore/Package.swift`, `Packages/WhoopStore/Sources/WhoopStore/Database.swift`)
- WhoopProtocol - Internal package defining Bluetooth protocol decoding schema (`Packages/WhoopProtocol/`, schema synced from `protocol/whoop_protocol.json`)
- WhoopStore - Internal package providing persistent store abstraction (`Packages/WhoopStore/`, depends on GRDB and WhoopProtocol)

## Configuration

- App reads optional server sync configuration from `Info.plist` via `Bundle.main.object(forInfoDictionaryKey:)`
- Server credentials (API key, base URL, device ID) injected from gitignored `Secrets.xcconfig` file
- `project.yml` - XcodeGen configuration (generates `Loop.xcodeproj`)
- `Packages/WhoopProtocol/Package.swift` - Swift package manifest with iOS 16+ / macOS 13+ targets
- `Packages/WhoopStore/Package.swift` - Swift package manifest depending on GRDB 6.0.0+

## Platform Requirements

- Xcode 15+ (for Swift 5.9 support)
- iOS 17+ device or simulator (Bluetooth only works on real device)
- macOS 13+ (for shared package compilation)


## Conventions

## Naming Patterns

- `PascalCase.swift` for all Swift files (e.g., `MetricsRepository.swift`, `BLEManager.swift`, `TodayView.swift`)
- Suffixes indicate type: `*Repository` (data layer facades), `*Manager` (stateful coordinators), `*View` (SwiftUI views), `*ViewModel` (state management), `*Tests` (test suites)
- Files are grouped by feature/domain: `Tabs/`, `BLE/`, `Collect/`, `Settings/`, `Design/`, `Metrics/`
- `PascalCase` for all type names (e.g., `MetricsRepository`, `WhoopCommand`, `ClockRef`, `LiveState`)
- Protocols: `PascalCase` with semantic name (e.g., `StoreWriting`, `ObservableObject`)
- Enums: `PascalCase` with raw values indicated in documentation (e.g., `WhoopCommand: UInt8` with case raw values matching wire protocol)
- `lowerCamelCase` for all functions and instance methods (e.g., `ensureOpen()`, `ingest(_:)`, `prune()`, `sleepSessions(from:to:limit:)`)
- Leading verb pattern for action methods: `load()`, `refresh()`, `bootstrap()`, `flush()`, `requestSync()`
- Computed properties and getters use same `lowerCamelCase` as methods (e.g., `bufferedCount`, `clockRef`)
- Parameter names match argument labels: `fromDay`, `toDay`, `maxPoints`, `markSynced`
- Instance properties: `lowerCamelCase` (e.g., `store`, `serverSync`, `deviceId`, `lastError`)
- Private instance properties: `lowerCamelCase` with underscore prefix for "backing" fields: `_alreadyOpen`, `_openTask`
- Local variables: `lowerCamelCase` (e.g., `now`, `cal`, `fmt`, `path`)
- Type aliases and associated types: `PascalCase` (e.g., `ParsedValue`)
- `static let` for type-level constants in `PascalCase` (e.g., `WhoopCommand.commandType`)
- `enum` scoping for related constants (e.g., `WH.Color.background`, `WH.Spacing.md`, `BLEManager.backfillIntervalSeconds`)
- Actor-isolated properties/methods: Marked `@MainActor` (e.g., `MetricsRepository: ObservableObject`, `BLEManager: NSObject`)
- Test helper functions: `make*()`, `seed*()` (e.g., `makeRepo()`, `seedDaily()`, `seedSleep()`)
- Hex conversion: `hex(_:)` (string-to-bytes parser in test suites)

## Code Style

- No SwiftLint or SwiftFormat detected; formatting is manual/implicit
- 4-space indentation (Swift convention)
- Brace style: opening brace on same line for functions and types (1TBS)
- Line length: appears unconstrained; some lines >100 chars (no visible limit)
- Trailing commas in multi-line arrays/tuples: omitted
- No .swiftlint configuration file detected
- No automated linting enforced; conventions are manual
- `public` for package-exported types (e.g., `WhoopCommand`, `Streams` in `WhoopProtocol`)
- `internal` (implicit) for app-internal types
- `private` for file-scoped helpers and implementation details
- `final` on classes to prevent unintended subclassing (e.g., `final class MetricsRepository`, `final class BLEManager`, `final class Collector`)

## Import Organization

- No path aliases detected; imports use full module names
- Relative paths in imports follow module organization (e.g., `import WhoopStore` for the `WhoopStore` package)

## Error Handling

- **Try-catch suppression:** Most operations use `try?` to suppress errors and provide a fallback (e.g., `try? StorePaths.defaultDatabasePath()`, `try? await WhoopStore(path: path)`)
- **Guard with early-return:** Errors are usually converted to guard failures with nil coalescing:
- **Result-less throws:** Methods marked `async throws` return `Void` or a success value; callers use `try?` to suppress
- **Publisher fallback:** Network operations return empty arrays on error rather than propagating exceptions:

## Logging

- No visible logging instrumentation in reviewed source
- Comments replace logs for debugging notes (see "Comments" section)
- Error messages surfaced to UI via `@Published private(set) var lastError: String?` in `MetricsRepository`

## Comments

- High-level class documentation: `// MARK: -` comments explain class purpose and invariants (e.g., `MetricsRepository` has detailed comments about lazy-open design, clock correlation)
- Invariants and design decisions: Comments explain WHY before the code that implements it
- Algorithm details: Comments document packet framing, CRC computation, timezone handling
- Edge cases: Comments flag pre-clock buffering behavior, strap-stuck detection gates, reconnect behavior
- Do NOT comment obvious code (e.g., `let x = 5  // set x to 5` is forbidden)
- Triple-slash documentation (`///`) used for public functions and important entry points
- Explains contract, parameters, return semantics, and side effects
- Example:

## MARK Sections

- Top-level sections use `// MARK: -` with a single topic name
- Nested sections use `// MARK: -` followed by a descriptive phrase
- Private helpers grouped at the bottom with `// MARK: - Helpers`
- Test files use `// MARK: -` to group test clusters by behavior

## Function Design

- Explicit parameter labels matching argument names (e.g., `daily(fromDay:toDay:)` not `daily(from:to:)`)
- Default parameters for optional, sensible values (e.g., `deviceId: String = "my-whoop"`)
- Tuple returns for multiple related outputs:
- Async methods marked `async` or `async throws` (when they call async dependencies)
- Return nil for "not found" conditions; empty collections for "no results"
- Fire-and-forget methods return `Void` or use `@discardableResult` if the return is unused:
- `@MainActor` on UI-related classes that must be accessed from the main thread (e.g., `MetricsRepository`, `BLEManager`, `Collector`)
- Async methods properly use `await` for coordinating with other async functions
- Task creation via `Task { @MainActor in ... }` to ensure main-thread execution

## Module Design

- `WhoopProtocol` and `WhoopStore` packages use `public` for framework-facing types (e.g., `public enum WhoopCommand`, `public struct Streams`)
- App-internal types are `internal` (implicit); not exported via package products
- No barrel files (`__init__.swift`, `index.swift`) detected
- Imports are explicit and per-module (e.g., `import WhoopStore` imports all public types from the package)
- Files organized by feature domain: `Tabs/` (UI views), `BLE/` (Bluetooth), `Collect/` (data collection), `Settings/` (configuration), `Metrics/` (data access layer)
- Cross-domain dependencies use explicit imports (e.g., `BLEManager` imports `WhoopStore`, `WhoopProtocol`)

## SwiftUI Patterns

- Primary views (tabs) are `struct View` with computed properties for sub-sections:
- Computed body properties marked `private` to encapsulate layout fragments
- `@State` for local mutable state within a view
- `@StateObject` for objects that manage per-view state
- `@EnvironmentObject` for app-wide singletons injected via `.environmentObject()` (e.g., `MetricsRepository`, `LiveViewModel`)
- `@Published` properties in `ObservableObject` classes for reactive updates
- `MetricsRepository`: injected as `@EnvironmentObject` in tab views to provide cached metrics and network refresh
- `LiveViewModel`: live Bluetooth status and controls
- `LanguageManager`: localization strings (L10n)

## Async/Concurrency

- All async database/network operations wrapped in `async` functions
- View tasks use `.task { await ... }` modifier to load data on appear
- Refresh actions use `.refreshable { await ... }` for pull-to-refresh
- Explicit `await` at call sites; no implicit async context leakage
- `MetricsRepository` uses lazy-open pattern: `init()` creates object synchronously, `ensureOpen()` async method initializes dependencies (store, sync) on first use
- Prevents blocking UI while waiting for WhoopStore to open


## Architecture

See `.planning/codebase/ARCHITECTURE.md` and `.planning/codebase/STRUCTURE.md` for the
up-to-date component map, data flow, and directory layout of `loop/Loop` (regenerated
2026-06-15 from the actual rewrite — LoopDataRepository, LocalDataStore, BLEConnectionManager,
SyncCoordinator, LoopServerSync, etc. — superseding the legacy ios/OpenWhoop naming below in
the Conventions examples).


## Project Skills

No project skills found. Add skills to any of: `.Codex/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.

