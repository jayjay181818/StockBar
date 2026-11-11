# StockBar v3.5.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-11

A large maintenance release from a full audit of the app. It corrects figures that were wrong, stops the database growing without limit, makes refreshes cope with slow or failing providers, and moves the market-data API keys into the Keychain. The Python pins are the same as in 3.4.0, and the database model is unchanged.

## After updating

- **API keys**: the Financial Modeling Prep and Twelve Data keys move from the settings file to the Keychain the first time they are needed. macOS may ask for Keychain access once; choose **Always Allow**. If the move fails, the keys stay in the file and keep working.
- **Database**: about once a week Stockbar saves a copy of the database, then thins old history: price rows older than 31 days to one per symbol per day, portfolio snapshots older than 90 days to one per day, and prices of symbols not held for 90 days. The space is reclaimed at the next launch.
- **Risk figures will change**: Sharpe and Sortino now use one 4% risk-free rate, weekends are left out of daily returns, and per-stock metrics use daily closes.

## Figures

- Attribution converts every snapshot to the current currency, so an old snapshot in another currency no longer inflates the start value. The waterfall shows the ten largest moves in either direction, and "top contributors" lists only holdings that gained.
- The Risk tab needs at least 20 trading days, says how many days its figures rest on, and shows a dash where a figure cannot be worked out. The beta card, which was never calculated, is gone.
- A holding with too little shared history is left out of the correlation section and named, so the rest still shows.
- No portfolio snapshot is recorded until the portfolio source is known, which stops snapshots that were missing positions.
- The per-stock popover and chart "Your Position" use Folync and Trading 212 figures instead of recalculating them. The menu-bar change is labelled **24h**, and titles dim and show their age when a price is stale.
- The P/L label reads GBP, not GBX, before the first quote.

## Refresh and market data

- A failed fetch no longer marks the old price as fresh. Failed refreshes are shown, with a separate "last tried" time.
- Each symbol has its own deadline, so one slow symbol no longer discards the whole batch. A provider-wide failure causes one shared back-off, not an hour's suspension of every symbol.
- Errors report the real cause, so a rate limit no longer reads as a bad ticker.
- Quotes refresh every 30 minutes while London and US markets are shut, and Stockbar refreshes when the Mac wakes.
- Previous close is right after the exchange date rolls over. Candles use unadjusted prices like the line charts. Long history requests use daily bars.
- The Stooq and Yahoo v7 fallbacks, which no longer work, are removed. Twelve Data pauses for a minute after a rate limit.
- A missing Python interpreter is shown in Data Health.

## Storage

- Price rows are written only when the price changed or an hour has passed; before, 62% of rows repeated the previous price.
- Trades are updated in place, not deleted and reinserted on every refresh.
- Failed history saves are kept and retried. A failed database load reports an error instead of crashing on the first save.
- Resetting preferences no longer deletes stored portfolio snapshots.
- Database safety copies are capped, and backups are written atomically. The backup and restore scripts include broker links, alias records and Folync data.
- The database's change history is trimmed daily while the app runs.

## Menu bar and charts

- Quit from the portfolio popover no longer hangs.
- Zoom narrows the date range (1x to 10x) and Option-drag pans. Volume, RSI and MACD panels line up with the price chart. More than 400 candles merge into weekly or longer candles.
- Comparison mode keeps the chosen stock and one currency. The gains chart draws its zero line. Chart type and range are remembered.
- Popovers close on Esc, on switching app and on changing Space. A hidden portfolio value stays hidden from the tooltip and VoiceOver.
- Chart PDF export includes the chart and uses the Mac's default paper size.

## Main window and settings

- The Alerts page says when notifications are denied, and alerts can be edited. An alert no longer fires again at every launch.
- Moving or removing a holding while a field is focused no longer resets the wrong row. Add Holding scrolls to the new row.
- **Clear Credentials**, **Use Local Portfolio**, **Disable Folync** and turning on **Delete linked manual holdings missing from Trading 212** ask for confirmation.
- Backups report "nothing to back up" separately from a failure. Restore shows progress and a result.
- The Risk tab keeps the previous figures on screen while it recalculates.
- Errors are no longer shown by colour alone, and money is formatted one way across the holdings table, Risk and Attribution.

## Trading 212 and Folync

- A Trading 212 sync is skipped while Folync supplies the portfolio, so it can no longer drop links. Its back-off survives internal restarts, and scheduled-sync failures show in Data Sources and the sidebar.
- A damaged broker links file is reported by name and left untouched.
- The Folync token is stored with its server and is only sent to that server. It can be removed with **Remove Token**.
- Folync shows "Offline" only when the server did not answer, and the Connecting flicker on every poll is gone.

## Security and export

- The FMP and Twelve Data API keys are kept in the Keychain and handed to the Python helper for each run.
- A settings import brings numbers into range, never turns on delete-missing, and refuses a file over 1 GB before reading it.
- Decrypted database copies left in staging are removed at launch.
- Log redaction covers more key, token, cookie and password forms, and the home folder is written as `~`.
- The Python helper runs with a minimal environment and reads only the settings file the app names.

## Logs

- Folync poll lines, which were 57% of the log, are cut to one warning on failure and one line on recovery.
- Timestamps carry milliseconds and a UTC offset, and the build version is logged at launch.
- The Debug Logs window is cheaper to open, honours Max Lines, and exports all three log files.
- Other apps' memory pressure no longer empties Stockbar's caches.

## Development

- About 3,900 lines of unused code removed. The cache layer, the two largest files and the chart source selection are simpler.
- 639 Swift tests, running in about 20 seconds, and 66 Python tests.
- CI builds the Release configuration, limits its token to read-only and keeps test results on failure.
- New `script/release.sh`, a coverage summary and `SECURITY.md`.

## Not yet checked in the running app

The suite and repository checks pass, but these were not looked at by eye before release: the first launch that moves real API keys to the Keychain, the main-window and settings changes, the Risk tab while recalculating, the delete-missing confirmation, and PDF export on A4.

## Comparison basis

These notes cover the changes on `testing` after tag `v3.4.0`: pull requests #46 to #66.
