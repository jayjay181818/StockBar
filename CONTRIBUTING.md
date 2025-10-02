# Contributing to Stockbar

Thank you for your interest in contributing to Stockbar! This document provides guidelines and instructions for contributing to the project.

---

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Getting Started](#getting-started)
3. [Development Setup](#development-setup)
4. [Code Style Guidelines](#code-style-guidelines)
5. [Testing](#testing)
6. [Pull Request Process](#pull-request-process)
7. [Reporting Bugs](#reporting-bugs)
8. [Feature Requests](#feature-requests)

---

## Code of Conduct

### Our Pledge

We are committed to providing a welcoming and inclusive environment for all contributors, regardless of experience level, gender, gender identity and expression, sexual orientation, disability, personal appearance, body size, race, ethnicity, age, religion, or nationality.

### Expected Behavior

- Be respectful and considerate in all interactions
- Provide constructive feedback
- Accept constructive criticism gracefully
- Focus on what is best for the project and community
- Show empathy towards other community members

### Unacceptable Behavior

- Harassment, trolling, or derogatory comments
- Publishing others' private information
- Spam or commercial advertising
- Any conduct that would be considered inappropriate in a professional setting

---

## Getting Started

### Prerequisites

Before contributing, ensure you have:

- **macOS 15.4+** for development
- **Xcode 16.0+** with Swift 6.0 support
- **Python 3.8+** installed
- **Git** for version control
- Basic familiarity with Swift and SwiftUI

### First Contribution

**New to open source?** Here's how to get started:

1. **Browse Issues:** Look for issues labeled `good first issue` or `help wanted`
2. **Read Documentation:** Familiarize yourself with `CLAUDE.md` and `Docs/UserGuide.md`
3. **Ask Questions:** Don't hesitate to ask for clarification on issues
4. **Start Small:** Begin with documentation fixes or minor bug fixes

---

## Development Setup

### 1. Fork and Clone

```bash
# Fork the repository on GitHub first, then:
git clone https://github.com/YOUR_USERNAME/stockbar.git
cd stockbar
```

### 2. Install Python Dependencies

```bash
# Install yfinance for stock data fetching
pip3 install yfinance

# Or install all requirements
pip3 install -r Stockbar/Resources/requirements.txt
```

### 3. Open in Xcode

```bash
open Stockbar.xcodeproj
```

### 4. Build and Run

- Select the **Stockbar** scheme
- Build: **⌘B**
- Run: **⌘R**
- Test: **⌘U**

### 5. Configure Git

```bash
git config user.name "Your Name"
git config user.email "your.email@example.com"
```

### 6. Create a Branch

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/bug-description
```

**Branch naming conventions:**
- `feature/` - New features
- `fix/` - Bug fixes
- `refactor/` - Code refactoring
- `docs/` - Documentation changes
- `test/` - Test additions/improvements

---

## Code Style Guidelines

### Swift Code Style

#### 1. Language Version
- **Swift 6.0** - Use modern Swift features
- **Concurrency:** Use async/await and actors
- **Type Inference:** Prefer explicit types for public APIs

#### 2. Naming Conventions

**Classes, Structs, Enums:**
```swift
class DataModel { }         // ✅ PascalCase
struct PortfolioSnapshot { } // ✅ PascalCase
enum CacheStatus { }        // ✅ PascalCase
```

**Variables, Functions:**
```swift
var realTimeTrades: [RealTimeTrade]  // ✅ camelCase
func refreshAllTrades() async { }    // ✅ camelCase
let cacheInterval: TimeInterval      // ✅ camelCase
```

**Constants:**
```swift
let maxCacheAge: TimeInterval = 3600  // ✅ camelCase
private let retryIntervals: [TimeInterval]  // ✅ camelCase
```

#### 3. Access Control

**Be explicit:**
```swift
public class CurrencyConverter { }   // ✅ Public APIs
private var lastFetchTime: Date      // ✅ Private implementation
fileprivate func helperMethod() { }  // ✅ When needed
```

#### 4. Swift 6 Concurrency

**Actor Isolation:**
```swift
actor RefreshCoordinator {
    func scheduleRefresh() async { }
}
```

**Main Actor for UI:**
```swift
@MainActor
class DataModel: ObservableObject {
    @Published var realTimeTrades: [RealTimeTrade]
}
```

**Async/Await:**
```swift
func fetchQuote(symbol: String) async throws -> StockFetchResult {
    // Use async/await, not completion handlers
}
```

#### 5. Error Handling

**Use custom error types:**
```swift
enum NetworkError: Error {
    case invalidURL
    case requestFailed(String)
    case timeout
}

throw NetworkError.requestFailed("Rate limit exceeded")
```

**Handle errors gracefully:**
```swift
do {
    let result = try await networkService.fetchQuote(symbol: symbol)
} catch let error as NetworkError {
    await Logger.shared.error("Network error: \(error)")
} catch {
    await Logger.shared.error("Unexpected error: \(error)")
}
```

#### 6. Memory Management

**Always use weak self in closures:**
```swift
URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
    guard let self = self else { return }
    // ...
}
```

**Avoid retain cycles:**
```swift
// ❌ Bad - creates retain cycle
cancellable = publisher.sink { self.handleData($0) }

// ✅ Good - breaks retain cycle
cancellable = publisher.sink { [weak self] data in
    self?.handleData(data)
}
```

#### 7. Logging

**Use Logger service:**
```swift
await Logger.shared.debug("🔍 Fetching price for \(symbol)")
await Logger.shared.info("ℹ️ Cache refreshed successfully")
await Logger.shared.warning("⚠️ Stale cache detected")
await Logger.shared.error("🔴 Failed to fetch data: \(error)")
```

**Emoji prefixes:**
- 🔍 Debug
- ℹ️ Info
- ⚠️ Warning
- 🔴 Error

#### 8. Comments and Documentation

**Document public APIs:**
```swift
/// Converts an amount from one currency to another
/// - Parameters:
///   - amount: The amount to convert
///   - from: Source currency code (e.g., "USD")
///   - to: Target currency code (e.g., "GBP")
/// - Returns: Converted amount in target currency
public func convert(amount: Double, from: String, to: String) -> Double {
    // Implementation
}
```

**Use `// MARK:` for organization:**
```swift
// MARK: - Cache Management
func clearCache() { }

// MARK: - Network Requests
func fetchData() async { }

// MARK: - Helper Methods
private func helper() { }
```

#### 9. SwiftUI Best Practices

**State management:**
```swift
@State private var selectedTab: Int = 0        // Local UI state
@AppStorage("currency") private var currency: String  // Persisted preference
@Published var realTimeTrades: [RealTimeTrade]       // Observable data
```

**View composition:**
```swift
// Break large views into smaller components
struct PortfolioView: View {
    var body: some View {
        VStack {
            HeaderView()
            StockListView()
            FooterView()
        }
    }
}
```

### Python Code Style

#### Follow PEP 8

```python
# Good variable naming
current_price = 150.50
previous_close = 148.25

# Good function naming
def fetch_stock_data(symbol: str) -> dict:
    """Fetch stock data from Yahoo Finance."""
    pass

# Good class naming
class StockDataFetcher:
    """Handles stock data fetching operations."""
    pass
```

#### Type Hints

```python
def get_price(symbol: str) -> float:
    """Get current price for symbol."""
    return 0.0
```

#### Error Handling

```python
try:
    data = yfinance.Ticker(symbol)
except Exception as e:
    print(f"FETCH_FAILED: {str(e)}", file=sys.stderr)
    return None
```

---

## Testing

### Running Tests

**Via Xcode:**
- Press **⌘U** to run all tests
- Or use Test Navigator to run specific tests

**Via Command Line:**
```bash
xcodebuild test -project Stockbar.xcodeproj -scheme Stockbar -destination 'platform=macOS'
```

### Writing Tests

#### Test File Location
- Place tests in `StockbarTests/` directory
- Name tests: `[Component]Tests.swift`

#### Test Structure

```swift
import XCTest
@testable import Stockbar

class MyComponentTests: XCTestCase {

    var component: MyComponent!

    override func setUp() {
        super.setUp()
        component = MyComponent()
    }

    override func tearDown() {
        component = nil
        super.tearDown()
    }

    func testBasicFunctionality() {
        // Arrange
        let input = "test"

        // Act
        let result = component.process(input)

        // Assert
        XCTAssertEqual(result, "expected")
    }
}
```

#### Testing Guidelines

1. **Test Naming:** Use descriptive names: `testCurrencyConversionWithUSD()`
2. **One Assertion Per Test:** Focus tests on single behaviors
3. **Mock External Dependencies:** Don't hit real APIs in tests
4. **Edge Cases:** Test boundary conditions, nil values, errors
5. **Floating-Point Comparisons:** Use `accuracy` parameter:
   ```swift
   XCTAssertEqual(result, 79.0, accuracy: 0.01)
   ```

#### Coverage Goals

- **Critical Business Logic:** 80%+ coverage
- **Currency Conversion:** Comprehensive (all currency pairs, GBX handling)
- **Portfolio Calculations:** All calculation paths
- **Cache Logic:** All states and transitions

### Python Testing

```bash
# Test single stock
python3 Stockbar/Resources/get_stock_data.py AAPL

# Test multiple stocks
python3 Stockbar/Resources/get_stock_data.py AAPL GOOGL MSFT

# Test UK stock (GBX handling)
python3 Stockbar/Resources/get_stock_data.py VOD.L
```

---

## Pull Request Process

### Before Submitting

1. **Create an Issue First:** Discuss significant changes before coding
2. **Follow Code Style:** Adhere to guidelines above
3. **Write Tests:** Add tests for new functionality
4. **Update Documentation:** Modify user guides if behavior changes
5. **Test Thoroughly:** Run all tests and verify app works
6. **Check Logs:** Review `~/Documents/stockbar.log` for errors

### Commit Messages

**Format:**
```
[Type] Brief description (50 chars max)

Detailed explanation of changes (72 chars per line max).
Include motivation and contrast with previous behavior.

Fixes #123
```

**Types:**
- `feat:` - New feature
- `fix:` - Bug fix
- `refactor:` - Code restructuring
- `test:` - Test additions/modifications
- `docs:` - Documentation changes
- `perf:` - Performance improvements
- `chore:` - Maintenance tasks

**Examples:**
```
feat: Add dark mode support for preferences window

Implemented automatic dark mode detection and manual override.
Users can now choose System, Light, or Dark appearance.

Fixes #45
```

```
fix: Correct GBX to GBP conversion for UK stocks

UK stocks were displaying incorrect values due to missing
pence-to-pounds conversion. Now properly divides by 100.

Fixes #78
```

### PR Submission Checklist

**Before clicking "Create Pull Request":**

- [ ] Code follows project style guidelines
- [ ] All tests pass (⌘U in Xcode)
- [ ] New tests added for new functionality
- [ ] Documentation updated (if applicable)
- [ ] Commit messages are clear and descriptive
- [ ] No merge conflicts with `main` branch
- [ ] App builds and runs without errors
- [ ] Reviewed own code for obvious issues

### PR Description Template

```markdown
## Description
Brief description of changes

## Motivation and Context
Why is this change needed? What problem does it solve?

## Type of Change
- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] New feature (non-breaking change adding functionality)
- [ ] Breaking change (fix or feature causing existing functionality to change)
- [ ] Documentation update

## How Has This Been Tested?
Describe your testing process

## Screenshots (if applicable)
Add screenshots for UI changes

## Checklist
- [ ] My code follows the project's code style
- [ ] I have performed a self-review of my code
- [ ] I have commented my code where necessary
- [ ] I have updated documentation accordingly
- [ ] My changes generate no new warnings
- [ ] I have added tests that prove my fix/feature works
- [ ] New and existing tests pass locally

## Related Issues
Fixes #(issue number)
```

### Review Process

1. **Maintainer Review:** A project maintainer will review your PR
2. **CI Checks:** Automated tests will run (if configured)
3. **Feedback:** Address any requested changes
4. **Approval:** Once approved, PR will be merged
5. **Cleanup:** Delete your branch after merge

---

## Reporting Bugs

### Before Reporting

1. **Search Existing Issues:** Check if already reported
2. **Verify Latest Version:** Reproduce on latest release
3. **Minimal Reproduction:** Create minimal test case
4. **Collect Information:** Gather logs, screenshots, debug reports

### Bug Report Template

**Title:** Brief, descriptive summary

**Description:**
```markdown
## Environment
- Stockbar Version: [e.g., 2.2.10]
- macOS Version: [e.g., macOS 15.4]
- Python Version: [e.g., 3.11.5]
- yfinance Version: [e.g., 0.2.28]

## Bug Description
Clear description of what the bug is

## Steps to Reproduce
1. Open Stockbar
2. Click on '...'
3. Scroll down to '...'
4. See error

## Expected Behavior
What you expected to happen

## Actual Behavior
What actually happened

## Screenshots
If applicable, add screenshots

## Logs
Paste relevant logs from ~/Documents/stockbar.log

## Debug Report
Attach debug report export if helpful

## Additional Context
Any other context about the problem
```

---

## Feature Requests

### Before Requesting

1. **Check Existing Requests:** Search issues for similar ideas
2. **Consider Scope:** Is it aligned with project goals?
3. **Think Through UX:** How would users interact with this?

### Feature Request Template

```markdown
## Feature Description
Clear description of the proposed feature

## Problem Statement
What problem does this solve?

## Proposed Solution
How would this feature work?

## Alternative Solutions
What alternatives have you considered?

## Additional Context
Mockups, examples, or other helpful context

## Potential Implementation
(Optional) Ideas for how to implement this
```

---

## Project Structure

### Key Directories

```
Stockbar/
├── Stockbar/                   # Main app code
│   ├── Data/                   # Data models and CoreData
│   ├── Services/               # Business logic services
│   ├── UI/                     # SwiftUI views and controllers
│   ├── Resources/              # Python scripts, assets
│   └── Supporting Files/       # Plist, entitlements
├── StockbarTests/              # Unit tests
├── Docs/                       # User documentation
├── CLAUDE.md                   # Architecture documentation
└── CONTRIBUTING.md             # This file
```

### Important Files

- **`AppDelegate.swift`** - App lifecycle and initialization
- **`DataModel.swift`** - Central data controller (MVVM)
- **`CacheCoordinator.swift`** - Cache management service
- **`CurrencyConverter.swift`** - Currency conversion logic
- **`NetworkService.swift`** - Stock data fetching
- **`get_stock_data.py`** - Python backend for Yahoo Finance
- **`HistoricalDataManager.swift`** - Chart data management

---

## Additional Resources

### Documentation

- **[CLAUDE.md](CLAUDE.md)** - Comprehensive architecture overview
- **[User Guide](Docs/UserGuide.md)** - End-user documentation
- **[FAQ](Docs/FAQ.md)** - Common questions and solutions

### External Resources

- [Swift Language Guide](https://docs.swift.org/swift-book/)
- [Swift 6 Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- [yfinance Documentation](https://pypi.org/project/yfinance/)

---

## Questions?

If you have questions about contributing:

1. Check existing documentation
2. Search closed issues for similar discussions
3. Open a new issue with the `question` label
4. Be patient - maintainers respond when available

---

## License

By contributing to Stockbar, you agree that your contributions will be licensed under the same license as the project.

---

**Thank you for contributing to Stockbar!** 🚀

Your contributions help make this project better for everyone.

---

*Last updated: October 2025*
