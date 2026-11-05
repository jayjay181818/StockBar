# StockBar v3.0.1 Release Notes

**Status:** Implemented  
**Date:** 2026-11-05

A patch release for 3.0.0. It makes Keychain prompts and network outages easier to live with. No stored data changes.

## Keychain

- While macOS is asking whether Stockbar may use its saved Folync credentials, Settings and the connection status say "Waiting for Keychain access" and suggest **Always Allow**, instead of looking stuck.
- The Folync token field shows "Checking Keychain…" while the stored token is being read.
- A pending Keychain prompt no longer stalls Folync supplemental data (exchange rates, benchmarks, chart history). The token is read outside the coordinator, so other Folync work continues while the prompt is open.

## Exchange rates

- When a rate fetch fails, for example while the Mac is offline, Stockbar retries five minutes later instead of waiting for the next hourly refresh. Data Health stops showing **Update failed** soon after the network returns.

## Logs

- Trimming the in-memory portfolio chart series is now a debug message. Before, every price refresh with a large stored history logged an "Aggressive cleanup" warning, although nothing was wrong.

## Development

- `script/build_and_run.sh` signs local builds with the first valid Apple Development identity when one is installed, so macOS keeps the Keychain "Always Allow" decision across rebuilds. Set `STOCKBAR_SIGNING_IDENTITY` to choose an identity, or `adhoc` to opt out.
- The invariant validators fail clearly when ripgrep is not installed.

## Comparison basis

These notes cover the changes on `testing` after tag `v3.0.0`.
