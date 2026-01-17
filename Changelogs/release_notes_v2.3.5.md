# Release Notes v2.3.5

## 🛡️ Stability & Menu Chart Reliability

This release focuses on eliminating menu dropdown crashes and improving resilience in chart rendering and startup.

---

## ✅ Crash Fixes

- **Menu Charts Stability**: Replaced menu dropdown Charts usage with a lightweight Canvas sparkline to avoid Swift Charts EXC_BREAKPOINT crashes on macOS 26.2.
- **Logger Crash Fix**: Stabilized log compaction by counting newline bytes directly from Data instead of String splitting.
- **Init Order Fix**: Ensured `StockMenuBarController` calls `super.init()` before invoking instance methods.

---

## 📈 Menu Chart Improvements

- **Canvas Sparkline**: Smooth bezier line with subtle glow and gradient fill, keeping the compact menu layout.
- **Invalid Data Guardrails**: Filters non-finite/zero prices and skips chart render when fewer than 2 valid points exist.
- **Safe Fallbacks**: Menu chart remains responsive even when historical data is missing.

---

## 🧩 Build & Packaging Fixes

- **Missing Model Added**: Restored `PortfolioMenuBarDisplaySettings` to fix Release build failures.
- **Refresh Cleanup**: Removed stale `probeTargets`/`performProbeRefresh` references in `RefreshService`.

---

## 📋 Files Modified

| File | Change |
|------|--------|
| `Stockbar/Charts/MenuPriceChartView.swift` | Canvas sparkline rendering + data guardrails |
| `Stockbar/Utilities/Logger.swift` | Safe log compaction |
| `Stockbar/Models/PortfolioMenuBarDisplaySettings.swift` | Added model |
| `Stockbar/Services/RefreshService.swift` | Removed stale probe references |
| `Stockbar/StockMenuBarController.swift` | `super.init()` ordering fix |

---

*Release Date: 17th January 2026*
