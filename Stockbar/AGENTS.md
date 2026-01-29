# STOCKBAR ROOT AGENTS KNOWLEDGE BASE

**Architecture:** Hybrid AppKit/SwiftUI | **Entry Point:** main.swift | **Core:** Swift 6 Concurrency
**Domain:** Application lifecycle, menu bar orchestration, and top-level UI navigation.

## OVERVIEW
Stockbar is a native macOS menu bar application that uses a modern hybrid architecture. It leverages AppKit for low-level menu bar integration and window management, while utilizing SwiftUI for complex settings interfaces and interactive charts.

- **main.swift**: The explicit entry point. Initializes the `AppDelegate` and launches the AppKit lifecycle.
- **AppDelegate.swift**: Coordinates application launch, first-run migrations, background service scheduling, and dependency verification (Python/yfinance).
- **StockMenuBarController.swift**: The central UI coordinator. Manages individual stock status items via `StockStatusBar` and handles the binding between `DataModel` and the system menu bar.

## STRUCTURE
- **AppDelegate.swift**: Application-level event handling and service initialization.
- **StockMenuBarController.swift**: Orchestrates the status bar items and preferences window lifecycle.
- **StockStatusBar.swift**: Low-level AppKit wrapper for `NSStatusItem` management.
- **PreferenceView.swift**: The primary SwiftUI interface for portfolio management and analytics.
- **PreferenceViewController.swift**: An `NSViewController` subclass hosting `PreferenceView` via `NSHostingController`.

## WHERE TO LOOK
- **App Startup**: `main.swift` and `AppDelegate.applicationDidFinishLaunching`.
- **Menu Bar Updates**: `StockMenuBarController.setupDataBinding` and `syncSymbolItemsFromUserData`.
- **Preferences Launch**: `StockMenuBarController.showPreferences` and `PreferenceWindowController`.
- **UI State**: `PreferenceView.swift` for the tabbed settings interface.

## CONVENTIONS
- **AppKit/SwiftUI Mix**: Use AppKit for system integration (menus, windows) and SwiftUI for content. `PreferenceViewController` serves as the primary bridge.
- **Main Actor Isolation**: All UI orchestration and status bar updates MUST be performed on the `@MainActor`.
- **Data Binding**: Reactive updates are driven by Combine publishers in `DataModel`, which `StockMenuBarController` subscribes to for menu bar synchronization.
- **Window Management**: Preferences are handled as an `NSPopover` or `NSWindow` depending on user interaction; see `PreferenceWindowController` for details.

## SUB-MODULE AGENTS
For detailed knowledge of specific sub-modules, refer to:
- [Data/AGENTS.md](./Data/AGENTS.md) - State & Networking
- [Data/CoreData/AGENTS.md](./Data/CoreData/AGENTS.md) - Persistence
- [Data/Networking/AGENTS.md](./Data/Networking/AGENTS.md) - Python bridge
- [Services/AGENTS.md](./Services/AGENTS.md) - Business logic
- [Views/AGENTS.md](./Views/AGENTS.md) - UI components
- [Charts/AGENTS.md](./Charts/AGENTS.md) - Visualization
- [Analytics/AGENTS.md](./Analytics/AGENTS.md) - Risk & metrics
- [Utilities/AGENTS.md](./Utilities/AGENTS.md) - Logging & helpers
- [Resources/AGENTS.md](./Resources/AGENTS.md) - Python backend
