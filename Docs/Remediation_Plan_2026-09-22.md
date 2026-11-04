# Stockbar remediation plan — 22 September 2026

Source: full project review of 22 September 2026 (build, 357 XCTests, Python and tooling tests, lint/validators; line reads of shell, menu bar, popovers, refresh/cache, Python bridge core; targeted inspection elsewhere).

Status legend: ⬜ not started · 🔄 in progress · ✅ done · ⏸ deferred (needs decision) — each completed slice records its verification.

Committed on `testing` (23 Sept 2026) in seven area slices — tooling/CI, Python bridge, data layer, services, UI/project, tests, docs — each including the previously uncommitted Folync/overhaul work in the same files. Intermediate commits are not guaranteed to build on their own; the final commit does. Not pushed.

## Slice 1 — Position units editing (High 1, 2)
- ✅ Preserve fractional units when editing from the menu-bar popover (`StockStatusBar.updateUnits`).
- ✅ Locale-aware units parsing with visible validation error in the popover editor.
- ✅ Enforce `DataModel.positionFinancialFieldsReadOnly(for:)` for `canEditUnits`.

## Slice 2 — Standard main menu (High 3)
- ✅ App menu (About, Settings, Hide/Hide Others/Show All, Quit), Edit, Window and Help menus.

## Slice 3 — Refresh policy (High 4, 5)
- ✅ Circuit breaker suppresses fetches for suspended symbols and applies backoff to never-succeeded symbols.
- ✅ User refresh interval is honoured as the freshness floor.
- ✅ `CacheCoordinator.init` no longer calls actor-isolated method from nonisolated init.

## Slice 4 — Suspension visibility and dead menu-bar code (High 6)
- ✅ Show suspension state and a Retry action in the per-symbol popover.
- ✅ Delete unreachable `updateMenu`, `retrySymbol` legacy path, `convertToGBP`, `MenuPriceChartHostingView`, `SparklineMenuView.swift`.

## Slice 5 — Analytics correctness (High 7, Medium)
- ✅ Max drawdown / drawdown periods ignore zero and non-finite values.
- ✅ Correlation matrix reads stored price history instead of the `nil` stub.

## Slice 6 — Startup robustness (Medium)
- ✅ Python dependency check off the main actor with timeout.
- ✅ Copied pip command uses the absolute bundled requirements path.
- ✅ Dependency and recovery alerts attach to the main window as sheets.
- ✅ Dependency check re-runs when the interpreter path changes.
- ✅ Daily automatic backup rechecked periodically while running.

## Slice 7 — Storage isolation (Medium)
- ✅ All `@AppStorage` use `StockbarRuntimeStorage.userDefaults`.

## Slice 8 — Persistence ordering (Medium)
- ✅ Trade/trading-info saves serialized in submission order.
- ✅ Pending saves flushed on termination.

## Slice 9 — Exchange-rate freshness (Medium)
- ✅ Rates restored from disk keep their stored timestamp.

## Slice 10 — Duplicate symbol status items (Medium)
- ✅ Duplicate rows no longer collapse into one rebinding controller.

## Slice 11 — Build configuration (Medium)
- ✅ Strict concurrency for Release as well as Debug.
- ✅ Remove unused `Info.plist` and `Main.storyboard`; move keys to `INFOPLIST_KEY_*`.

## Slice 12 — Logger autoclosure warnings (Medium)
- ✅ Remove 464 non-Sendable autoclosure warnings.

## Slice 13 — Deprecated APIs (Medium/Low)
- ✅ `NSUserNotification` → `UserNotifications`; deprecated `onChange`; `activate(ignoringOtherApps:)`; remaining trivial warnings.

## Slice 14 — Menu bar and popover UI polish
- ✅ Neutral colour for zero/unknown changes; no `nan` header; currency on header price.
- ✅ Consistent "Stockbar" naming; locale-aware formatting; tooltips and accessibility labels on status items.

## Slice 15 — Main window UX
- ✅ Remember window frame; do not re-centre on every open.
- ✅ Native sidebar (`List` selection) with keyboard/VoiceOver support; single Settings entry; highlight parent for Risk/Allocation.
- ✅ Refresh feedback.

## Slice 16 — Python bridge hygiene
- ✅ Bare `except:` and stale commentary in `get_fetch_priority`.

## Slice 17 — Documentation and hygiene
- ✅ README Swift version; remove obsolete `Scripts/setup_and_run_tests.sh`; update Architecture where behaviour changed.

## Slice 18 — Follow-up: warnings and concurrency hygiene
- ✅ Archive cleanup no longer blocks a Swift concurrency thread.
- ✅ Remaining Swift 6 diagnostics in app code resolved (0 warnings).
- ✅ Removed dead, racy import/export path.

## Slice 19 — Acting on the review's recommendations
- ✅ One-time repair of mixed-scale UK price snapshots; single shared scale rule.
- ✅ Python quote cache moved out of the home folder; backup/restore scripts updated.
- ✅ Hardened runtime for Release; unused `VolumeChartView` removed.
- ✅ Watchlist toggle restored in Holdings; labelled row actions.
- ✅ User Guide and FAQ rewritten; local review files ignored by git.

## Slice 20 — Visual pass (offscreen renders)
- ✅ Popover period P&L no longer reads 0 when the chart has no stored history.
- ✅ Risk "no history" is a neutral empty state, not an orange error.
- ✅ Zero P&L neutral in Holdings; watchlist rows show "—" for value.
- ✅ Portfolio totals no longer show placeholder $0.00 while services start.

## Slice 21 — UI/UX and motion modernisation (25 Sept 2026)
- ✅ Shared design language (`Views/StockbarDesign.swift`): motion curves that respect Reduce Motion, neutral-at-zero gain/loss colours, cards, page headers, metric tiles, change badge, search field, chart draw-in.
- ✅ Main window: native `NavigationSplitView` with full-height sidebar under a transparent title bar; sidebar footer shows portfolio source, last price update and refresh (⌘R); pages cross-fade.
- ✅ Consistent page headers; Overview hero, Swift Charts area chart with hover read-out; Holdings tiles, search, Edit/Done, remove confirmation; Alerts, Backups, Data Health, Diagnostics redesigned.
- ✅ Settings: segmented tabs and grouped forms instead of a second sidebar; duplicated portfolio summary and log viewer removed; benchmark toggle exposed.
- ✅ Popovers follow the Theme setting, hover (not drag) to scrub, exact amounts, empty state instead of a flat line, icon footer with Open Stockbar.

## Deferred / needs decision
- ✅ ~~UK ×20 rescale heuristics~~ — one-time `UKPriceSnapshotScaleMigrationService` (Slice 19); display guards kept as a logged safety net.
- ✅ ~~Python cache location~~ — moved to `~/Library/Caches/stockbar-cache/quote_cache.json` with one-time legacy move (Slice 19).
- ⏸ `urllib3` 1.26 pin (tied to Apple Python/LibreSSL target).
- 🔄 Hardened runtime enabled for Release (Slice 19); notarization still needs a Developer ID identity.
- ✅ ~~`VolumeChartView`~~ — deleted (unreachable; indicator maths retained). Annotation editor is wired per the 5 Sept overhaul.
- ✅ ~~Root-level review documents and `artifacts/`~~ — kept locally, excluded via `.gitignore`.
- ⏸ Chart configuration persistence across sections; full accessibility/resizing acceptance matrix.
- ✅ ~~Remaining 50 Swift 6 region-isolation warnings~~ — resolved in Slice 18; app target now builds with 0 warnings. Switching to Swift 6 language mode still needs a runtime pass (dynamic isolation checks).
- ✅ ~~Stale User Guide and FAQ~~ — both rewritten against the current window (Slice 19).
- ✅ ~~`DataModelTests` touch real defaults~~ — not an issue: under XCTest `StockbarAcceptanceRuntime` auto-isolates to `com.stockbar.acceptance.xctest-<pid>` with live providers disabled. Minor leftover: those per-run suites (39 plists, ~156 KB) accumulate in `~/Library/Preferences`.
- ✅ ~~`cleanArchiveCacheBySize` blocks with `DispatchQueue.sync`~~ — resolved in Slice 18.
- ✅ Visual verification — Slice 21 captured real on-screen windows (Screen Recording now granted). Earlier note: offscreen renders reviewed (Slice 20). An isolated `com.stockbar.acceptance` launch passed preflight, but window capture needs Screen Recording permission, which was not granted. Sidebar selection highlight and dark-mode window background can only be judged on the real surface.

## Progress log
- **Slice 1 ✅** — `MenuPopoverFormatter.units/editableUnits/parseUnits` (locale-aware, up to 8 dp); popover editor shows inline validation, Return/Esc shortcuts, disabled pencil with explanation for read-only positions; `StockStatusItemController.updateUnits` stores full precision and re-checks read-only authority. Verified: build + `MenuPopoverUnitsFormattingTests` (2 new tests) pass.
- **Slice 2 ✅** — `AppDelegate.setupMainMenu` now builds App (About, Open, Settings, Services, Hide/Hide Others/Show All, Quit), Edit (Undo/Redo/Cut/Copy/Paste/Delete/Select All), Window (Close ⌘W, Minimize ⌘M, Zoom, Bring All to Front) and Help (system search) menus. Verified: build passes; no new warnings.
- **Slice 3 ✅** — `CacheCoordinator.shouldRefresh` defers failing/suspended symbols to backoff; `shouldRetry` tolerates legacy counts without timestamps; pruning (pure `prunedState`, also used by init) drops orphaned failure counts (Aug H7). `RefreshService` uses the user's interval (×0.9 grace, ≥30s) as freshness; Python quote cache follows via `STOCKBAR_QUOTE_CACHE_SECONDS` (15–300s). Verified: `CacheCoordinatorTests` 27/27 (4 new), python-tests pass (1 new).
- **Slice 4 ✅** — Per-symbol popover shows an orange "Updates paused…" notice with **Retry Now** (clears suspension, refreshes the symbol immediately); popover sizes to content (`sizingOptions = .preferredContentSize`). Removed dead `updateMenu` (~520 lines), `convertToGBP`, `usePopover`, `MenuPriceChartHostingView`, `SparklineMenuView.swift`; `StockStatusBar.swift` 1532 → ~1030 lines. Footer "Preferences" → "Settings" with refresh tooltip/accessibility label. Also fixed 10 pre-existing Swift 6 warnings in `MenuPriceChartView`, `PortfolioMenuPopoverView`, `StockbarOverviewView`. Verified: full suite 363/363.
- **Slice 5 ✅** — `RiskMetricsService` drops zero/non-finite observations before drawdown and return calculations (root cause of the audit's 100%/1-day drawdown); drawdown periods now report the deepest trough, not the value before recovery; `maxDrawdownDuration` documented as observations. `RiskAnalyticsView` currency formatter uses `currencyCode` (was printing "GBP1,234"). Correlation reads 180 days of stored snapshots, aligns daily closes across holdings (new `CorrelationMatrixService.alignedDailyReturns`), computes real annualised volatilities instead of the 20% placeholder, requires ≥20 shared days and shows an explanatory empty state. Verified: `RiskMetricsServiceTests` 22/22 (3 new), `PortfolioAnalyticsServicesTests` 16/16 (2 new).
- **Slice 6 ✅** — Dependency check runs through `PythonProcessRunner` (off main actor, 20s timeout, pipes drained) and re-runs when the interpreter path changes (`pythonDependencyCheck.interpreterPath`). Copied command is `'<python>' -m pip install -r '<bundle>/requirements.txt'` with shell quoting; alert mentions virtual environments for externally-managed Pythons; Terminal opened by bundle ID. Dependency and Core Data recovery alerts are sheets on the main window via `presentAlert` (no startup-freezing `runModal`). Automatic backup re-checked every 6h. Verified: build; `StockbarProviderAccessPolicyTests` 18/18 (1 new).
- **Slice 7 ✅** — `menu.benchmarkComparisonEnabled` and three `debugLog*` settings now use `StockbarRuntimeStorage.userDefaults`. New invariant #6 in `Scripts/validate_invariants.sh` fails on any unscoped `@AppStorage` (negative-tested). Verified: validator + tooling tests pass.
- **Slice 8 ✅** — `DataModel.enqueuePersistence` chains trade and trading-info saves so they finish in submission order (each save replaces the stored portfolio). `AppDelegate.applicationShouldTerminate` defers quit until `flushPendingPersistence()` completes or 5s elapse (`TerminationReply`). Verified: build, no new warnings; covered by full-suite run.
- **Slice 9 ✅** — Root cause was `refreshRatesFromConfiguredSource` stamping `lastRefreshTime = now` *before* fetching (as a throttle), so failed/unavailable refreshes read "Just now". Added `lastRefreshAttemptTime` for throttling; `lastRefreshTime` now only changes when rates are actually obtained (legacy success sets it explicitly; Folync uses `asOf`). Verified: `CurrencyConverterTests` 25/25 (1 new).
- **Slice 10 ✅** — Found persistence (`TradeDataService.deduplicatedTrades`) silently keeps only the first row per symbol, so a duplicate entry vanished after relaunch. Holdings editor now flags duplicates (red symbol, warning icon, explanatory tooltip) via `DataModel.hasDuplicateSymbol`; `StockStatusBar.syncSymbolItems` binds one item per symbol to the first row. Also fixed Aug H4: `StockMenuBarController.menuBarTrades` excludes blank rows, so "Add Holding" no longer creates an empty status item. Verified: `DataModelTests` 7/7 (2 new).
- **Slice 11 ✅** — `SWIFT_STRICT_CONCURRENCY = complete` added to project, app and test Release configurations (Debug already had it). Deleted the unused `Stockbar/Info.plist` (was copied as a stray resource) and never-loaded `Base.lproj/Main.storyboard`; added `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.finance` and `INFOPLIST_KEY_NSPrincipalClass = NSApplication`. Deliberately did not carry over `NSSupportsSuddenTermination`. Verified: Debug build; clean Release build succeeds with the same warning set as Debug; generated Info.plist contains the keys; Release bundle has no stray plist/storyboard. Backup of the original pbxproj at `/tmp/stockbar-review/project.pbxproj.bak`.
- **Slice 12 ✅** — `Logger.log/debug/info/warning/error/critical` now take `isolation: isolated (any Actor)? = #isolation`, check the level, evaluate the autoclosure in the caller's isolation and send only the `String` to the actor's private `write`. Call sites unchanged; laziness preserved. Verified: clean build warnings 574 → 100 (0 Logger races remaining); `LoggerTests` 5/5. Backup at `/tmp/stockbar-review/Logger.swift.bak`.
- **Slice 13 ✅** — New `StockbarNotificationPoster` (UserNotifications, requests authorization on first use, respects denial) replaces `NSUserNotification` in `CurrencyConverter`, `HistoricalDataCoordinator`, `ExportManager`. Deprecated `onChange(of:perform:)` and `activate(ignoringOtherApps:)` replaced. Removed 27 same-actor `await`s, 4 unreachable `do/catch` blocks, unused values; `getMemoryUsage` now checks the `task_info` result; Codable snapshot types exclude their session-only `id` from coding. Verified: full suite 372/372; clean build warnings 100 → 50 (remaining are Swift 6 region-isolation diagnostics — see Deferred).
- **Slice 14 ✅** — Found that Settings' portfolio "Day Gain" format was ignored and its preview didn't match the real title. New shared `PortfolioMenuBarTitleFormatter` (locale-aware) drives both; added an "Amount and Percentage" option as the default for users who never chose (preserving today's look); explicit Amount/Percentage choices now apply. Portfolio item honours the colour-coding preference and shows zero change neutral; "StockBar" → "Stockbar". Status items get tooltips and accessibility labels. Popover: price shown with currency (no `nan`), neutral `—` badge for unknown/unchanged, neutral colour for nil/zero P&L, locale date format, fuller exchange names (`SymbolMetadata.exchangeDisplayName`). Watchlist 👁 emoji kept (SF Symbol attachments don't tint reliably in status items). Verified: build, no new warnings; `PortfolioMenuBarTitleFormatterTests` 3/3.
- **Slice 15 ✅** — Main window restores its saved frame (`setFrameAutosaveName`) and centres only on first ever show. Sidebar is now a native `List(selection:)` `.sidebar` with Portfolio (Overview, Holdings, Alerts), Analysis (Performance, Risk, Allocation), Maintenance (Backups, Data Health, Diagnostics) and a single Settings entry — arrow-key navigation, VoiceOver selection state, and Risk/Allocation are highlighted when shown (the redundant "Explore" and "Tools" menus are gone). Refresh button shows a spinner, disables while running, supports ⌘R and shows when it was last requested. Verified: build, no new warnings. **Not visually verified** — the normal app is running and a second instance would share real data; needs a visual check (sidebar width, section headers, Light/Dark).
- **Slice 16 ✅** — `get_fetch_priority` rewritten without the bare `except:` and speculative comments; behaviour unchanged. Verified: python-tests pass.
- **Slice 17 ✅** — README now states Swift 5 mode with complete strict-concurrency checking (not "Swift 6"). Removed obsolete `Scripts/setup_and_run_tests.sh` and its mention in Development.md. Architecture documents the new freshness/backoff policy. FAQ/User Guide refresh and circuit-breaker sections rewritten to match the code (the documented "probe every 2 minutes" mechanism never existed). Verified: docs-check passes.

## Final verification (23 Sept 2026)
- `bash script/develop.sh checks` (SwiftLint, entitlements, Sendable allowlist, invariants incl. new #6, docs) — pass.
- Python offline tests and `Scripts/tests` — pass.
- Full XCTest: **375/375** (was 357; 18 new tests).
- Clean Debug build: **50 warnings** (was 574); Release build succeeds with strict concurrency.
- GUI changes (sidebar, popover badge/header/suspension notice, units editor) are build- and unit-verified only; a visual check in an isolated acceptance run is still needed.
- **Slice 18 ✅** — `CacheOptimizations.cleanArchiveCacheBySize` bridges to its serial queue with a continuation instead of `sync` inside `async` (Aug H5). New `Logger.post` (synchronous, level-checked, string built on the caller's side) replaces `Task { await logger… }` in `PortfolioCalculationService`, `DataCompressionService` and `PerformanceChartView` downsampling. `MemoryOptimizedDataModel` (with `isolated deinit`) and `PortfolioCalculationService` are `@MainActor`, matching their only callers. Deleted dead `PaginatedDataSource`/`OptimizedHistoricalDataProvider` (moved the used `ChartTimeRange.startDate()` to `Data/ChartTimeRange+StartDate.swift`) and the unreachable `ImportExportManager` + `DataModel.importPortfolio/exportPortfolio` — no callers, and it mutated main-actor `RealTimeTrade`s from an actor, wrote to the local store even while Folync was authoritative, and saved each trade twice. `PriceAlertService` returns its migration error from `performAndWait`. Holdings' read-only table now starts in your saved portfolio order (was always alphabetical, hiding Edit-mode reordering) until a column header is clicked. Verified: clean Debug build **0 warnings** (was 50); full suite 375/375; checks pass. `PortfolioCalculationTests` is `@MainActor` with synchronous `setUp`/`tearDown` wrapped in `MainActor.assumeIsolated` (async lifecycle methods added ~0.2 s per test; suite stays at ~6.6 s). Test code still has minor warnings (unused `longMessage` in `LoggerTests`; two `sending self` in `PortfolioCalculationTests` lifecycle).
- **Slice 19 ✅** — New `UKPriceScale` (one rule replacing three copies in `StockStatusBar`, `MenuPriceChartView`, `HistoricalDataManager`) and versioned `UKPriceSnapshotScaleMigrationService`, which rescales stored UK `PriceSnapshotEntity` rows relative to each symbol's newest snapshot, then `HistoricalDataManager.invalidatePriceData(for:)` reloads affected series; display guards remain as a logged safety net. Quote cache now at `~/Library/Caches/stockbar-cache/quote_cache.json` (acceptance-aware, passed via `STOCKBAR_CACHE_FILE`); the script moves a legacy `~/.stockbar_cache.json` once, only for the default path; backup/restore scripts use the new path and fall back to the legacy file. `ENABLE_HARDENED_RUNTIME = YES` for Release. Deleted unreachable `VolumeChartView.swift`. Found Holdings had no way to set watchlist-only (subtitle promised it): added an eye toggle plus help/accessibility labels on row actions. Found the dependency alert pointed at a non-existent interpreter setting: now shows the `defaults write … pythonInterpreterPath` command. User Guide and FAQ rewritten (the old guide listed four template tokens the app never supported). Verified: full suite 378/378 (3 new), python-tests 14 (1 new), tooling tests 17 (1 new), docs-check pass, 0 app warnings.
- **Slice 20 ✅** — Rendered Overview, Holdings (light/dark), Risk, Settings and two popover states offscreen with synthetic data via a temporary XCTest (removed afterwards). Findings fixed: per-symbol popover computed period P&L from a flat placeholder chart (always +£0.00) — `MenuChartViewModel.hasStoredHistory` now gates it and the tile falls back to "Today's P&L"; `DataModel` creates the pure `PortfolioCalculationService` in `init` (it was created in a deferred `Task`, so totals briefly fell back to $0.00/+0.00%); Holdings P&L cells and Total Net Gains card are neutral at zero; watchlist rows show "—" instead of $0.00 value; Risk shows "Not enough history" instead of "Calculation Error". Left as-is: the popover's one-decimal compact amounts (deliberate and pinned by `testMenuPopoverFormatterUsesCurrencySymbolsAndGroupingForCompactAmounts`) and the nested Settings sidebar (existing embedded-settings design). Verified: full suite 378/378, checks, python and tooling tests pass, 0 app warnings.
- **Slice 21 ✅** — UI/UX modernisation. Found and fixed during on-screen verification: pages without their own scroll view (Holdings, Diagnostics) took their ideal height inside `NavigationSplitView` and overflowed the window; the detail column now pins each page to its size, and the window's hosting controller only enforces minimum size. The portfolio chart view model keeps the current chart during same-period reloads (no spinner flash on each refresh). Popover curves use a Catmull-Rom spline (the old flat-tangent curve rippled on dense series). The stock popover now shows exact amounts, matching the portfolio popover; the compact formatter and its test are unchanged. The editing table no longer hides row actions behind a horizontal scroll at the default window size (P&L columns stay in the read-only table). Verified: full suite 378/378, checks, docs-check, 0 new warnings; every section captured on screen in light and dark from the isolated test host; the relaunched normal app driven through the Accessibility API (Overview ranges, Holdings Edit/Done, Add Alert sheet, Settings tabs and cross-links, refresh). Popovers were checked in renders only: macOS showed no Stockbar menu-bar items on this machine, before and after the change. Note: capturing real windows from the test host overwrote the saved main-window frame in the standard defaults (`NSWindow Frame StockbarMainWindow`).
