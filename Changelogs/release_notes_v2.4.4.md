# StockBar v2.4.4 Release Notes

**Status:** Implemented
**Date:** 2026-07-12

## Trading 212 Broker Valuation

- Captures a valuation snapshot during linked Trading 212 sync using the broker account summary and linked position wallet-impact data.
- Uses the broker account value, including cash, as the primary Net Value for a linked Trading 212 portfolio.
- Uses broker-provided unrealised P/L and total cost for portfolio Total Net Gains and Total P/L percentages when available.
- Uses broker-provided unrealised P/L for linked position Total P/L while preserving Stockbar's previous-close calculation for Day P/L.
- Carries account currency, investments value, cash value, position value, cost, unrealised P/L, and FX impact through the sync plan without persisting credentials or sensitive account payloads.

## Currency And Fallback Safety

- Converts broker totals from the Trading 212 account currency to the selected display currency without routing broker-valued GBP positions through Stockbar's local USD holding valuation path.
- Normalizes GBX and GBP correctly when broker and display currencies differ.
- Uses broker values only while the snapshot belongs to the enabled Trading 212 environment and account type and remains fresh for the configured sync cadence.
- Falls back to the existing local market-data calculation when a broker snapshot is stale, invalid, absent, or belongs to a different account.
- Activates the latest saved historical USD exchange-rate snapshot when a live FX refresh fails, before falling back to hard-coded rates.

## Unchanged Behavior

- Trading 212 remains opt-in and linked holdings continue to use the existing sync and reconciliation settings.
- Manual portfolios, watchlists, market-data providers, historical charts, and Day P/L calculation paths are unchanged when no fresh broker valuation is available.
- Broker-only holdings are still imported only through the existing explicit or configured reconciliation flows.

## Validation Coverage

- Added coverage for Trading 212 account-value snapshots, including investments, cash, total cost, and unrealised P/L.
- Added coverage proving broker account value drives Net Value and includes cash.
- Added coverage proving broker GBP values are not revalued through the local USD FX path.
- Added coverage for broker-provided linked-position Total P/L and local fallback behavior.
- Added coverage for historical FX snapshot activation and GBX round-trip conversion.
- Verified the macOS app builds successfully with code signing disabled.
- Verified the focused `CurrencyConverterTests`, `PortfolioCalculationTests`, and
  `Trading212BrokerSyncTests` suites pass with 90 tests and zero failures.

## Comparison Basis

These notes describe the local changes beyond GitHub `testing` at commit `8980473` (`chore: release v2.4.3`), fetched on 2026-07-12.
