# STOCKBAR RESOURCES AGENTS KNOWLEDGE BASE (Python Backend)

**Architecture:** Python 3.8+ | **Bridge:** Subprocess / JSON-RPC Lite | **Library:** yfinance
**Domain:** External market data retrieval, historical data backfilling, and currency normalization.

## OVERVIEW
The `Resources/` directory contains the Python-based data layer of Stockbar. Since the Swift application remains unsandboxed, it leverages these scripts via `Process` calls to fetch real-time and historical data from providers like Yahoo Finance, Financial Modeling Prep (FMP), Twelve Data, and Stooq.

## CORE SCRIPTS
- **get_stock_data.py**: The primary orchestrator. Handles real-time quotes, historical data ranges, and batch requests.
- **get_ohlc_data.py**: Specialized fetcher for Open-High-Low-Close candlestick data.
- **requirements.txt**: Minimal dependency list, primarily `yfinance`.

## DATA FLOW & COMMUNICATION
- **Stdout Protocol**: Scripts MUST ONLY output valid JSON (or a specific formatted line for single fetches) to `stdout`. This is the only channel for data transfer to the Swift application.
- **No Stdout Pollution**: Any `print()` calls for debugging or warnings are strictly prohibited on `stdout`. This prevents parser errors in the Swift `NetworkService`.
- **Stderr Logging**: All operational logs, warnings (e.g., missing `requests` library), and tracebacks MUST be directed to `stderr`. The Swift side captures `stderr` and pipes it to the `Logger` service for the Debug console.
- **Structured Errors**: Failures are reported via `output_error()` which returns a JSON object with `error: true` and an `error_code` (e.g., `TIMEOUT`, `RATE_LIMIT`, `NO_DATA`) to allow for programmatic recovery.

## KEY CONVENTIONS
- **GBX to GBP Normalization**: London Stock Exchange (.L) stocks often report in pence (GBX). All scripts automatically divide these values by 100.0 before returning them to ensure consistency in the Swift UI.
- **Rate Limiting**: To prevent API bans and 429 errors, batch fetches implement a mandatory `time.sleep(1.0)` between requests.
- **Provider Fallbacks**: If `yfinance` fails or is unavailable, the system automatically falls back to secondary providers (FMP, Twelve Data, Stooq) based on user configuration.
- **Robust Networking**: Scripts include `urllib` fallbacks to ensure operation if the `requests` library is not installed in the local Python environment.

## WHERE TO LOOK
- **Market State Logic**: See `fetch_real_time_quote_yfinance` for timezone-aware pre/post market detection (America/New_York vs Europe/London).
- **Fetch Priority**: See `get_fetch_priority()` for how the script decides which API to use first.
- **Caching**: Scripts maintain a local `~/.stockbar_cache.json` to minimize redundant network calls during rapid refreshes.

## ANTI-PATTERNS
- **Main Thread Output**: Never use standard `print()` for anything other than the final data payload. Use `print(..., file=sys.stderr)` instead.
- **Hardcoded Keys**: API keys should be retrieved from `~/.stockbar_config.json` or environment variables, never hardcoded.
- **Large Payloads**: Keep JSON responses lean to avoid memory spikes in the subprocess bridge.
