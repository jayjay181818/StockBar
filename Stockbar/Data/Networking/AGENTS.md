# Stockbar Networking Knowledge Base

**Architecture:** Python Subprocess Bridge | **Concurrency:** Swift 6 + Thread-safe Buffering
**Domain:** External data acquisition via Python `yfinance` and subprocess orchestration.

## OVERVIEW
The Networking layer handles all external data fetching. It primarily uses a hybrid bridge that executes a bundled Python script (`get_stock_data.py`) to leverage the `yfinance` library.

## CORE COMPONENTS

### PythonNetworkService
- **Role**: Primary implementation of `NetworkService`.
- **Mechanism**: Spawns `Process` instances running the configured Python interpreter.
- **Data Formats**: Supports both legacy string parsing (Regex-based) and modern JSON-based batch/historical data.

### SafeDataBuffer
- **Purpose**: Prevents pipe buffer overflows (65KB system limit) during large data transfers (e.g., historical data).
- **Implementation**: Uses `NSLock` for thread-safe `Data` appending during asynchronous readability handler callbacks.
- **Usage**: Mandatory for any subprocess call expected to return >1KB of data.

### PythonConfiguration
- **Role**: Manages interpreter path discovery (default: `/usr/bin/python3`).
- **Security**: Provides `sanitizeSymbol(_:)` and `validateSymbol(_:)` to prevent command injection. Allowed: `A-Z`, `0-9`, `.`, `^`, `=`, `-`.

## OPERATIONAL PARAMETERS

### Process Timeouts
To prevent hanging the application, strict timeouts are enforced:
- **Quotes**: 30 seconds.
- **OHLC Data**: 2 minutes.
- **Historical/Batch Data**: 5 minutes.

### Output Handling
- **stdout**: Reserved for structured data (JSON) or valid price strings.
- **stderr**: Captured for debugging and logged via `Logger.shared`.
- **JSON Error Parsing**: Scripts return a JSON object with `error: true` and `error_code` for graceful failure handling (e.g., `RATE_LIMIT`, `INVALID_SYMBOL`).

## CONVENTIONS
1. **Symbol Normalization**: Always sanitize symbols before passing to `Process.arguments`.
2. **Incremental Reading**: Use `readabilityHandler` with `SafeDataBuffer` for all non-trivial output.
3. **Task Cancellation**: Always cancel timeout tasks if the process exits normally.
4. **Mocking**: Use `StubNetworkService` for UI testing and unit tests to avoid Python dependencies.

## ERROR RECOVERY
- **FETCH_FAILED**: Explicit script signal for unrecoverable data errors.
- **Fallback Logic**: Application layer (DataModel) handles retries and fallback to alternative symbols/intervals.
