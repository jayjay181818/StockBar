# StockBar v3.8.1 Release Notes

**Status:** Implemented  
**Date:** 2026-11-18

With Folync as the portfolio source, total P&L is now measured against the money you paid in, less what you took out, rather than against what the shares you hold cost. This release also fixes when "Updated" says a cached price was fetched, and saves price alerts' last checked prices less often.

## After updating

- **Total P&L changes for a Folync portfolio.** In the portfolio popover and the Overview summary it is now measured against **net deposits** by default. That is the figure Folync's web dashboard shows as "What if not investing". The figure will usually differ from the one shown in 3.8.0. To go back to the old figure, choose **Cost of Current Holdings** in **Settings → General → Measure P&L Against**.
- Local and Trading 212 portfolios are not affected.
- This version arrives through the updater. Nothing needs doing by hand, apart from allowing Keychain access once after the update, as before.

## Total P&L against net deposits

Total P&L used to be the market value of the shares you hold less what those shares cost. That leaves out cash, sales, dividends, interest and fees, so it is not what the account has made.

For a Folync portfolio, Stockbar now reads net deposits, the money paid in less the money taken out, from Folync's portfolio history. It measures the portfolio value against them, and that value includes cash. An example with invented amounts:

| | Amount |
|---|---|
| Net deposits | £8,800 |
| Shares, at market value | £8,000 |
| Cash | £1,600 |
| Portfolio value | £9,600 |
| What the shares cost | £7,500 |
| **P&L against cost of current holdings** | +£500 (+6.67%) |
| **P&L against net deposits** | +£800 (+9.09%) |

- **Portfolio popover:** **Total P&L** uses the basis you choose. The box beside it shows **Net Deposits** or **Cost Basis**, with its amount.
- **Overview:** when P&L is measured against net deposits, the summary adds **Total P&L** and **Net deposits** rows. It keeps **Unrealised P&L** and **Cost basis**.
- **Timing:** net deposits are read at launch and then at most every five minutes. Folync adds a new deposit to its history a minute or two after Trading 212 lists it. Until Stockbar reads it, which takes up to about ten minutes, the deposit counts as gain. **Refresh Now** in Stockbar's Folync settings reads it at once.
- **When Folync cannot give net deposits,** for example because its history is missing exchange rates for some transactions, or it cannot be read for fifteen minutes, total P&L is measured against cost basis and the popover box says **Cost Basis**.
- **No percentage** is shown when net deposits are zero or negative.
- **Not changed:** the menu bar item, which shows the day's change; the per-stock popovers; the Holdings table; the Performance charts; recorded history.

## Settings

- **Settings → General → Measure P&L Against:** **Net Deposits** (the default) or **Cost of Current Holdings**. It is included in Settings export.

## Fixes

- **"Updated" shows when a price was fetched.** The Python helper can serve a price it fetched a few minutes earlier, for example after **Refresh Now**. Stockbar used to stamp it with the time it received it, so "Updated" said "just now" and the history point was recorded at the later time. It now uses the time the price was fetched.
- **Price alerts** saved the record of last checked prices once for every alerted symbol whose price moved. They now save it once per refresh, and only when a remembered price changed.

## For developers

- `FolyncNetDeposits` (`FolyncSupplementalData.swift`) takes the last point of the `3m` history's `netContributionSeries`. `refreshFolyncNetDeposits(force:now:)` in `FolyncPortfolioSession.swift` reads it through `routePortfolioHistory` and never uses a history marked stale. `DisplayPortfolioSummary.totalReturn(measuredAgainst:)` chooses the basis; `totalGain` keeps its cost-basis meaning.
- Each quote from the Python helper carries `fetchedAt`, which its cache keeps.
- The locked Python helper packages were updated (pandas 3.1.1, platformdirs 4.14.5, soupsieve 4.0.1). The pins Stockbar checks at launch are unchanged.
- The docs were checked against the app: keyboard shortcuts, Trading 212 defaults, alerts, chart ranges and the Folync and exchange-rate intervals. The README links the [wiki](https://github.com/jayjay181818/StockBar/wiki).
