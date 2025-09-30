# Stockbar v2.2.9 Release Notes

**Release Date**: September 30, 2025  
**Version**: 2.2.9  
**Previous Version**: 2.2.8  

## 🎯 Overview

Stockbar v2.2.9 centers on reliability, memory efficiency, and smoother navigation. A serialized refresh pipeline keeps quotes coherent, caches adapt to payload size, and the menu bar experience receives quality-of-life upgrades alongside a resilient Python backend fallback.

---

## ✨ Major New Features

### 🧭 Quick Status Menu Actions
- Add `Preferences…` and `Quit StockBar` commands to every status menu with familiar shortcuts
- Provide one-click access to settings without hunting for the Dock icon
- Route actions through `AppDelegate` so the window appears reliably after menu rebuilds

### 📈 Chart Picker Enhancements
- Replace the segmented control with horizontal chip buttons that scroll for large watchlists
- Animate selection changes for better visual continuity between chart types
- Improve VoiceOver labels and selected-state announcements for the picker controls

---

## ⚙️ Performance & Reliability

### 🔄 Safer Refresh Pipeline
- Introduce an actor-backed `RefreshCoordinator` so bulk and staggered refreshes never overlap
- Run `refreshAllTrades` and per-symbol updates on the main actor to keep `realTimeTrades` mutations thread-safe
- When available, call the Python service’s enhanced quote endpoint during individual refreshes for richer pre/post-market data
- Skip symbols still inside cache/ retry windows while logging those decisions for easier diagnostics

### 🧠 Memory-Aware Caching
- Cap in-memory cache entries at 512 KB and transparently promote larger payloads to disk before storing them
- Keep cache statistics in sync after evictions or memory-pressure wipes to maintain accurate diagnostics
- Allow the memory optimizer to trigger full cache cleanup instead of no-op placeholders
- Prefer disk caching for historical windows longer than a week while keeping short lookbacks in memory
- Record historical snapshots with the display-price helper so stored values mirror the UI and exports

### 📜 Logging & Diagnostics
- Persist logs under Application Support and auto-create bundle-specific folders when needed
- Gracefully handle file-system failures during log writes to avoid crashes in sandboxed environments
- Extend CLAUDE developer guidance with Swift 6.0 concurrency notes and explicit testing expectations

---

## 🐍 Python Backend Improvements
- Fallback to Python’s built-in `urllib` when the optional `requests` package is unavailable
- Emit clear stderr warnings instructing users to install `requests` for best performance while still returning quote data
- Normalize error handling between HTTP implementations so failures surface consistently in the macOS app

---

## 🐛 Bug Fixes
- Prevent staggered refresh scheduling from dividing by zero when the watchlist is empty
- Ensure individual refreshes advance the symbol index even after cache skips so timers do not stall
- Fix historical snapshot generation to ignore trades with invalid prices and align values with display data
- Update log compaction to use safe file handles and seek APIs, avoiding rare crashes during rotation
- Harmonize DataModel unit tests with the `realTimeTrades` collection to reflect current storage

---

## 🧪 Testing Recommendations
1. Verify the new chart chips scroll and announce selection correctly across large symbol lists
2. Trigger both bulk and staggered refreshes and confirm no overlapping updates appear in the logs
3. Remove the Python `requests` package to confirm the `urllib` fallback still returns quotes
4. Review Debug tab cache statistics before and after maintenance to see memory counts update
5. Open a status menu entry to confirm `Preferences…` and `Quit StockBar` shortcuts operate as expected

---

## 🔮 What's Next
- Continue refining cache eviction heuristics to balance disk writes and launch time
- Explore richer chart overlays and comparative analytics for the Performance tab
- Expand health checks for Python dependencies with automated self-healing prompts

---

## 👥 Contributors
- Core development and UX polish by the Stockbar team
- Python tooling hardening and logging improvements by project maintainers
- QA verification of refresh sequencing by community testers

---

**Full Changelog**: [View detailed changes on GitHub]
