# StockBar v3.6.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-11

The rest of the audit work, plus faults found by running 3.5.0 against live Folync and Trading 212 data. Short-range charts no longer waste width on nights and weekends, a cost entered in another currency is converted before gains are worked out, and a ticker renamed by Trading 212 can no longer cause a holding to be deleted. The Python pins and the database model are the same as in 3.5.0.

## After updating

- **Trading 212 links**: each link gains the instrument's ISIN at the next sync. Nothing needs doing.
- **Gains may change** for a holding whose cost was entered in a different currency from its quote (a US share costed in pounds, or a cost marked `GBp`). The old figure treated the cost as if it were in the quote currency.
- **Attribution may change**: holdings opened or closed inside the period are now counted.
- **Estimated history**: days of estimated portfolio history are recorded only when at least 90% of the portfolio by value has a price, so some thinly covered days no longer appear.

## Charts

- On the **1 Day** and **1 Week** ranges, the line chart draws nights and weekends narrow, so the hours with prices fill the chart. The week chart has one label per day and the day chart labels round times. Hover, selection and zoom follow the chart as drawn. Longer ranges, comparison charts and candlesticks are drawn to scale as before.
- Money on the chart is written the same way as in the holdings table. On a UK-region Mac a dollar figure used to read `US$1,234.56` on the chart and `$1,234.56` in the table.
- A portfolio chart opened before Folync connected no longer keeps the local series under the Folync caption.
- The chart shows a loading state while Folync history is requested, and leaves pence off a wide value axis.
- A chart drawn before the database has loaded no longer records an empty portfolio. That forced a full five-year history rebuild at every launch.

## Figures

- A cost entered in a different currency from the quote is converted to the quote currency, in one shared place, before gains are worked out.
- Attribution measures each holding from the first to the last day it was held in the period, and says which days it measured and that exchange-rate moves are not included.
- The Risk series holds a holding flat across a one-day price change of more than four times or less than a quarter, which is a split or a pence-for-pounds slip, not a return. The Risk tab says where its figures come from.
- A Trading 212 row's day profit is shown in that row's own currency.
- Estimated portfolio history uses the latest price on or before each day, at most 10 days old. It used the nearest price within 30 days either side, which could be a later price.
- History checks and estimates read prices stored under a symbol's earlier names.
- A Folync cost in pence stays pence, and a broker amount in pence is divided before conversion.
- Volatility, Sharpe ratio, value at risk and win rate are worked out by one piece of code for the portfolio and for each holding.
- **Total P&L** says, when hovered, that it is the unrealised gain against average cost.

## Trading 212 and Folync

- A linked position that vanishes while a new one with the same ISIN, or the same size, appears is treated as a rename: it is reported as missing and never deleted, even with **Delete linked manual holdings missing from Trading 212** on.
- Folync exchange rates dated up to four days apart are used as one set, dated by the oldest. They were rejected whenever the days differed.
- A quote fetch started before Folync became active no longer overwrites Folync's prices for the first minute after launch.
- Folync dates and reason codes are shown in readable form.

## Start-up and storage

- An unreadable alias-recovery file is named in the error and set aside once a backup is restored, so it no longer fails every launch unexplained.
- The automatic backup waits for a slow first load instead of giving up after 15 seconds. **Last Backup** updates when an automatic backup completes.
- The runtime monitor no longer counts an old traceback as a current error.

## Main window

- New **View** menu with ⌘1 to ⌘9 for the pages of the main window, and a **Help** menu for Data Health, Diagnostics and the log files.
- **Add Holding** appears only when holdings can be edited, and **Activate Folync** says why it is disabled.
- Average cost in the holding detail is formatted like the price above it.
- Data Health reports hidden menu bar items and Folync's own refresh interval.
- More decorative icons are hidden from VoiceOver. On the 1 Day and 1 Week charts VoiceOver reads the chart summary rather than individual points.

## Development

- Every Python package is locked to an exact version with checksums (`requirements.lock`). Stockbar's own environment and CI install from the lock. A weekly workflow opens a pull request that moves the lock to releases at least a week old.
- CI runs on Xcode 27 as well as Xcode 26, and its actions are pinned to commit hashes.
- A new test builds a database from each of the eight shipped model versions and opens it with the current one. Another runs a whole refresh pass against a fake network.
- `PerformanceChartView.swift` (2,396 lines) and `HistoricalDataManager.swift` (2,887 lines) are split by concern; the code was moved unchanged.
- 658 Swift tests and 96 Python tests.

## Looked at and left alone

- **Exchange rates in Attribution and Risk** are still today's rates. Using the rate of each day needs past rates stored beside each day's prices.
- **`fast_info` for quotes**: it has no market state or pre-market and post-market prices, which Stockbar shows.
- **Marking estimated history days** and **dropping the unused symbol index** both need a new database model version.
- **Day boundaries in the Mac's time zone**: changing them would re-file every stored day.
- **The Trading 212 account identifier** stays an unsalted hash: salting it would change the name every existing link is filed under.

## Not yet checked in the running app

Checked by eye against live data: the 1 Day and 1 Week charts, chart money, hover on the squeezed axis, the View and Help menus, the start-up fixes and cost conversion. Not checked by eye: box selection and zoom on the squeezed axis, the ISIN being filled in by a real Trading 212 sync, the Total P&L hover text, a full VoiceOver pass, the menu-bar popovers, and PDF export on A4.

## Comparison basis

These notes cover the changes on `testing` after tag `v3.5.0`: pull requests #69 to #76.
