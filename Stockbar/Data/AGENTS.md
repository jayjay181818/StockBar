# Data layer

- `DataModel.swift` owns UI-facing portfolio state; preserve refresh serialization (`RefreshPassScheduler` in `Services/RefreshService.swift`) and the existing persistence update pipeline (`triggerTradeUpdate`).
- Keep manual holdings recoverable when switching sources. Watchlist-only symbols and benchmarks must not acquire position math.
- For subprocess work read [Networking guidance](Networking/AGENTS.md); for persistence read [Core Data guidance](CoreData/AGENTS.md).
- Refresh and cache defaults belong in `Services/RefreshService.swift` and `Services/CacheCoordinator.swift`; inspect them rather than duplicating numeric policies.
