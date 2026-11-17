# StockBar v3.8.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-17

Stockbar uses less memory and less processor time. It idles in about a fifth less memory, loads its price history at launch in about half the time, and spends about half the processor time on each price refresh. The Python helper that fetches prices now quits when it has been idle for 90 seconds. The figures it shows, the Python pins and the database model are the same as in 3.7.0.

## After updating

- **The Python helper now quits when idle, by default.** **Settings → Advanced → Memory → Quit Python Helper When Idle** is on unless you turn it off. The helper holds 70 MB or more. With the switch on it quits about 90 seconds after its last request, and each refresh starts it again, at about a third of a second of processor time. Turned off, it stays running for 15 minutes after its last request, as in 3.7.0. While markets are open and Stockbar refreshes every minute, it keeps running either way. If you turned the switch off in a testing build, it stays off.
- This version arrives through the updater in 3.7.0. Nothing needs doing by hand, apart from allowing Keychain access once after the update, as before.

## Memory and speed

These figures come from the project's benchmark on one Mac, with a made-up portfolio and live price providers turned off. Each change was measured on its own against the version before it, and the first group was also measured together against 3.7.0 on 2026-11-13. The record is in [EXPERIMENTAL_LOG.md](https://github.com/jayjay181818/StockBar/blob/main/EXPERIMENTAL_LOG.md).

- **Idle memory** is about 20% lower: 95.8 MB against 119.9 MB in 3.7.0. That comparison covers the memory and history changes; the refresh changes further down were measured one by one.
- **Stored history** is read in batches, away from the main thread, and without each snapshot's positions where they are not needed. Launch to history loaded took 0.63 s against 1.20 s, the benchmark's peak memory during launch is 40 MB lower, and the launch uses about 29% less processor time.
- **Each portfolio snapshot** keeps its positions in a compact sorted array, and the price history held in memory is kept in arrays sized to fit.
- **Price refreshes** apply all their quotes together, so the main window redraws once per refresh rather than once per symbol. Over four refreshes the app used 3.4 s of processor time against 6.8 s. The processor wakes about a third more often during them, because the figures now get to roll to their new values.
- **The Python helper** reads and writes its quote cache once per refresh rather than once per symbol: for 22 symbols, 2 reads of the cache file against 66, and 2 forced writes to disk against 44.
- **A symbol's price history** is read only for the time window asked for. The day reads at launch took 11 to 14 ms against about 410 ms.
- **History cache files** are no longer rewritten when their value has not changed.
- **The portfolio popover** releases its content when it closes, so it is no longer redrawn and its chart reloaded at every refresh while nothing is on screen.
- **The session's portfolio snapshots** no longer carry a price for every position, which nothing read. That is up to about 2.3 MB less over a long session with 11 positions, worked out from the sizes of the data.
- **Release builds** no longer contain test-coverage counters, which made the app's executable 6.7 MB larger.

## Settings

- **Settings → Advanced → Memory → Quit Python Helper When Idle**, described above. On by default.
- **Settings → Advanced → Memory → Roll Digits When Figures Change.** Figures in the main window and the popovers roll to a new value, as before. macOS keeps the digits it draws for this in memory: 6 to 10 MB after the main window's figures have rolled. Turned off, figures change without rolling and that memory is not used. On by default.

## Updates

- **Settings → General → Updates** has a third channel, **Experimental**, beside Stable and Testing. It offers builds of the `experimental` branch, which is used only for major changes, such as an overhaul of the app, or for temporary testing. It can go quiet for long periods, and things may break on it. A release or a testing build reaches it once that branch includes it.
- Experimental builds are listed in a feed of their own, so they never appear on Stable or Testing.

## Fixes

- The popover charts no longer draw their line doubling back to the left either side of a gap in time, such as the night between two trading days.

## For developers

- `Scripts/perf/` holds the benchmark: launch, idle and refresh workloads on made-up data, run in turns with `compare.sh`, and a report of each metric's change and whether it is more than run-to-run noise. See `Scripts/README_PERFORMANCE.md`.
- `EXPERIMENTAL_LOG.md` records each change of this release with its before and after figures, tests and review, the ideas tried and rejected, and an evaluation of moving parts of the app to Rust. None was moved.
- `script/package_release.sh` refuses to package an app built with test-coverage counters.
- Branches: ordinary changes go through pull requests into `testing`. `experimental` is used only for major changes or temporary testing. See "Branches, releases and dependencies" in `Docs/Development.md`.
