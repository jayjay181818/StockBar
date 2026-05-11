# StockBar v2.4.2 Release Notes

## Trading 212 Broker Preview

- Phase 0: Treat the local working tree as the source of truth for implementation. The packaged modern app bundle remains a provenance mismatch, so Trading 212 work is being integrated into the local Data Sources settings view that actually exists in this checkout.
- Phase 0: Verified current official Trading 212 Public API docs: credentials are API Key + API Secret using HTTP Basic auth; public API is documented for Invest and Stocks ISA account types; demo and live environments use separate base URLs.
- Phase 0: Confirmed MVP permission model: Account data required, Metadata recommended, History permissions optional future, and Orders - Execute never required.
- Phase 0: Trading 212 position values are labelled in StockBar as broker-provided live position data, not guaranteed real-time exchange quotes.

## Implementation Progress

- Phase 1: Added Trading 212 settings controls to the local Data Sources view, including enable/disable, live/demo selection, account type/label, permission guidance, API key + API secret credential entry, Keychain status, test connection, and read-only preview controls.
- Phase 1: Added Trading 212 credential storage via Keychain only. Non-secret settings are stored separately in user preferences.
- Phase 1: Added redaction coverage for Trading 212 API key/secret labels, HTTP Basic authorization headers, and account identifiers.
- Phase 2: Added a Swift Trading212Provider for the current documented account summary, positions, instruments, and exchanges endpoints. The existing Python/yfinance market-data path remains untouched.
- Phase 2: Added a memory-first preview cache with live/demo-separated broker account keys. No raw payloads, credentials, auth headers, or account numbers are stored.
- Phase 3: Added InstrumentResolver and read-only preview row mapping for Trading 212 positions, including `.L`, `.LON`, and local legacy `.XC` UK suffix handling.
- Phase 3: Clarified Trading 212 credential UX after save. Keychain-saved fields now show stored/replacement placeholders, save is disabled unless both new credential parts are entered, and blank saves are rejected before touching Keychain.
- Phase 3: Fixed Trading 212 preview symbol resolution for provider-specific aliases such as lowercase London venue suffixes (`AVl_EQ` -> `LSE:AV`) and legacy Hims & Hers provider ticker `OAC_US_EQ` -> `US:HIMS` using metadata short names.
- Phase 3: Expanded the read-only import preview into a manual-match audit. Preview rows now compare each broker position with the existing manual holding symbol, quantity, currency-assisted identity mapping, and quantity delta before any future merge/link action is allowed.
- Phase 4: Added explicit broker-link persistence for clean previews. StockBar now saves normalized Trading 212 links keyed by `brokerAccountKey + instrumentId` only after user confirmation, without changing manual holdings, backups, historical data, market caches, or Core Data trade rows.
- Phase 5: Added linked Trading 212 holding sync planning and settings. Linked holdings can now be refreshed from broker-provided live position data, auto-sync can be enabled on an interval, and users can opt into deleting linked manual holdings when the broker position is removed from Trading 212.
- Phase 5: Changed linked Trading 212 sync to a 30-second default cadence using one bulk positions refresh per cycle rather than per-ticker broker polling. Periodic sync skips metadata fetches and falls back to stored provider tickers for linked holdings, avoiding false deletions for provider aliases such as `OAC_US_EQ`.
- Phase 5: Added safe Trading 212 sync log markers for scheduler start, broker snapshot fetches, and linked holding sync summaries. Legacy minute-based sync preferences are ignored so the current 30-second broker interval remains authoritative.
- Phase 5: Fixed Trading 212 linked LSE cost-basis normalization. Pence-priced broker rows now normalize average cost and current price into the same GBP unit before total net gains are calculated, preventing false million-scale losses in the Holdings summary.
- Holdings: Added a Total P/L column beside Day P/L. Clicking either P/L header or value toggles that column between amount and percentage.
- UI alignment: Replaced the old Preferences window shell with the newer Settings structure: General, Menu Bar, Appearance, Data Sources, Refresh, and Advanced.
- UI alignment: Added a first-class Stockbar window with the newer left sidebar sections: Holdings, Charts, Risk, Allocation, Alerts, Backups, Data Health, and Diagnostics.
- UI alignment: Added Open Stockbar and Settings actions from the app menu, Settings window, main window sidebar, and menu bar menu so portfolio management is no longer hidden inside Preferences.

## Validation

- Verified the Total P/L change with a targeted portfolio calculation test and the full macOS test suite: 177 tests passed.
- Rebuilt and relaunched the local Debug app, then reviewed app and macOS logs for crashes, runtime errors, Trading 212 sync failures, and secret leaks. No new serious runtime issues were found.
