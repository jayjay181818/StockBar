# StockBar v3.8.2 Release Notes

**Status:** Implemented  
**Date:** 2026-11-18

With Folync as the portfolio source, the portfolio chart now appears at once, without waiting for Folync. When Folync doesn't answer, Stockbar now says so rather than asking for more stored history.

## After updating

- Nothing needs doing. Each chart period is saved the first time it loads after the update, so open **1 Week** and **1 Month** once and they show at once from then on.
- Local and Trading 212 portfolios are not affected.
- This version arrives through the updater. As before, allow Keychain access once after the update.

## The portfolio chart appears at once with Folync

The portfolio popover and the Overview used to leave the chart empty until Folync answered. Each time, Stockbar asks Folync whether the history for that period has changed.

- Stockbar now saves the history from Folync's last answer for each period, and draws it straight away, marked **Checking Folync**.
- When Folync answers, the chart and its label update. If nothing has changed, Folync answers with a short "not modified", and the same chart stays.
- A saved chart is drawn only if Folync answered or confirmed it in the last day. An older one waits for Folync, as before.
- Period P&L is not shown from a saved chart until Folync confirms it.

## When Folync can't be reached

If Folync doesn't answer, for example because the machine it runs on has stopped responding:

- **A period with a saved chart** keeps it, marked **Folync · stale cache**. The Overview's period change says **No current history from Folync**, where it used to say Folync marked the period partial.
- **A period with nothing saved** now says **Couldn't reach Folync** in the popover and the Overview, and next to the Overview's period change. It used to say there was not enough stored history, which pointed at the wrong cause.
- Stockbar counts as "couldn't reach" any request that got no answer at all, such as a timeout, a lost connection or a failed secure connection, and a 502, 503 or 504 from the server in front of Folync. If Folync answers with any other error, or with data Stockbar can't use, the chart still says the history is unavailable.
- **The log** gets one line when a period's history starts failing, with the reason, such as `timeout` or `http-503`, and one when it works again. The line names the period and the reason only, no address, token or amounts.

## For developers

- `FolyncSupplementalCoordinator.savedPortfolioHistory(range:maximumAge:now:)` reads the history saved from Folync's last full answer for a range, from disk, with no request or Keychain read. It is used only if Folync confirmed it, by a full answer or a 304, within `maximumAge` (one day). A 304 doesn't rewrite the file, so confirmations are kept in memory.
- `routePortfolioHistory` returns the new `FolyncRoutedPortfolioResult.unreachable` when the request fails with nothing usable saved and no HTTP response arrived (`FolyncRefreshSchedule.failureCategory` is `timeout`, `offline`, `unreachable` or `network-<code>`) or the response was 502, 503 or 504. Otherwise it returns `.unavailable`, as before. A usable saved history still comes back as `.folync(_, status: .stale)`, and `allowLegacyFallback` still returns `.legacy`.
- `PortfolioMenuChartViewModel.folyncUnreachable` and `folyncStale` drive the popover's and the Overview's wording.
- Not changed: the local day chart still reads stored history on the main thread, which takes about 30 ms.
