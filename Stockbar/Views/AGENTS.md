# Views

- `StockbarMainView` is the live sidebar/window; settings use `StockbarSettingsView`. Do not reintroduce a separate preferences popout.
- Keep UI state on `@MainActor`; route fetching through `DataModel` or services and calculations through Services/Analytics.
- SwiftUI views are value types: do not mechanically add `[weak self]`. Manage task cancellation and reference-type subscription lifetimes deliberately.
- Follow existing native styling and semantic colors. Verify affected UI through its real surface when practical, using isolated acceptance for data-sensitive changes.
