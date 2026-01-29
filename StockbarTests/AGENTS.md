# STOCKBAR TESTS AGENTS KNOWLEDGE BASE

**Architecture:** XCTest Framework | **Swift 6 Concurrency** | **Mocking Strategy:** Dependency Injection
**Domain:** Unit & Integration Testing, Regression Testing, and Performance Verification.

## OVERVIEW
The `StockbarTests` suite ensures the reliability and correctness of the Stockbar application. It covers everything from low-level data normalization to high-level portfolio analytics and UI formatting logic.

- **Primary Framework**: XCTest (native Apple testing framework).
- **Target**: `@testable import Stockbar` allows testing of internal symbols.
- **Concurrency**: Full support for Swift 6 async/await and Actor-isolated testing.

## TEST SUITE STRUCTURE

| Test File | Focus | Key Coverage |
|-----------|-------|--------------|
| **DataModelTests.swift** | State Hub | Initialisation, persistence, and state management. |
| **RiskMetricsServiceTests.swift** | Analytics | VaR, Sharpe, Sortino, Beta, and Drawdown calculations. |
| **PortfolioAnalyticsTests.swift** | Logic | Sector attribution and performance contribution. |
| **CurrencyConverterTests.swift** | Networking | Exchange rate normalization and GBX to GBP conversion. |
| **CacheCoordinatorTests.swift** | Reliability | Cache TTL, eviction policies, and breaker logic. |
| **MenuBarFormattingServiceTests.swift** | UI Logic | Label generation, color coding, and market hour indicators. |

## CONVENTIONS

### 1. Test Pattern: Given / When / Then (AAA)
All tests should follow the Arrange-Act-Assert pattern, explicitly labeled with comments:
```swift
func testScenario_Condition_ExpectedOutcome() async throws {
    // Given: Setup of state and dependencies
    let input = ...
    
    // When: Execution of the code under test
    let result = await service.performAction(input)
    
    // Then: Verification of results
    XCTAssertEqual(result, expectedValue)
}
```

### 2. Naming Conventions
- **Files**: `[ClassName]Tests.swift` (e.g., `DataModelTests.swift`).
- **Methods**: `test[Function]_[Condition]_[Expectation]` (e.g., `testVaR_WithEmptyReturns_ShouldReturnNil`).
- **Mocks**: Use `createMock[Entity]()` helper methods for generating test data.

### 3. Concurrency & Actors
- **@MainActor**: Tests for UI-facing components (like `DataModel`) MUST be marked `@MainActor`.
- **Async Setup**: Use `override func setUp() async throws` for services requiring asynchronous initialization.
- **Task Verification**: Ensure `Task` completion before assertion when testing side effects.

### 4. Dependency Management
- Prefer Dependency Injection (DI) to allow passing mock services.
- Use `UserDefaults.standard` for persistence testing but ensure cleanup in `tearDown()`.

## ANTI-PATTERNS (DO NOT DO)
1. **Network Dependency**: Never make real network calls in tests. Use mock responses or local JSON data.
2. **Core Data Side Effects**: Do not use the production Core Data store; use an in-memory `NSManagedObjectContext` where possible.
3. **Flaky Timers**: Avoid using `sleep()` or long `Expectation` timeouts. Use mock clocks or immediate triggers.
4. **State Leakage**: Always reset shared instances or create new instances in `setUp()` to ensure test isolation.

## NOTES
- **Symbol Normalization**: Verify that `.L` symbols always convert to `GBP` early in the data pipeline.
- **Precision**: Use `accuracy` parameters in `XCTAssertEqual` for `Double` calculations (e.g., `accuracy: 0.0001`).
- **Log Monitoring**: Tests can verify logging behavior via `Logger.shared` if necessary.
