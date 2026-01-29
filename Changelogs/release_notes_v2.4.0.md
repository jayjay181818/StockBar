# Release Notes v2.4.0

## 🧩 Popover Improvements

- Fixed popover anchoring so it consistently appears below the menu bar item.
- Centered footer layout for the updated timestamp, with Preferences and Quit aligned to the edges.
- Standardized the updated timestamp format to "Updated: HH:mm dd/MM/yy".
- Changed the footer button label to "Preferences" (removed ellipsis).
- Added click-outside dismissal while keeping in-popover interactions responsive.
- Fixed London Stock Exchange stocks displaying P&L in pence (GBX) instead of pounds (GBP).
- Currency formatting now uses symbols after the number ($, £, €, ¥, C$, A$) instead of currency codes.
- Large values (≥10,000) now display without decimal places for cleaner presentation.
- Medium values (1,000-9,999) now display with one decimal place.

---

## 📈 Charts and Benchmarks

- Range-based change: the header percent and P&L now reflect the selected time range (1D/1W/1M).
- Benchmark comparison line is thicker and more legible.
- Automatic tracking and fetching for benchmarks (^GSPC, ^FTSE) to ensure overlay data is available.
- Benchmark line now spans the full selected range and chart padding avoids the time-range picker overlap.
- Benchmarks now use a short-range (30-day) backfill to avoid heavy 5-year fetches while keeping comparisons responsive.
- Menu chart now auto-normalizes UK snapshot scales (GBp/GBP) to prevent extreme 1D P&L spikes in the dropdown.

---

## 🧭 Menu Bar Stability

- Reused existing status items instead of recreating them on each refresh to prevent third-party menu managers (e.g., Bartender) from reshuffling items and stuttering.
- Fixed first-launch menu bar tickers rendering blank until a click by forcing an initial title update.
- Fixed an issue where clicking a menu bar ticker would temporarily strip its color formatting.
- Portfolio summary now uses a popover-based menu to preserve green/red color rendering.
- Portfolio summary format updated to show total value and day gain with percentage.
- Zero-change gains now render in green for consistency.

---

## 🪟 Menu Dropdown Redesign

- **Menu Dropdown Redesign (Layout)**: Implemented a new popover-style layout in `MenuPriceChartView` with header, hero chart, bento grid, and footer styling.
- **Canvas Chart Rendering**: Kept Canvas-based rendering for the menu chart to avoid Charts.framework crashes.

---

## 🧮 Data Providers & Symbol Handling

- Added symbol alias support via `SYMBOL_ALIASES` in `~/Documents/.stockbar_config.json` (e.g., `COPGL.XC` → `COPG.L`) to handle provider-specific tickers.
- Expanded UK symbol detection to include `.XC`, with centralized currency/timezone defaults in `SymbolMetadata`.
- Improved real-time quote resiliency with Twelve Data + Yahoo quote API fallbacks and consistent currency normalization (GBp/GBX → GBP).
- Previous-close handling now supports daily-history lookups for UK symbols when providers return same-day close as prev close.
- Historical backfill now resolves aliases before fetching (but normalizes results back to the original symbol).
- Added an earliest-available-history floor so symbols with shorter histories stop backfilling older, non-existent data.
- Adjusted previous-close backfill for .XC aliases to keep day-change percentages in the correct scale.

---

## 🔄 Menu Bar Refresh & Updates

- Added a refresh action to the “Updated: …” footer in the popover (with a refresh icon) to force an immediate quote refresh.
- Menu bar items now react to deep trade changes using a dedicated trade-content publisher (keeps titles in sync with edits).

---

## 🧷 Settings & Persistence Fixes

- Restored deep-edit persistence by re-triggering the debounced save pipeline for units/cost/symbol edits.
- Portfolio summary now respects the `showColorCoding` preference (neutral colors when disabled).
- Benchmarks (^GSPC, ^FTSE) are treated as transient chart helpers and no longer persist in user trade data.

Release Date: 29 Jan 2026
