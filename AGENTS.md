# STOCKBAR PROJECT KNOWLEDGE BASE

**Generated:** 2026-01-26 | **Branch:** n/a | **Commit:** n/a

## OVERVIEW
macOS menu bar stock monitor. Swift 6 AppKit/SwiftUI frontend with Python (yfinance) subprocess backend.

## STRUCTURE
```
Stockbar/
├── Stockbar/                # App sources
│   ├── Data/                # State, persistence, networking
│   ├── Services/            # Business logic, coordinators
│   ├── Utilities/           # Logging, config, perf
│   ├── Views/               # SwiftUI analytics
│   ├── Charts/              # Swift Charts UI
│   ├── Analytics/           # Pure math services
│   ├── Models/              # Data structs and settings
│   └── Resources/           # Python scripts
├── StockbarTests/           # XCTest suite
├── Scripts/                 # Backup/restore tooling
├── Changelogs/              # Release notes
└── .github/workflows/       # CI + static analysis
```

## WHERE TO LOOK
| Task | Location | Notes |
| --- | --- | --- |
| App bootstrap | `Stockbar/main.swift` | Manual entry point (no @main) |
| Lifecycle | `Stockbar/AppDelegate.swift` | Dependency checks, migrations |
| Menu bar UI | `Stockbar/StockMenuBarController.swift` | Status items, menu wiring |
| Portfolio state | `Stockbar/Data/DataModel.swift` | @MainActor state hub |
| Python bridge | `Stockbar/Data/Networking/NetworkService.swift` | Process + SafeDataBuffer |
| Core Data | `Stockbar/Data/CoreData/` | Trade/historical persistence |
| Analytics UI | `Stockbar/Views/` | Risk + portfolio dashboards |

## CODE MAP
| Symbol | Type | Location | Role |
| --- | --- | --- | --- |
| `AppDelegate` | class | `Stockbar/AppDelegate.swift` | App lifecycle + dependencies |
| `StockMenuBarController` | class | `Stockbar/StockMenuBarController.swift` | Menu bar coordinator |
| `DataModel` | class | `Stockbar/Data/DataModel.swift` | Central state + services |
| `PythonNetworkService` | class | `Stockbar/Data/Networking/NetworkService.swift` | Subprocess fetch |
| `CacheCoordinator` | actor | `Stockbar/Services/CacheCoordinator.swift` | Cache TTL + breaker |

## CONVENTIONS (DEVIATIONS)
- Manual `main.swift` entry (no `@main`).
- Menu bar app uses `LSUIElement = false` (Dock-visible by default).
- Python subprocesses must emit JSON to stdout; logs to stderr only.
- `.L` symbols normalized from GBX to GBP early in the pipeline.
- UI-facing state stays on `@MainActor` (Swift 6 strict isolation).
- SwiftLint enabled with 120 line limit; `force_unwrapping` is opt-in.

## ANTI-PATTERNS (PROJECT)
- Network or heavy processing on main thread.
- Direct Core Data writes on viewContext (use background contexts).
- Stdout pollution from Python scripts.
- Business logic embedded in SwiftUI view bodies.

## UNIQUE STYLES
- Cache + circuit breaker policy for fetch retries (Services/CacheCoordinator).
- JSON error protocol from Python (`error: true`, `error_code`).
- 5-minute snapshot cadence for historical data.

## COMMANDS
```bash
# Lint
swiftlint

# Build
xcodebuild build -project Stockbar.xcodeproj -scheme Stockbar -destination 'platform=macOS'

# Tests
xcodebuild test -project Stockbar.xcodeproj -scheme Stockbar -destination 'platform=macOS'

# Python smoke test
python3 Stockbar/Resources/get_stock_data.py AAPL
```

## NOTES
- Python dependency check runs on first launch; sandboxing must remain disabled.
- API keys load from `~/.stockbar_config.json`.
- `Scripts/setup_and_run_tests.sh` hardcodes a local path; update when running elsewhere.
