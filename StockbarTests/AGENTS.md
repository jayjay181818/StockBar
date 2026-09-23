# XCTest

- New Swift test files need explicit membership in `Stockbar.xcodeproj/project.pbxproj`; the app's folder synchronization does not apply to this target. Keep `ProjectTestTargetMembershipTests` passing.
- Use injected mocks, isolated defaults suites and temporary/in-memory Core Data stores. Never use `UserDefaults.standard` with teardown cleanup as isolation.
- `StockbarRuntimeStorage` redirects only when acceptance is configured; merely using the wrapper is insufficient. Configure runtime before first access, or inject isolated dependencies. See [development workflows](../Docs/Development.md).
- Mark UI-facing tests `@MainActor`; await side effects and use controlled clocks instead of sleeps where possible.
- Test one coherent behavior with enough assertions to establish it. Follow nearby naming/Arrange-Act-Assert style without mandatory boilerplate comments. Use tolerances for floating-point comparisons.
- Run the affected class/method first with `bash script/develop.sh test StockbarTests/ClassName[/methodName]`; broaden for shared behavior changes. Tests must not contact live providers.
