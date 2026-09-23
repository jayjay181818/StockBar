# App sources

- Keep the manual `main.swift` entry; acceptance preflight/bootstrap must run before normal AppKit startup.
- `StockMenuBarController` connects `DataModel`, status items and `StockbarMainWindowController`. Use `Views/StockbarMainView.swift` for window content and embedded Settings.
- The app is Dock-visible as well as a menu bar app. Preserve that behavior unless requested otherwise.
- Read instructions only in subdirectories relevant to your changes.
