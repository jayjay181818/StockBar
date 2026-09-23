# Stockbar working instructions

macOS AppKit/SwiftUI portfolio app with a Python market-data bridge. Personal working agreements belong in global guidance; this file adds project constraints.

## Working efficiently
- Read applicable directory `AGENTS.md` files before editing there. Read linked reference docs only for relevant tasks; do not load the whole documentation tree.
- Use scoped searches and bounded output. Reuse instruction reads and valid check results unless inputs change. Keep complete logs on disk and report useful failures plus the log path.
- Follow existing component isolation and design. Avoid generic refactors, dependency upgrades, or added abstractions unrelated to the request.
- Start with affected checks; broaden for shared contracts and required CI gates. Do not equate process startup with functional acceptance.

## Invariants
- Keep UI state on `@MainActor`, heavy work off the main thread, and Core Data writes on background contexts.
- Use `StockbarRuntimeStorage` for app defaults and writable paths. Acceptance requires a valid temporary root, run ID and disabled live providers; never fall back to production storage on invalid configuration.
- Gate live network/subprocess paths through `StockbarProviderAccessPolicy`. Use isolated stores and mocks in tests; the storage wrapper alone does not enable isolation.
- Preserve local/manual holdings when broker or Folync sources are active. Broker/Folync financial fields stay authoritative and read-only. Never splice supplemental Folync and legacy points into one series. Keep broker/Folync credentials in Keychain and secrets out of logs.
- Normalize pence to GBP once using reported currency and existing provider rules. Never divide already-normalized GBP just because a symbol ends in `.L`.
- The app's Python bridge uses JSON stdout and stderr logs; retain structured errors and symbol validation. Keep the existing unsandboxed app configuration for subprocess compatibility.

## Entry points
- Lifecycle: `Stockbar/main.swift` → `AppDelegate.swift` → `StockMenuBarController.swift`. Preserve acceptance preflight before normal startup.
- Window/settings: `Stockbar/StockbarMainWindowController.swift`, `Stockbar/Views/StockbarMainView.swift`. Settings stay embedded in the main window.
- State: `Stockbar/Data/DataModel.swift`; fetches: `Stockbar/Data/Networking/`; persistence: `Stockbar/Data/CoreData/`.
- Architecture and source ownership: [Docs/Architecture.md](Docs/Architecture.md).

## Checks and tools
Run from the repository root:
- `bash script/develop.sh build` — build only.
- `bash script/develop.sh test StockbarTests/ClassName[/methodName]` — focused XCTest; omit the filter for the full suite.
- `bash script/develop.sh python-tests` — offline Python checks.
- `bash script/develop.sh checks` — lint, entitlements, Sendable, code and documentation validators.
- `bash script/develop.sh acceptance /path/to/manifest.json` — isolated acceptance harness; see [workflow details](Docs/Development.md).
- `bash script/build_and_run.sh` — explicit normal-app launch; never a substitute for build-only checks.

[CI](.github/workflows/ci.yml) and [.swiftlint.yml](.swiftlint.yml) define gates. The app folder is Xcode-synced; new Swift test files require explicit test-target membership. See [recovery procedures](Scripts/README.md) before backup/restore work.
