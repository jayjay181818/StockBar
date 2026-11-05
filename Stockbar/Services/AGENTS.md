# Services

- Preserve each service's isolation model: actors for shared concurrent state, `@MainActor` classes for UI coordination, and value/pure helpers where appropriate. Do not convert every stateful service into an actor.
- `RefreshService` (with its `RefreshPassScheduler` and `RefreshRequestQueue`) and `CacheCoordinator` own refresh serialization, backoff and circuit breaking; do not bypass their policy.
- Keep broker/Folync ownership boundaries and manual portfolio restoration intact. Review source behavior in [architecture](../../Docs/Architecture.md) for integration changes.
- Keep heavy calculations outside UI execution. Choose weak captures based on ownership and lifetime, not mechanically in every closure.
