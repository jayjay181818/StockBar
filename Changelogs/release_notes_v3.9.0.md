# StockBar v3.9.0 Release Notes

**Status:** Implemented  
**Date:** Not set until the release

Stockbar has a new look throughout: a see-through window with a floating sidebar, new cards on every page, a new portfolio popover and a new Overview. There are four new pages: **Activity**, **Trades**, **Income** and **Calendar**. Holdings, Risk, Allocation, Charts, Data Health, Settings and Alerts have been reworked. A Trading 212 account that holds only cash now has a value. Idle memory is about where it was before the redesign.

## After updating

- **The keyboard shortcuts for pages have changed.** ⌘1 to ⌘9 follow the sidebar from the top: **Overview**, **Holdings**, **Activity**, **Alerts**, **Charts**, **Income**, **Calendar**, **Trades**, **Risk**. **Allocation**, **Data Health**, **Backups** and **Diagnostics** have no number now. Choose them in the sidebar or the **View** menu.
- **Performance is now called Charts.** It is the same page.
- **In Holdings, clicking a cell no longer switches between amounts and percentages.** Use the **Amounts / Percent** switch beside the search field.
- **With a Folync portfolio, the Calendar sends ticker symbols to Yahoo.** To find earnings dates, Stockbar sends the holdings' ticker symbols to Yahoo, but no amounts or units. **Calendar** asks when you open it and when you click its refresh button, never on its own. The Folync **Income** page asks Yahoo nothing, and **Next up** asks nothing.
- **The three new Folync pages are on by default.** Settings → **Connections** → Folync has a checkbox for each: **Income**, **Trades** and **Activity**. Turning one off or on asks Folync nothing.
- This version arrives through the updater. As before, allow Keychain access once after the update.

## What each portfolio source gets

| Page or feature | Folync | Local | Trading 212 |
|---|---|---|---|
| **Activity** | Yes | No: needs Folync | No: needs Folync |
| **Trades** | Yes | No: needs Folync | No: needs Folync |
| **Income** | Folync's figures | An estimate from Yahoo, labelled as one | An estimate from Yahoo, labelled as one |
| **Calendar** dividends | Folync's dates | The Income estimate | The Income estimate |
| **Calendar** earnings | From Yahoo | From Yahoo | From Yahoo |
| Overview card of what the total is made of | Yes, when Folync gives all four figures | No: a summary table | No: a summary table |
| **Allocation** Cash row | Yes, when the figures add up | No | Yes, when the figures add up |

Activity and Trades need Folync because only Folync knows each transaction and when you bought and sold. For a local or Trading 212 portfolio their sidebar entries are dimmed.

Stockbar reads Folync and changes nothing in it. Transactions are added and changed in Folync itself.

## The window and the sidebar

- The window is see-through: you see a blurred, tinted view of what is behind it. **System Settings → Accessibility → Display → Reduce Transparency** makes it solid, and **Increase Contrast** outlines the sidebar. Motion follows **Reduce Motion**.
- The sidebar floats in its own panel on the left. It groups the pages under **Portfolio**, **Analysis** and **System**. On macOS 26 and later the panel is glass; on earlier versions it is a system material with a hairline edge.
- Hide the sidebar with **View → Hide Sidebar** (⌃⌘S) or the sidebar button next to the window's close, minimise and zoom buttons. The page then takes the whole width, and Stockbar remembers your choice.
- With the sidebar in focus, the Up and Down arrows move through it, and Home and End go to the first and last page.
- The bottom of the sidebar says where your portfolio comes from and when prices last updated, with a refresh button (⌘R). If Folync stops answering while Stockbar shows the figures it saved, it turns amber and says when those figures are from.
- The new pages are marked as new in the sidebar.

## Glass cards and memory

Every page draws its cards, panels, notices and switches the same way. Gains and losses use deeper colours in light mode, so figures stay readable on a light card. Under Increase Contrast every surface has a stronger outline, and under Reduce Transparency it is solid.

The switches inside pages, such as the ranges, are now one capsule control. The left and right arrows move the selection. The Charts page's switch between a line and a candlestick chart no longer has icons.

In the redesign's test builds, the faint highlight along the top of each card in dark mode cost about 18 MB of drawing memory. It is now drawn another way that looks the same and does not cost that memory. On the project's benchmark, with a made-up portfolio, idle memory is about 100 MB, against about 97 MB before the redesign. The record is in `EXPERIMENTAL_LOG.md`.

## The portfolio popover

- From the top: the total, its change over the chosen period, the chart, the range switch (**Today**, **1 week**, **1 month**), the movers for that period, and total return beside what it is measured against.
- On **Today**, a dotted line on the chart marks yesterday's close.
- The movers list follows **Today**, **1 week** and **1 month**. Week and month show the price change for each holding with sufficient history. The largest gain comes first, and unknown changes show “–”.
- The list shows as many holdings as fit below the menu bar. It scrolls when more holdings remain.
- For partial Folync portfolio history, the headline labels the change with the dates of the available values.
- **Next up** lists up to three dividend or earnings dates in the next 14 days. See [Calendar and Next up](#calendar-and-next-up).

## Overview

- The total is shown in large type, with today's change and the selected period's change beside it.
- There are six periods: **1D**, **1W**, **1M**, **3M**, **1Y** and **All**, for every portfolio source. With a local or Trading 212 portfolio the longer ones show what Stockbar has stored.
- The period's change is the last value in the chart less the first, so money paid in or taken out during the period counts in it.
- A change Stockbar does not know shows as "–", with the reason under it.
- With Folync, a card under the chart shows what the total is made of: **Net deposits**, **Unrealised gains**, **Realised gains**, and **Income, interest and fees**, which is the rest. The four figures always add up to the total shown. A figure Folync marks partial is labelled **Partial**. When Folync does not give all four figures in the portfolio's currency, the page shows a summary table instead.
- When Folync stops answering, an amber bar at the top says **Couldn't reach Folync** and when the figures were saved. If Folync answered but its figures could not be used, it says **Folync didn't send new figures**.
- The details for one position are still there, on a card of their own.
- **Next up** shows as up to three cards under the chart.

## Activity (new, Folync only)

- **Activity** lists every transaction Folync holds, newest first, under a heading for each month.
- Each row has the day, the kind of transaction, the ticker, the quantity and price as Folync gives them, and the amount in the portfolio's currency. Money in is green with "+", money out red with "−".
- The kind switches **Trades**, **Dividends**, **Interest** and **Cash** combine: click one to show or hide that kind, so one click hides the daily interest rows. Option-click a switch, or choose **Show Only** from its menu, to show that kind alone. **All** shows everything again, and Stockbar remembers your choice.
- **As entered** or **Adjusted** restates quantities and prices for splits and similar events. Search shows one holding, by its ticker.
- **Load more** fetches the next rows.
- The page asks Folync only when you open it, refresh it or load more, and reuses an answer from the last five minutes. If Folync is not answering, it shows a saved copy under an amber bar.
- With any other portfolio source the sidebar entry is dimmed with **Needs a Folync portfolio**.

## Trades (new, Folync only)

- **Trades** shows every position you have opened and how it did, as Folync works it out. Stockbar works none of these figures out itself.
- At the top: the win rate, how often a trade beat the S&P 500 over the same days, Folync's total gain on trades, open and closed, and this year's fees.
- The table lists each lot with its status, the day it was opened, the days held, its cost, gain and return, and the points it finished ahead of or behind its index over the same days.
- **All**, **Open**, **Partial** and **Closed** choose the lots. **Load more** asks for more rows.
- A card below shows a year's fees, what was bought and sold, and turnover, with a switch for earlier years.
- The page asks Folync only when you open it, refresh it or load more. If Folync does not answer, it shows the copy saved last time under an amber notice.
- For a local or Trading 212 portfolio the entry is dimmed.

## Income (new)

**With a Folync portfolio**, **Income** shows Folync's own figures: the dividends expected in the next 12 months, with the declared and estimated parts, the yield and the income received.

- A chart covers the six months up to this one and the six after it.
- **Outlook** lists the payments still to come, soonest first, with ex-dividend dates. **History** lists payments received, newest first. **By holding** sums each paying holding's payments over the chart's months.
- The chart's bars and the **By holding** sums are Stockbar's own sums of the payments Folync lists, and the page says so.
- **Declared** or **Estimated** beside a payment appears only when Folync says which.
- The page asks Folync when you open it and when you click its refresh button. Switching between the three views asks nothing, and opening it again within five minutes reuses the last answer.

**With a local or Trading 212 portfolio**, **Income** is an estimate, and says so at the top.

- It takes each holding's dividends over the last year as Yahoo records them, times the units you hold today. It is not a record of what was paid to you, because Stockbar does not know what you held on each date.
- **Outlook** repeats last year's payments a year on, each marked **Estimate**. Where Yahoo gives a real upcoming ex-dividend date, that date replaces the estimated one and is marked **Yahoo's date, amount estimated**.
- **History** lists the last 12 months' payments at today's units. **By holding** gives each holding's last and next 12 months.
- A holding with no payments shows **None**. Watchlist rows are left out.
- Amounts are converted only with exchange rates already loaded. A holding with no rate keeps its own currency, is left out of the totals, and the page says so.
- Yahoo is asked when you open the page and when you click its refresh button, never on its own. Its answers are kept for a day.
- The sidebar entry is dimmed when live market data is off, and while Folync is switched on but its portfolio is not showing yet. Calendar's entry is dimmed exactly when Income's is.

## Calendar and Next up

**Calendar** (new) shows dividend and earnings dates for your holdings, as a month grid and a list.

- **Upcoming** runs from this month to twelve months ahead, grouped **This week**, **Next week**, then by month. **Past** goes back twelve months, with the dividends and the earnings dates of those months.
- **All**, **Dividends** and **Earnings** choose what is shown, in either view.
- In the grid, an open circle is an ex-dividend date, a filled circle a payment, and a diamond earnings. An estimated date has a dashed outline. Click a day to mark its events in the list.
- **For a Folync portfolio** the dividends are Folync's, from the same answer as the Income page, marked **Declared**, **Estimated** or **Upcoming**.
- **For a local or Trading 212 portfolio** they are the Income page's estimate from Yahoo, and the page says so. Dates Stockbar estimated from last year are marked **Estimated**.
- **Earnings dates come from Yahoo** for every portfolio. A range of dates is marked **Estimated**. For a Folync portfolio, this means Stockbar sends the holdings' ticker symbols, not amounts, to Yahoo.
- Funds and investment trusts usually have no dates from Yahoo, so theirs are estimated from last year's payments and marked as such.
- The page asks when you open it and when you click its refresh button, never on its own. With Folync, opening Income or Calendar within five minutes of the other reuses the same answer.
- **Past earnings** show the reported and expected earnings per share and the surprise, exactly as Yahoo gives them ("Earnings, EPS 1.52 against 1.48 expected, surprise 2.70%"). Yahoo gives the figures in the company's reporting currency, which it does not name and which may differ from the share's price currency, so they are shown without a currency. **Settings → Advanced → Earnings Figures** lets you name a holding's currency ("EPS €0.27 against €0.28 expected") or hide its figures. Past earnings are asked for only while **Past** is shown, when you choose it and when you click refresh there, and an answer is kept for the rest of the day.

**Next up** in the portfolio popover and on the Overview lists up to three dividend or earnings dates in the next 14 days, soonest first. It reads only what Stockbar already saved for Income and Calendar, so opening the popover or the Overview asks nothing. It is absent until one of those pages has loaded, and when nothing falls in the next 14 days.

## Holdings

- **Settings → Appearance → Show company logos** displays available company logos on the left of the Instrument column and beside the ticker in the stock popover. This option sends visible symbols to Financial Modeling Prep and starts switched off.

- A new **Weight** column shows each holding's share of the portfolio. With Folync it is Folync's own figure. Otherwise it is the holding's value as a share of the **Net value**. A watchlist symbol, or a holding whose value is not known, shows "–".
- One **Amounts / Percent** switch sets both **Today** and **Total gain**, and Stockbar remembers it. The column that was headed Total P&L is now **Total gain**.
- The strip above the table shows the US-dollar figure on a second line, and **Total gains** says what they are for your portfolio source.
- A line under the table counts holdings and watchlist symbols and says which weight you are seeing.
- At the minimum window size, every column of the table now fits on its card, in both the read-only and the **Edit** table.

## Risk

- A strip gives volatility, the Sharpe and Sortino ratios, each with a reading from "Poor" to "Exceptional", and the worst fall from a peak.
- A new chart shows how far below its peak the portfolio stood each day, with the lowest point marked.
- "On a bad day" gives the 95% and 99% value at risk as a loss in the display currency.
- Then the falls of more than 5%, the downside deviation, and a footnote with the days, dates, method and risk-free rate behind the figures.
- Each figure is shown once. The figures themselves are worked out as before.
- **Fix:** the length of the worst fall was labelled in trading days. It is counted in calendar days from the peak to the low, and now says so. The number is the same.

## Allocation

- A donut sits beside its list. A switch groups it by sector, by holding or by currency. The currency view is new: it groups holdings by the currency each is priced in, even when Folync values it in another. Pence count as pounds.
- Past eight groups, the smallest share one "Other" slice.
- **A Cash row.** When your portfolio source gives its cash (Folync or Trading 212), each view has a Cash row and slice. Every share is then of the same total as Holdings' **Weight** column, so the two pages agree. A cash-only account is all Cash.
- There is no Cash row, and a line says the shares are of the holdings alone, when:
  - not every holding has a price yet;
  - the cash has no exchange rate;
  - Folync gives no total;
  - a Trading 212 account sits beside holdings kept outside it;
  - the holdings and cash do not add up to the source's total.
- Allocation converts only at exchange rates Stockbar has loaded, and works its figures out again as soon as rates arrive.
- The diversification score and concentration are shown once, in one card, with the recommendations under them.
- How the holdings move together is now a grid of correlations, for the twelve largest holdings.
- Four sector colours have changed, so that no slice reads as a gain or a loss.

## Charts and Data Health

- **Charts:** the chart picker and the range switch are on one row, and everything that changes how the chart is drawn is on one strip above it, on the same card as the chart. The controls no longer move down while a chart is loading or empty.
- **Data Health:** the tiles make full rows of three, or of two in a narrow window.

## Trading 212

- **A cash-only account now has a value.** An account with nothing linked, such as one holding only cash, is valued from its account summary on the usual schedule, when you have no holdings of your own in Stockbar. Holdings, the menu bar and the popover show its value, and Allocation shows its cash.
- Beside holdings you entered yourself, it is left out, and your own holdings' totals and weights stay as they are.
- With no rows to list, Holdings says its total is the Trading 212 account's value.
- Without a figure for the account's investments, the Overview shows its cost basis and unrealised P&L as unknown.
- **Fixes:**
  - Links in another environment or account type no longer count as links in the one in use.
  - The hourly check no longer stores figures that override holdings you entered yourself.
  - While a Folync portfolio is active, no Trading 212 figure is used.
  - Changing or clearing the credentials, switching Trading 212 off, or choosing another environment or account type now drops the old account's figures at once. They used to stay on screen for up to 20 minutes.

## Settings and Alerts

- Settings → **Connections**, from the top: **Market-data keys**, the Folync card, the Trading 212 card and **Fetch order**. Market-data keys used to be called API Keys, and Fetch order used to be called Fetch Priority.
  - **Market-data keys** has one row each for the FMP and Twelve Data keys, with the last test's result beside **Save & Test**: **Verified**, **Verification failed** or **Not verified**, or **Not set** when no key is entered.
  - **Fetch order** lists the providers in the order Stockbar tries them. **Edit Order** changes it.
  - The Folync card says **Active**, or **Enabled** while Folync is switched on but not showing its portfolio, with a line giving the last and next check.
  - Under **What Stockbar reads from Folync**, the new **Income**, **Trades** and **Activity** checkboxes turn those pages' Folync data off and on. A page switched off says so the next time it is opened.
- Every Settings tab is now a set of cards that runs the full width of the page, like the other pages. VoiceOver reads each switch and menu by its own name, and each card's title is a heading.
- **Settings → Advanced → Earnings Figures** is new: see [Calendar and Next up](#calendar-and-next-up).
- **Alerts:** each row's condition icon sits in a tinted ring, grey when the alert is paused. The controls line up across rows, and the time an alert last fired is easier to read.
- **Diagnostics:** ordinary log lines are in the normal text colour, not the accent blue.

## Fixes

- When Yahoo's quote details failed for a London listing priced in pounds, its price could be treated as pence and divided by 100. Stockbar now reads the currency from the chart data instead.
- The Risk and Trading 212 fixes are listed in their sections above.

## For developers

- **Surfaces.** Views take every surface from `Views/StockbarDesign.swift` (`stockbarCard()`, `stockbarSurface(_:tint:)`, `stockbarInset()`, `stockbarPill()`, `StockbarMetricStrip`, `StockbarNotice` and the rest), which gives each a light and a dark value, a stronger one under Increase Contrast and a solid one under Reduce Transparency. `StockbarSurfaceStyle.resolve` holds the numbers. `Scripts/validate_invariants.sh` fails when a view outside the design file draws a surface from a raw system colour or material; a line that must keep its colour ends with a comment giving the reason.
- **The card highlight.** `StockbarSurfaceHighlight` draws the dark card's top highlight as a solid hairline under a gradient mask. A shape stroked with a gradient cost about 18 MB of idle `CoreAnimation` memory on the dark Overview.
- **Switches.** Range, period and mode switches inside pages are `StockbarSegmentedControl`. Pickers in Settings forms stay native.
- **Sidebar.** `StockbarMainSection.sidebarGroups` is the one list behind the sidebar, the **View** menu and ⌘1–⌘9. The panel is custom because macOS gives no floating sidebar in this AppKit-owned window. `stockbarSidebarPanel()` uses `glassEffect` only behind `#available(macOS 26, *)`, and `.regularMaterial` with a hairline from macOS 15.4 to 25. `StockbarSidebarFooterStatus.make` words the footer from status the app already has and makes no request.
- **Folync ledger routes.** Dividends, trade analysis and transactions are read by `FolyncSupplementalCoordinator.routeDividends`, `routeTradeAnalysis` and `routeTransactions`, with `loadMore…` for later pages. Models are in `Services/FolyncLedgerData.swift`, and the routes have their own `FolyncLedgerRoute` enum. `FolyncLedgerFetchPolicy` runs one request at a time across the three, lets identical callers share one, and reuses a first page for five minutes. Their settings on `FolyncSupplementalSettings` default to on. `FolyncSupplementalSettings` now decodes field by field, so settings stored by an older build still decode.
- **Yahoo events.** `get_instrument_events.py` asks Yahoo, through the pinned yfinance, for each symbol's instrument type, dividend, pay and earnings dates, and twelve months of dividends. `InstrumentEventsService` runs it only when `StockbarProviderAccessPolicy` allows the Python bridge, keeps each answer for a day, and makes no run for an hour after a rate limit. `PythonWorkerPool` runs it like the other helper scripts. The helpers now accept yfinance 1.8.0's `HistoryMetadata` mapping where they used to require a `dict`. Its `--earnings-history` mode gives each symbol's past earnings dates, with the reported and expected EPS and the surprise as Yahoo gives them, each date taken in the exchange's own time zone; `InstrumentEventsService.earningsHistory(for:forceRefresh:)` runs it only while the Calendar's Past view is shown, with copies of its own kept for the day. The helper no longer sends an `epsCurrency`; one in an older saved copy or fixture is read past.
- **Pages.** Income: `StockbarIncomeView` switches between `StockbarFolyncIncomeView` and `StockbarLocalIncomeView`; the estimate is `LocalIncomeFigures` in `Analytics/LocalIncomeEstimate.swift`. Calendar: `StockbarCalendarModel` is built from Income's own models, so one request serves both pages. Next up: `StockbarNextUpModel` reads saved data only. The Overview's composition card is `PortfolioTotalComposition`. The Earnings Figures choices are kept under `calendar.earningsFigures.v1`, only for holdings set away from As Given, and travel in a settings export, checked on import. Activity's kind switches are remembered under `activity.kinds`.
- **Settings.** Every tab is built from `StockbarSettingsPage`, `StockbarSettingsSection`, `StockbarSettingsRow` and `StockbarSettingsSwitchStyle` in `Views/StockbarDesign.swift`, in place of macOS grouped forms, which cap their width and ignore row backgrounds.
- **Valuation.** `DataModel.holdingsWeightBasis()` decides once where Holdings' total and cash come from, and `AllocationValuation` uses it with `DataModel.weighedPositionValue(for:in:)`, so Allocation and Holdings agree. `CurrencyConverter.convertWithLoadedRates` never uses a built-in fallback rate.
- **Trading 212.** A valuation stored with no position linked in the active account is marked `isAccountOnly` (`Trading212BrokerSyncPlanner.accountOnlyValuationSnapshot`), and `freshTrading212BrokerValuationSnapshot()` ignores it beside the app's own holdings.
- **Acceptance runs.** An explicit acceptance run may reach a Folync on this Mac (`127.0.0.1`, `localhost` or `::1`) and nothing else (`loopbackFolyncAllowed`, `authorize(_:endpoint:)`). Its bootstrap leaves the Folync settings in a seed file that the app adopts at launch (`StockbarAcceptancePreflight.adoptSeededSettingsIfPresent`). The `STOCKBAR_ACCEPTANCE_*` launch options set the appearance, the opening page, the currency, the minimum window size, the Calendar view, the Settings tab, the Earnings Figures choices for made-up symbols, and the portfolio popover. The events fixture (`STOCKBAR_ACCEPTANCE_EVENTS`) accepts only made-up symbols starting `FAKE`; the alerts fixture (`STOCKBAR_ACCEPTANCE_ALERTS`) shows made-up alerts that are never stored, checked or fired; the holdings fixture (`STOCKBAR_ACCEPTANCE_HOLDINGS`) starts a fresh copy on a local portfolio of made-up `FAKE` holdings. See `Docs/Development.md`.
- **Tests.** The sidebar footer's test accepts either wording of the minutes that the system's date formatter gives, which differs between systems.
- **Benchmark.** The timed comparison for the latest pull requests of the redesign is still owed. `EXPERIMENTAL_LOG.md` records each pull request of this release, 134 to 168, with its tests, review and known issues.
