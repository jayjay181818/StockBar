# Stockbar experimental log

The record of the optimisation work on the `experimental` branch: the baseline,
what each pull request changed and measured, and what was tried and dropped.
It changes only through pull requests into `experimental`.

To resume this work, read this file and the open pull requests into
`experimental` before anything else. The rules of the branch are in
[How this branch works](#how-this-branch-works).

## Where things stand

Seven changes are merged, and the first milestone has been measured: see
the table below and [Milestone 1](#milestone-1-2026-11-12). The candidates
that remain are small or would change what the app does, so no further
optimisation is planned until the decisions below are made. One feature was
built at the owner's request and is open as pull request 97: an update
channel in the app that follows `experimental`.

- Release builds no longer carry test-coverage counters (pull request 85).
  The executable is 6.7 MB smaller and none of the fifteen measured rows
  moved.
- Stored portfolio history is read in batches (pull request 87). The peak
  memory of launch and history load is 16.4 MB lower: 267.4 MB against 283.8
  MB, measured in turns.
- Stored history is read at launch away from the main thread (pull request
  89). History is loaded 0.43 s sooner after launch, 0.60 s against 1.03 s,
  and the launch uses a quarter less CPU, 1.67 s against 2.23 s, measured in
  turns with the screen locked.
- Each portfolio snapshot's positions are kept in a sorted array instead of a
  dictionary (pull request 90). The memory the app holds allocated at idle is
  10.7 MB lower, 52.2 MB against 62.9 MB, and idle memory is 14.2 MB lower,
  95.8 MB against 110.0 MB, measured in turns.
- The chart of the portfolio's value reads stored history without each
  snapshot's positions (pull request 92). Its read of a week of history
  takes 2 ms against 24 ms, each time the chart reloads. None of the fifteen
  standard rows moved.
- The price history held in memory is kept in arrays sized to their points
  (pull request 93). Those arrays hold 5.25 MB against 8.69 MB, 3.44 MB
  less, in every launch.
- The popover charts no longer draw their line doubling back to the left
  either side of a gap in time, such as the night between two trading days
  (pull request 95). A bug fix, not an optimisation: the benchmark does not
  run its code, and no row moved in both of the two runs made for it.

Waiting for a decision:

- Pull request 97, the Experimental update channel. Merging it is itself a
  push to `experimental`, which the workflow it changes would build, sign
  with the update key and publish as a public prerelease, and so would every
  merge after it. That is distributing a build, so it waits for the owner's
  explicit word.
- Pull request 86, where the idle Python helper exits after 90 seconds. It
  trades memory for CPU.
- Pull request 94, where `script/package_release.sh` refuses to package an
  app built with test-coverage counters. It changes the release packaging
  step, and it has to reach `testing` and `main` together with pull request
  85's scheme change: without that change every build carries the counters
  and would be refused.
- Whether the market data fetch should leave Python. The
  [Rust evaluation](#rust-evaluation-2026-11-12) sets out the options; no
  component was moved to Rust.
- Whether to promote `experimental` to `testing`. The recommendation and
  what it does not cover are at the end of
  [Milestone 1](#milestone-1-2026-11-12).
- Whether the rolling digits of the main window's figures are worth about
  6 MB of cached glyphs after a launch that opens the window at once. See
  "What the idle memory is made of" under
  [Milestone 1](#milestone-1-2026-11-12).

This comparison is re-measured, baseline commit against the head of
`experimental` in turns on the same day, at each milestone. Figures from
different days are not set side by side, because the machine's state drifts.

Milestone 1 was measured on 2026-11-12 with `experimental` at `c4f4cff`, six
launches a side in turns. The head since then, `c3c21ec`, adds only pull
request 95, whose code the benchmark does not run. These are the rows that
moved. The full table, the soak runs, what the idle memory now consists of
and what is left are under [Milestone 1](#milestone-1-2026-11-12).

| Metric | Baseline `47c1bda` | `experimental` at `c4f4cff` | Change |
| --- | --- | --- | --- |
| Idle memory (physical footprint) | 121.5 MB | 98.3 MB | -23.2 MB, -19.1% |
| Idle memory the app holds allocated | 60.4 MB | 54.0 MB | -6.4 MB, -10.5% |
| Peak memory, launch and history load | 281.1 MB | 244.4 MB | -36.7 MB, -13.0% |
| Launch to history loaded | 1.88 s | 0.72 s | -1.15 s, -61.3% |
| CPU from launch to the idle window | 2.46 s | 2.07 s | -0.39 s, -16.0% |
| CPU energy from launch to the idle window | 7.76 J | 6.37 J | -1.39 J, -18.0% |

Idle CPU, wake-ups, idle CPU power, disk writes and the three Python helper
rows did not change measurably. Launch to first window came out "possibly
lower", 0.61 s against 0.97 s (p = 0.024), which does not count without a
repeat.

### Breaks in the measuring environment

Figures from either side of a break are not compared with each other.

- 2026-11-12, macOS 27.2 to 27.2.1. The Mac installed the update and
  restarted at 08:58 UTC, after the baseline and before pull request 85.
  `experimental` at `4f475ea`, whose app sources are the baseline's, was
  measured again after the update: it is the "before" column of pull request
  85. With the same app, launch to first window was 0.99 s against 1.38 s the
  night before and launch to history loaded 1.64 s against 2.34 s. Idle
  memory, allocated heap and peak memory were 2 to 3 percent higher and idle
  CPU 14 percent lower. A figure is therefore read against the "before"
  column measured beside it, never against the baseline table.
- 2026-11-12, from some time between 11:09 and 11:23 UTC until some time
  between 12:13 and 12:33 UTC: the Mac's screen was locked and its display
  mostly asleep, because its owner was away. The comparisons of pull requests
  85 to 87 ran unlocked with the display awake; pull request 89's ran locked;
  pull request 90's ran unlocked again, with the display awake for all twelve
  launches. Both sides of a comparison are still measured under the same
  conditions, in turns. Locked, the build that showed its first window in
  0.58 s in pull request 87's comparison shows it in 0.42 s, draws 1.4 mW of
  idle CPU power against 4.5 mW, and uses 0.16 s/min of idle CPU against
  0.08. A figure from a locked comparison is therefore not set beside one
  from an unlocked comparison.

### Milestones

| Milestone | State |
| --- | --- |
| `experimental` created, earlier work moved onto it | Done 2026-11-11 |
| Benchmark procedure and baseline in the repository | Done 2026-11-12, pull request 84 |
| Carried-over changes re-measured and merged one by one | Done 2026-11-12, pull requests 85 to 93. Pull requests 86 and 94 are open for a decision |
| Stage 3 changes | Done 2026-11-12. Plan items 8, 9, 11 and 12 were measured and none gave a change worth making; pull request 88 records the Rust evaluation |
| First checkpoint tag and soak run against the baseline | Done 2026-11-12: [Milestone 1](#milestone-1-2026-11-12), tag `experimental-checkpoint-2026-11-12-milestone-1` |
| Recommendation to promote to `testing` | Made 2026-11-12, at the end of [Milestone 1](#milestone-1-2026-11-12). Nothing is promoted until the owner asks for it |

### Planned next, in order

1. Done in pull request 85: release builds without test-coverage counters.
   The branch also carried a check in `script/package_release.sh` that refuses
   an instrumented binary. That is a change to the release packaging step, so
   it came off the branch and is open as pull request 94 for a decision.
2. Open as pull request 86, waiting for a decision: the idle Python helper
   exits after 90 seconds. It trades memory for CPU, and its effect shows only
   on real data.
3. Done in pull request 87: portfolio history read in batches.
4. Done in pull request 89: stored history read at launch away from the main
   actor.
5. Done in pull request 92: the chart of the portfolio's value reads stored
   history without each snapshot's positions.
6. Done in pull request 93: price history arrays sized to fit.
7. Done in pull request 90: compact storage for the positions kept with every
   portfolio snapshot, which were the largest single block of the idle heap.
8. Measured, not pursued: the Python helper's start-up cost. The helper
   compiles its own three scripts at every start, because the app sets
   `PYTHONDONTWRITEBYTECODE`. Compiling them takes 8.2 ms in all
   (`get_stock_data.py` 7.5 ms, range 6.3 to 58.8 over 20 compiles; the other
   two 0.3 and 0.4 ms), of a start that takes about 330 ms. Shipping
   bytecode would save about 2 percent of the helper's start. Retiring the
   helper straight after a refresh is the trade of pull request 86 taken
   further, and waits on that decision.
9. Measured, nothing to change: the graphics memory of the first window (the
   result is at the end of this item). AppKit's Writing Tools check during
   launch was not looked into. Also why one and the same build idles near 105 MB after
   some launches and near 130 MB after others (see pull request 87). Across
   the 36 launches of the comparisons of pull requests 85 to 87, ten idled
   above 120 MB and 26 below, and the heap the app holds allocated was the
   same at both levels (medians of 61.0 MB and 61.8 MB). The extra 22 MB or
   so is therefore memory outside the allocated heap. The memory breakdowns
   saved with those launches show what it is: the small-allocation zone held
   101.0 MB at the high level and 79.5 MB at the low one, 21.5 MB apart, and
   apart from 1.6 MB of large allocations no other kind of memory differed by
   as much as 0.1 MB. So it is memory the launch freed that the allocator has
   not handed back, and the allocator does not hand it back on request (see
   "Tried and rejected"). In pull request 90's comparison that zone held 80.5
   MB against 62.9 MB allocated before, and 67.0 MB against 52.2 MB after.
   What is left to work on is therefore what the launch allocates at its
   peak: 250 MB, for 52 MB kept.

   The peak was then looked at directly. A launch of `c4f4cff` was captured
   at the moment its footprint passed 150 MB (it stood at 157.6 MB): 100.6
   MB of that was graphics memory the process owns for the first window,
   which is 48 KB once the app is idle, and 50.8 MB was the small-allocation
   zone, against 44.9 MB at idle. The heap held the same classes in nearly
   the same amounts as at idle. So the benchmark's launch peak is the first
   window being drawn, not the history load, and in normal use no window
   opens at launch. Pausing the app to capture it changed that launch: it
   peaked at 192.5 MB where undisturbed launches of the same build peak at
   242 to 247 MB. The capture therefore shows what the peak is made of, not
   its size.
10. Done in pull request 88: Rust evaluated, no migration recommended. See
    the [Rust evaluation](#rust-evaluation-2026-11-12).
11. Measured, not pursued. Seen while reading for pull request 93: after
    every recorded snapshot `cleanupOldData` thins every symbol's price
    series again on the main actor, which sorts and copies each one and
    works out the calendar day of every older point, and then keeps the
    result only if its length changed. The benchmark records no prices, so
    this was timed on a copy of the code compiled with `-O`: one pass over a
    store shaped like the benchmark's (22 symbols, 70,004 points) takes 32.6
    ms (30.0 to 40.6 over 200 passes). 27.3 ms of that is working out the
    calendar day of the 22,000 older points and 2.4 ms is sorting series
    that are already in order. At the default five-minute interval that is
    0.0065 s of CPU a minute while prices are being recorded, against 0.09
    s/min for the idle app. Doing only the work that can change anything
    means remembering how far each series has been thinned, and keeping
    that true at every place that replaces a series and in every time zone
    the Mac moves through. That is new state to get wrong, for about 2 s of
    CPU in a trading day.
12. Measured, nothing changed: why one and the same build holds about 6 MB
    more allocated after some launches than after others, and whether the
    main window's chart is the cause. It is not the chart. It is the
    system's cache of drawn glyphs, filled when the main window's figures
    roll in. See "What the idle memory is made of" under
    [Milestone 1](#milestone-1-2026-11-12).
13. Open as pull request 97, waiting for the owner's word: an update
    channel in the app that follows `experimental`, asked for by the owner
    on 2026-11-12. It is a feature, not an optimisation. Once merged, the
    release workflow builds and publishes each push to `experimental`,
    starting with the merge itself, which the rules of this branch do not
    allow without the owner's word. The builds go in an update feed of
    their own: the copy of `Scripts/release_feed.py` on `testing` and
    `main` refuses to rewrite a feed that holds a channel it does not know,
    so a shared feed would stop testing builds and releases from being
    published.

No further optimisation is planned until the owner decides about promotion
and about pull requests 86 and 94. What could still be done, and what each
would cost, is listed at the end of [Milestone 1](#milestone-1-2026-11-12).

## Baseline

Untouched `experimental` at `47c1bda`, which has the same files as `testing`
and `main` had on 2026-11-11 (release 3.7.0). Measured on 2026-11-11 between
23:08 and 23:54 UTC on an Apple M3 Pro with 18 GB, macOS 27.2, on mains
power. The display was awake and unlocked for every launch.

```bash
bash Scripts/perf/compare.sh experimental dd30bb3 --label baseline --rounds 2 --runs 4
```

A Release build runs in the isolated acceptance mode on synthetic data (11
holdings, 7,000 portfolio snapshots of 15 positions, 69,982 prices), with live
providers off. Each launch is left for 75 seconds and then watched for 60.
There were eight launches a side, taken in turns. The other side is `dd30bb3`,
the commit that adds the benchmark, whose app sources are the same. Its column
is therefore a second sample of the same app, and the difference between the
two columns is the noise of the method.

| Metric | Baseline: median (range) of 8 launches | The same app again | Difference |
| --- | --- | --- | --- |
| Idle memory (physical footprint) | 103.5 (100.0 to 114.9) MB | 104.5 (99.5 to 127.1) MB | none measurable (p = 0.645) |
| Idle memory the app holds allocated | 60.7 (59.7 to 61.7) MB | 60.4 (54.9 to 61.9) MB | none measurable (p = 0.817) |
| Peak memory: launch, first window, history load | 275.1 (272.8 to 292.3) MB | 282.6 (271.9 to 292.9) MB | none measurable (p = 0.328) |
| Idle memory growth across the 60 s window | 0.0 (-6.9 to 0.0) MB | 0.0 (0.0 to 0.9) MB | none measurable (p = 0.533) |
| Idle CPU | 0.100 (0.091 to 0.107) s/min | 0.103 (0.084 to 0.161) s/min | none measurable (p = 0.776) |
| Idle CPU wake-ups | 26 (23 to 28) /min | 26 (24 to 43) /min | none measurable (p = 0.667) |
| Idle CPU power | 4.43 (4.24 to 5.36) mW | 4.64 (4.22 to 6.80) mW | none measurable (p = 0.663) |
| Idle disk writes | 0.000 MB/min in every launch | 0.000 MB/min in every launch | none |
| Launch to first window | 1.38 (1.02 to 1.57) s | 1.21 (0.95 to 1.47) s | -0.17 s at p = 0.050: noise, see below |
| Launch to history loaded | 2.34 (1.74 to 2.81) s | 2.19 (1.68 to 2.72) s | none measurable (p = 0.342) |
| CPU from launch to the idle window | 3.07 (2.69 to 3.49) s | 2.75 (2.39 to 3.32) s | none measurable (p = 0.065) |
| CPU energy from launch to the idle window | 8.37 (7.69 to 9.80) J | 7.97 (7.17 to 10.12) J | none measurable (p = 0.442) |
| Python helper start to ready, no network | 0.35 (0.29 to 0.84) s | 0.39 (0.33 to 0.68) s | none measurable (p = 0.553) |
| Python helper start, CPU | 0.34 (0.29 to 0.49) s | 0.38 (0.32 to 0.42) s | none measurable (p = 0.311) |
| Python helper memory once started | 71.2 (71.0 to 71.3) MB | 71.2 (71.0 to 71.4) MB | none measurable (p = 0.959) |

What this says about reading later tables:

- The same binary idles anywhere between 100 and 127 MB from launch to
  launch, because the allocator keeps or returns memory freed during the
  launch. The allocated figure is far steadier, so a memory change shows there
  first.
- Launch times move by about 0.3 s either way between launches.
- One row of the fifteen separated the two sides at p = 0.050 although the app
  was the same. With fifteen rows that is expected in about half of all
  comparisons, so the report calls a row "lower" or "higher" only below
  p = 0.01 and marks anything between 0.01 and 0.05 as "possibly", to be
  repeated before it counts. A pull request also names in advance the rows it
  is meant to move.

Where the memory is, from the heap listing of one baseline launch (59.7 MB
allocated): the position dictionaries of the 7,000 portfolio snapshots 17.1
MB, the price history arrays 8.7 MB, allocations without a type name 12.9 MB,
Swift type metadata 3.4 MB. (MB is 1,048,576 bytes throughout, as the tools
report it.) Of that launch's 103 MB idle footprint, 75 MB is the
malloc heap and about 13 MB is graphics and window memory. The peak, about
275 MB, is reached before the idle window starts; this tooling does not yet
say what it is made of (item 9 of the plan).

### Soak: 30 minutes idle

One launch of the same build watched for 30 minutes, from 23:55 on 2026-11-11
to 00:26 UTC. This is too slow for every pull request and is run at
milestones.

```bash
bash Scripts/perf/benchmark.sh --skip-build --commit-label 47c1bda --label baseline-soak --runs 1 --window 1800
```

| Metric | Over the 30 minutes |
| --- | --- |
| Idle memory (physical footprint) | 103.1 MB over the first five minutes, 104.9 MB over the last five; lowest 101.9, highest 105.0 |
| Memory the app holds allocated, at the end | 60.3 MB |
| Idle CPU | 0.032 s/min |
| Idle CPU wake-ups | 27.7 /min |
| Idle CPU power | 0.43 mW |
| Idle disk writes | 0.001 MB/min |

Memory rose by 1.8 MB over the half hour, in steps. Whether it levels off
over hours is not measured. Idle CPU and power over the half hour are well
below the 60 second figures in the table above, because that window starts 75
seconds after launch, while the app is still settling: compare a soak with a
soak and a table with a table.

### Tests on the baseline

Run on 2026-11-12 on the tooling branch, whose app sources and tests are
those of `47c1bda`:

- `bash script/develop.sh test`: 682 XCTest tests, 0 failures.
- `bash script/develop.sh python-tests`: 66 Python helper tests pass.
- `bash script/develop.sh checks` and `docs-check`: lint, entitlements,
  sendable, invariant and agent-document checks pass.
- `bash script/develop.sh build-release`: the Release configuration builds.

Nothing fails on the baseline, so the bar for every later pull request is no
failures at all.

### Not measured

| What | Why not | What would fill the gap |
| --- | --- | --- |
| Whole-system battery drain | `powermetrics` needs administrator rights. The CPU energy figures above are the kernel's estimate for the process alone: no display, graphics processor or network | `sudo powermetrics --samplers tasks,battery -i 10000 -n 60` while the app idles |
| Frame-level smoothness and click-to-response time | Needs Instruments or instrumentation inside the app. Time to first window and launch CPU are the nearest figures here | Instruments (Time Profiler, Hangs, SwiftUI) against the Release build |
| A quote refresh over the network | Depends on the provider and the network, and the isolated benchmark has live providers off. The helper's start to ready, without the network, is measured instead | `bash Scripts/measure_performance.sh` against the running app, read together with the refresh lines in its log |
| How long the Python helper stays alive between refreshes, and app plus helper memory | The isolated benchmark never starts the helper. Measuring it means quitting the installed app and running a test build on real data, which is not done unattended | `bash Scripts/measure_performance.sh --duration 720` against a build of the commit |
| Memory, CPU and energy while the app is being used (charts, settings, scrolling) | Nothing here drives the interface. "Active" in the tables is the launch, the first window and the history load | Use the app while `measure_performance.sh` runs |
| Operation over hours with real refreshes | The soak run is 30 minutes, idle, in isolation, at milestones only | `bash Scripts/measure_performance.sh --duration 7200` on the installed app |

## Milestone 1, 2026-11-12

Every change merged so far, measured together against the baseline. The
comparison ran with `experimental` at `c4f4cff` (pull requests 84 to 93).
The head when this was written, `c3c21ec`, adds pull request 95, whose code
the benchmark does not run; the soak and the tests below ran on `c3c21ec`.
The checkpoint tag `experimental-checkpoint-2026-11-12-milestone-1` is on
the commit that merged this section, whose app sources are those of
`c3c21ec`.

### Comparison with the baseline

```bash
bash Scripts/perf/compare.sh 47c1bda c4f4cff --label milestone-1
```

Six launches a side in turns, from 15:21 to 15:53 UTC, on macOS 27.2.1 and
mains power, all twelve launches with the screen unlocked and the display
awake. The load average was 6.9 at the start, after waiting 140 s for it to
fall below 8.

| Metric | Before: median (range) | After: median (range) | Change | Verdict |
| --- | --- | --- | --- | --- |
| Idle memory (physical footprint) | 121.5 (100.2 to 132.8) MB | 98.3 (96.2 to 101.6) MB | -23.2 MB, -19.1% | lower (p = 0.009) |
| Idle memory the app holds allocated | 60.4 (59.6 to 61.7) MB | 54.0 (50.3 to 56.2) MB | -6.4 MB, -10.5% | lower (p = 0.002) |
| Peak memory, launch and history load | 281.1 (275.6 to 298.5) MB | 244.4 (242.1 to 247.3) MB | -36.7 MB, -13.0% | lower (p = 0.002) |
| Idle memory growth across the window | 0.0 (-9.1 to 0.1) MB | 0.0 (-3.2 to 0.1) MB | +0.0 MB | no measurable change (p = 0.939) |
| Idle CPU | 0.091 (0.089 to 0.101) s/min | 0.087 (0.068 to 0.095) s/min | -0.004 s/min, -4.4% | no measurable change (p = 0.292) |
| Idle CPU wake-ups | 28 (23 to 35) /min | 27 (25 to 32) /min | -0 /min, -1.8% | no measurable change (p = 1.000) |
| Idle CPU power | 4.41 (4.24 to 5.34) mW | 4.42 (3.92 to 4.78) mW | +0.01 mW, +0.2% | no measurable change (p = 0.937) |
| Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
| Launch to first window | 0.97 (0.66 to 1.39) s | 0.61 (0.46 to 0.86) s | -0.35 s, -36.3% | possibly lower (p = 0.024) |
| Launch to history loaded | 1.88 (1.32 to 2.55) s | 0.72 (0.60 to 0.83) s | -1.15 s, -61.3% | lower (p = 0.002) |
| CPU from launch to the idle window | 2.46 (2.33 to 2.86) s | 2.07 (1.92 to 2.16) s | -0.39 s, -16.0% | lower (p = 0.002) |
| CPU energy from launch to the idle window | 7.76 (7.07 to 9.20) J | 6.37 (5.34 to 6.79) J | -1.39 J, -18.0% | lower (p = 0.002) |
| Python helper start to ready, no network | 0.39 (0.28 to 0.64) s | 0.34 (0.30 to 1.14) s | -0.05 s, -14.1% | no measurable change (p = 0.777) |
| Python helper start, CPU | 0.34 (0.28 to 0.40) s | 0.33 (0.30 to 0.54) s | -0.01 s, -4.4% | no measurable change (p = 0.965) |
| Python helper memory once started | 71.0 (70.9 to 71.2) MB | 71.0 (69.9 to 71.1) MB | +0.0 MB, +0.0% | no measurable change (p = 0.470) |

- Launch. History is loaded 1.15 s sooner, and the launch uses 16 percent
  less CPU and 18 percent less CPU energy. The first window came out
  "possibly lower", 0.61 s against 0.97 s. That was not repeated and does
  not count.
- Peak memory is 36.7 MB lower.
- Idle memory is 23.2 MB lower between the medians. Part of that is the
  baseline's two levels (plan item 9): its six launches here idled at
  100.2, 115.1, 116.7, 126.3, 128.1 and 132.8 MB. The six launches of
  `experimental` idled at 96.2 to 101.6 MB, so its highest is about where
  the baseline's lowest is.
- The memory the app holds allocated is 6.4 MB lower. Pull requests 90 and
  93 took out 10.7 MB and 3.44 MB in their own comparisons. The total here
  is smaller because the faster launch adds something back, which the next
  section explains.
- Idle CPU, wake-ups, idle CPU power and disk writes did not change
  measurably, and nothing merged was aimed at them. The Python helper is
  unchanged; pull request 86, which is about it, is open.

### What the idle memory is made of

One launch was run with the system recording where every allocation is
made (`MallocStackLogging=lite`), which lets `heap` name the allocations it
otherwise lists as untyped. The build was that of `4ba6ea8`, whose app
sources are those of `c3c21ec`, started the way the benchmark starts it and
read a minute after its history had loaded. It held 55.7 MB allocated.

| What | Allocated | Blocks |
| --- | --- | --- |
| Bitmaps of drawn glyphs, cached by CoreGraphics | 6.52 MB | 3,267 |
| Positions of the 7,000 portfolio snapshots | 5.98 MB | 7,000 |
| Price history arrays | 5.25 MB | 24 |
| What Swift Charts keeps for the main window's chart of 730 points (248 classes) | 5.42 MB | 4,907 |
| Swift type metadata | 4.34 MB | 255 |
| Objective-C method caches | 1.58 MB | 1,814 |
| Everything else: 5,022 classes, none above 1 MB | 26.6 MB | 226,889 |

The glyph bitmaps are the part earlier tables could not explain. In
comparisons since pull request 89, one and the same build held about 6 MB
more allocated after some launches than after others, all of it untyped;
pull request 93's entry notes a spread of 5.9 MB. Two guesses were tested.

It is not the chart. A trial build drew the main window's series as one
area plot and one line plot in place of a mark for every point, and three
launches of it were set against three of the build it was made from. The
benchmark saves the 27 largest classes of each launch. Swift Charts'
classes among them held 5.02 MB in 4,437 blocks in all three launches
before. After, they held 4.38 MB in 1,467 blocks in two launches and 2.75
MB in the third, where Swift Charts held one copy of its content in place
of two; whether that was the change or chance was not established. The
untyped allocations stayed where they were: 19.7 to 20.4 MB before and
20.2 to 20.6 MB after. Swift Charts expands a plot into the same content
for every point as it keeps for separate marks. The trial was not
committed; see "Tried and rejected".

It is the glyph cache. Of the 6.52 MB of glyph bitmaps, 6.1 MB was
allocated while SwiftUI was drawing text in the middle of an animated
change. The figures in the main window change with a rolling-digit
transition. A temporary build with that transition taken out of the main
window, not committed, held 0.46 MB of glyph bitmaps in 576 blocks in the
same kind of launch.

Why some launches fill the cache and others do not is an inference, not
something watched happening. Since pull request 89 the window can be on
screen before the portfolio's figures are ready, and then the figures roll
in; when they are ready first, nothing rolls. The comparisons fit that. In
the comparison above the baseline's six launches held 13.0 to 15.1 MB of
untyped allocations and the six of `experimental` 18.3 to 24.1 MB. In pull
request 95's first run, the three launches whose first window took 0.70 s
or longer held 16.2 to 17.5 MB and the other nine, at 0.45 to 0.56 s, held
21.6 to 23.5 MB. The first window's time does not decide it alone: one
launch of `experimental` in the comparison above took 0.86 s to its window
and held 21.8 MB.

Nothing was changed. The cache belongs to the system, the animation is
deliberate, and in normal use the app starts without a window, so the
figures are ready long before one is opened. The cache was still held after
the 30 minutes of the soak below; whether it is ever emptied was not
measured beyond that.

### Soak: 30 minutes idle, baseline and `experimental`

One launch of each build watched for 30 minutes on 2026-11-12, the baseline
from 18:45 to 19:17 UTC and `experimental` at `c3c21ec` from 19:17 to 19:50,
on mains power with the display awake and unlocked. The load average was
4.8 before the first run, 3.5 between the two and 3.1 after the second.

```bash
STOCKBAR_DERIVED_DATA=build/bench/dd/48343a833a6d bash Scripts/perf/benchmark.sh --skip-build --commit-label 47c1bda --label milestone-1-soak-baseline --runs 1 --window 1800
STOCKBAR_DERIVED_DATA=build/bench/dd/8a91a4015cac bash Scripts/perf/benchmark.sh --skip-build --commit-label c3c21ec --label milestone-1-soak-head --runs 1 --window 1800
```

The two folders are the builds of those commits, made beforehand with
`benchmark.sh --build-only`.

| Metric | Baseline `47c1bda` | `experimental` at `c3c21ec` |
| --- | --- | --- |
| Idle memory (physical footprint), first five minutes | 132.2 MB | 101.4 MB |
| Idle memory (physical footprint), last five minutes | 135.9 MB | 101.7 MB |
| Idle memory, lowest and highest | 128.2 and 135.9 MB | 100.9 and 102.1 MB |
| Memory the app holds allocated, at the end | 67.1 MB | 55.4 MB |
| Idle CPU | 0.131 s/min | 0.136 s/min |
| Idle CPU wake-ups | 24.5 /min | 24.3 /min |
| Idle CPU power | 0.71 mW | 0.63 mW |
| Idle disk writes | 0.000 MB/min | 0.000 MB/min |

- Neither build's memory grows after the first four minutes.
  `experimental` rose by 0.4 MB 55 s into the window and by 0.8 MB at 230
  s, and then stayed where it was for the remaining 26 minutes. The first
  step falls where the app's log shows its startup check for missing price
  history, two minutes after launch. The baseline rose by 6.8 MB at 130 s
  and by 0.8 MB at 230 s, and then stayed at 135.9 MB.
- Idle CPU, wake-ups and CPU power are the same for the two builds, as far
  as one run of each can show.
- The two memory columns are one run of each build and are not a
  comparison; the table above is. The baseline's footprint takes two
  levels (plan item 9) and here it sat at the higher one. Its 67.1 MB
  allocated is also 6.8 MB above its soak of the night before (60.3 MB) and
  above all six of its launches in the comparison above (59.6 to 61.7 MB).
  Its heap listing at the end holds two copies of the main window chart's
  content where the earlier soak held one (3.25 MB against 1.62 MB), the
  chart's accessibility items (0.86 MB) and 2.4 MB more untyped
  allocations. So that chart was built a second time during the run. What
  made it do so was not established.
- Both runs used about four times the CPU of the baseline's soak of the
  night before (0.032 s/min, on the same build). That difference is
  therefore the Mac's state on the day and not the build, and its cause was
  not established. A soak is compared only with a soak run beside it.
- The glyph cache of the section above was still there at the end of
  `experimental`'s half hour: 19.0 MB of untyped allocations, and 1,625
  blocks of the size class its bitmaps fall in.

### Tests at the milestone

Run on 2026-11-12 on the branch that adds this section, whose app sources
and tests are those of `c3c21ec`:

- `bash script/develop.sh test`: 710 XCTest tests, 0 failures. The baseline
  had 682; the 28 more were added by the pull requests since.
- `bash script/develop.sh python-tests`: 66 Python helper tests pass.
- `python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py'`: 75
  script tests pass.
- `bash script/develop.sh checks` and `docs-check` pass.
- `bash script/develop.sh build-release`: the Release configuration builds.

Nothing fails.

### What is left

In my judgement the candidates that remain are either small or change what
the app does:

- The app's own history in memory, 11.2 MB for the fixture's 7,000
  snapshots and 70,000 prices. Lowering it further means not keeping all
  history in memory and reading it when a view needs it. That is a change
  of architecture, not attempted here.
- The main window's chart, 5.4 MB for 730 points. Fewer points would lower
  it in proportion and would change what is drawn.
- The glyph cache, about 6 MB after a launch like the benchmark's, for the
  rolling digits. The owner's choice; see "Tried and rejected".
- The Python helper, 71 MB while it is running. Pull request 86 and the
  [Rust evaluation](#rust-evaluation-2026-11-12) cover the two ways to
  lower it, and both wait for a decision.
- The launch peak of 244 MB, which is the first window being drawn (plan
  item 9).

### Recommendation

`experimental` is ready to be promoted to `testing` when the owner asks for
it. Nothing has been promoted and no pull request into `testing` or `main`
exists. What would go is pull requests 84, 85, 87 to 93 and 95, and this
log. Pull requests 86 and 94 are separate decisions, and 94 only makes
sense where 85 is.

What the measurements do not cover:

- One Mac and one macOS version, 27.2.1 on an M3 Pro, with made-up data.
  The app supports macOS 15.4 and later. Nothing here was run on an older
  system or on a real portfolio's store.
- The benchmark keeps live providers off. A refresh over the network, and
  the app recording prices through a trading day, were not measured.
- The longest run is 30 minutes idle.
- Pull request 89 changes the order of work at launch. It is covered by
  its tests and by every launch of every comparison since, not by a launch
  on a store that has grown over years.
- The popover chart fix was checked by drawing the app's own view with
  made-up data, not on the Mac that showed the fault.

## Pull requests

Newest last. "Before" is the `experimental` commit the branch was based on,
"after" is the head of the pull request, measured in turns by
`Scripts/perf/compare.sh`.

### 84: Add the benchmark procedure, the baseline and the experimental log

- What: `Scripts/perf/benchmark.sh` (one build on fixed synthetic data),
  `Scripts/perf/compare.sh` (two commits in turns, with the before/after
  table), their tests, a rewritten `Scripts/README_PERFORMANCE.md`, the
  read-only sampler for a running app, and this log. No app code.
- Merged: 2026-11-12, squash commit `4f475ea`.
- Benchmark: the baseline above. The two sides are untouched `experimental`
  and this branch, whose app sources are identical, so the table shows the
  noise of the method.
- Testing: 682 XCTest tests, 66 Python helper tests and 70 script tests pass
  (15 of the script tests cover the benchmark data and the comparison
  report). `checks`, `docs-check` and `build-release` pass, and the shell
  scripts pass a syntax check. `measure_performance.sh` was run for 20
  seconds against the installed app to confirm it still reads the sampler.
  The benchmark itself was exercised by the baseline: 16 launches and the
  soak, every one with the display awake and unlocked.
- Known issues: none.
- Verdict: retained.

### 85: Stop building test-coverage counters into release builds

- What: one line of `Stockbar.xcscheme`. The scheme's test action no longer
  auto-creates a test plan. With that setting Xcode turned code coverage on
  for every build of the scheme, Release included, so the shipped executable
  carried coverage counters and maps: the installed 3.7.0 has nine such
  sections. No app code. `develop.sh coverage` asks for coverage explicitly
  and still reports it.
- Merged: 2026-11-12, squash commit `bd56486`.
- Benchmark: before `4f475ea`, after `88383b8`, six launches a side in turns
  on 2026-11-12 from 09:17 to 09:41 UTC, macOS 27.2.1, mains power with the
  battery charging from 12 percent.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Executable size | 24,982,936 bytes | 17,966,360 bytes | -7,016,576 bytes, -28.1% | lower: one build a side, no spread |
  | App bundle size | 29,116 KiB | 22,264 KiB | -6,852 KiB, -23.5% | lower: one build a side, no spread |
  | Coverage sections in the executable | 9, holding 1,125,163 bytes | 0 | removed | removed |
  | Idle memory (physical footprint) | 106.7 (104.9 to 110.6) MB | 105.5 (100.7 to 110.2) MB | -1.2 MB, -1.1% | no measurable change (p = 0.394) |
  | Idle memory the app holds allocated | 61.8 (61.5 to 62.7) MB | 61.6 (59.7 to 63.3) MB | -0.2 MB, -0.4% | no measurable change (p = 0.509) |
  | Peak memory, launch and history load | 282.7 (276.2 to 299.8) MB | 282.6 (275.9 to 287.4) MB | -0.1 MB, -0.0% | no measurable change (p = 0.937) |
  | Idle memory growth across the window | 0.0 (-3.6 to 0.0) MB | 0.0 (-0.1 to 0.1) MB | +0.0 MB | no measurable change (p = 0.727) |
  | Idle CPU | 0.086 (0.076 to 0.099) s/min | 0.092 (0.091 to 0.913) s/min | +0.006 s/min, +7.0% | no measurable change (p = 0.130) |
  | Idle CPU wake-ups | 26 (25 to 28) /min | 28 (25 to 221) /min | +2 /min, +5.7% | no measurable change (p = 0.517) |
  | Idle CPU power | 3.96 (3.47 to 4.94) mW | 4.28 (3.55 to 29.15) mW | +0.33 mW, +8.2% | no measurable change (p = 0.420) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.99 (0.90 to 1.39) s | 0.81 (0.49 to 1.05) s | -0.18 s, -18.2% | no measurable change (p = 0.132) |
  | Launch to history loaded | 1.64 (1.54 to 2.46) s | 1.65 (1.02 to 1.86) s | +0.01 s, +0.9% | no measurable change (p = 0.589) |
  | CPU from launch to the idle window | 2.62 (2.41 to 3.40) s | 2.52 (2.01 to 2.95) s | -0.11 s, -4.0% | no measurable change (p = 0.258) |
  | CPU energy from launch to the idle window | 7.92 (7.57 to 8.26) J | 7.56 (6.34 to 8.09) J | -0.35 J, -4.4% | no measurable change (p = 0.195) |
  | Python helper start to ready, no network | 0.32 (0.28 to 0.59) s | 0.30 (0.28 to 0.61) s | -0.01 s, -3.2% | no measurable change (p = 0.981) |
  | Python helper start, CPU | 0.30 (0.28 to 0.36) s | 0.30 (0.28 to 0.37) s | -0.01 s, -1.6% | no measurable change (p = 0.907) |
  | Python helper memory once started | 71.0 (70.9 to 71.0) MB | 71.0 (70.9 to 71.1) MB | +0.0 MB, +0.0% | no measurable change (p = 1.000) |

  The sizes are of the two apps the comparison built (`stat`, `du -sk` and
  `otool -l`). The rows this change was expected to move were the launch
  rows, since counters are updated on every code path. None moved by more
  than the noise: the benefit measured is the size alone.
- Testing: 682 XCTest tests with 0 failures, run plainly and again under
  `develop.sh coverage`, which still produced its report (30.54 percent of the
  app's lines). 66 Python helper tests and 70 script tests pass. `checks`,
  `docs-check` and `build-release` pass, and the Release executable from
  `build-release` has no coverage sections.
- Known issues: one "after" launch idled at 0.913 s/min with 221 wake-ups a
  minute. Its log shows the same events as every other launch and the cause
  was not found; the Mac had restarted after a macOS update 25 minutes
  earlier. Later comparisons show whether it recurs. Separately, running the
  tests from Xcode's own interface no longer gathers coverage unless it is
  turned on in the scheme's test options, and Xcode can write the setting back
  if the scheme is edited there.
- Verdict: retained, for the smaller executable. It changes no measured
  runtime figure.

### 87: Read stored portfolio history in batches

- What: `CoreDataHistoricalDataService` fetched the whole portfolio history
  at once, so every snapshot's managed objects, with their positions, were
  alive together beside the values built from them. It now lists the
  snapshots oldest first and converts 500 at a time, letting go of each batch
  before the next. Both `fetchPortfolioSnapshots(from:to:)` and
  `fetchAllPortfolioSnapshots()` read this way. Three new tests.
- Merged: 2026-11-12, squash commit `3f59dc6`.
- Benchmark: before `bd56486`, after `1dd6455`, six launches a side in turns
  on 2026-11-12 from 10:39 to 11:09 UTC, macOS 27.2.1, mains power. The row
  it was meant to move is the peak memory of launch and history load. The Mac
  was not quiet: a system file-syncing process and the window server kept
  between one and two cores busy throughout (load average about 6), for both
  sides alike.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 128.9 (104.3 to 132.2) MB | 113.1 (100.0 to 116.2) MB | -15.8 MB, -12.3% | possibly lower (p = 0.026) |
  | Idle memory the app holds allocated | 60.2 (55.1 to 61.5) MB | 61.5 (60.1 to 62.1) MB | +1.3 MB, +2.2% | no measurable change (p = 0.087) |
  | Peak memory, launch and history load | 283.8 (277.0 to 300.3) MB | 267.4 (265.2 to 269.7) MB | -16.4 MB, -5.8% | lower (p = 0.002) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.1) MB | 0.0 (0.0 to 0.1) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.075 (0.065 to 0.086) s/min | 0.082 (0.072 to 0.099) s/min | +0.007 s/min, +8.6% | no measurable change (p = 0.333) |
  | Idle CPU wake-ups | 28 (23 to 31) /min | 30 (28 to 32) /min | +1 /min, +3.5% | no measurable change (p = 0.348) |
  | Idle CPU power | 4.58 (4.20 to 5.14) mW | 4.46 (4.00 to 5.60) mW | -0.13 mW, -2.8% | no measurable change (p = 0.615) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.86 (0.50 to 1.24) s | 0.58 (0.52 to 1.54) s | -0.28 s, -32.9% | no measurable change (p = 0.556) |
  | Launch to history loaded | 1.75 (1.56 to 2.17) s | 1.47 (1.13 to 2.48) s | -0.28 s, -16.2% | no measurable change (p = 0.381) |
  | CPU from launch to the idle window | 2.47 (2.20 to 3.30) s | 2.29 (1.91 to 3.29) s | -0.18 s, -7.3% | no measurable change (p = 0.331) |
  | CPU energy from launch to the idle window | 7.95 (7.48 to 8.37) J | 6.68 (5.55 to 8.38) J | -1.27 J, -15.9% | no measurable change (p = 0.093) |
  | Python helper start to ready, no network | 0.35 (0.30 to 0.73) s | 0.34 (0.29 to 0.62) s | -0.01 s, -4.3% | no measurable change (p = 0.673) |
  | Python helper start, CPU | 0.33 (0.30 to 0.44) s | 0.34 (0.29 to 0.40) s | +0.01 s, +1.5% | no measurable change (p = 0.931) |
  | Python helper memory once started | 71.1 (71.0 to 71.2) MB | 71.0 (70.8 to 71.2) MB | -0.1 MB, -0.2% | no measurable change (p = 0.080) |

  Idle memory came out "possibly lower". That needs a repeat before it
  counts, and it is not claimed. The six "before" launches idled at 104.3,
  126.7, 128.0, 129.8, 130.8 and 132.2 MB and the six "after" launches at
  100.0, 102.4, 111.9, 114.3, 115.4 and 116.2 MB. The "before" build idles
  near 105 MB after some launches and near 130 MB after others: it did so in
  pull request 86's comparison too, on both sides, which ran the same code at
  launch. Six launches a side cannot separate that from an effect of this
  size. Later comparisons have this change on their "before" side and will
  show whether it holds.
- Testing: 685 XCTest tests with 0 failures (three new), 66 Python helper
  tests and 70 script tests pass. `checks`, `docs-check` and `build-release`
  pass. The new tests read a history longer than one batch, compare batch
  sizes against each other, and read from an SQLite store whose rows are not
  in date order.
- Known issues: none.
- Verdict: retained, for the lower peak.

### 88: Record the Rust evaluation and add the script behind its figures

- What: the [Rust evaluation](#rust-evaluation-2026-11-12) below, and
  `Scripts/perf/helper_layers.py`, which measures what each layer of the
  Python helper's imports holds beside two compiled programs that start and
  wait (`native_floor.swift`, `native_floor.rs`). `helper_cost.py` now shares
  its process-starting code with the new script; three starts before and
  three after gave the same figures (0.28 to 0.30 s, 70.8 to 71.1 MB). Its
  one visible difference: the message when the started program exits without
  answering now names the program instead of saying "The worker". A
  section in `Scripts/README_PERFORMANCE.md` and four script tests.
- Merged: 2026-11-12, squash commit `4ff7566`.
- Benchmark: not run. No file that goes into the app changes (nothing under
  `Stockbar/`, `StockbarTests/` or `Stockbar.xcodeproj`), so before and after
  are the same app and all fifteen rows are "not measured". The figures this
  pull request does carry are the layer table in the evaluation.
- Testing: 74 script tests pass (four new), and `checks` and
  `docs-check` pass. The app's own tests were not run again: no file they
  build changes.
- Known issues: none.
- Verdict: retained as a record. No Rust was adopted.

### 89: Read the stored history at launch away from the main thread

- What: at launch the app read each symbol's stored price history and took
  it into memory one symbol at a time on the main actor, then read the
  portfolio history, while the main thread was also building the first
  window. A detached task now reads and thins every symbol's history away
  from the main actor and reads the portfolio history without waiting for the
  prices to be taken. Only taking the results into memory runs on the main
  actor. A stored series is taken as it is when nothing is in memory for its
  symbol, without the merge every series used to go through.
- The defect this found and closes: because every symbol is now read before
  any is taken, the launch read could finish after the UK price scale repair
  had rewritten, invalidated and reloaded a symbol, and put the old rows back
  for the session. `invalidatePriceData` now counts its calls, and a read that
  began before a symbol was invalidated is not taken for that symbol. Eight
  new tests cover the read, the taking into memory, and both orders of a
  stale read and the reload.
- Behaviour change: stored price history used to appear symbol by symbol as
  it was read. It now appears for every symbol together, once all are read.
  All of it is in memory sooner (the table below). How much later the first
  symbol's history arrives than it used to was not measured; it is in memory
  within the 0.60 s the whole load now takes.
- Merged: 2026-11-12, squash commit `8140395`.
- Benchmark: before `4ff7566`, after `6925741`, ten launches a side in turns
  on 2026-11-12 from 11:23 to 12:13 UTC, macOS 27.2.1, mains power. The rows
  it was meant to move are launch to history loaded and launch to first
  window. All twenty launches ran with the screen locked and eighteen with
  the display asleep; the last two "before" launches had the display awake.
  See "Breaks in the measuring environment". When the run began a system
  media-analysis process was using more than two cores (load average 3.9).

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 123.2 (117.5 to 129.9) MB | 116.2 (113.4 to 122.4) MB | -6.9 MB, -5.6% | lower (p = 0.000) |
  | Idle memory the app holds allocated | 63.0 (62.5 to 63.4) MB | 63.3 (62.9 to 63.5) MB | +0.3 MB, +0.6% | possibly higher (p = 0.020) |
  | Peak memory, launch and history load | 261.8 (259.9 to 269.7) MB | 253.0 (251.5 to 259.2) MB | -8.8 MB, -3.3% | lower (p = 0.000) |
  | Idle memory growth across the window | 0.0 (-0.2 to -0.0) MB | 0.0 (0.0 to 0.2) MB | +0.0 MB | no measurable change (p = 0.263) |
  | Idle CPU | 0.162 (0.089 to 0.198) s/min | 0.168 (0.154 to 0.223) s/min | +0.006 s/min, +3.7% | no measurable change (p = 0.210) |
  | Idle CPU wake-ups | 25 (23 to 31) /min | 28 (22 to 30) /min | +2 /min, +10.0% | no measurable change (p = 0.298) |
  | Idle CPU power | 1.38 (1.29 to 4.21) mW | 1.31 (1.25 to 1.50) mW | -0.08 mW, -5.8% | no measurable change (p = 0.117) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.42 (0.37 to 0.95) s | 0.42 (0.38 to 0.66) s | +0.01 s, +1.2% | no measurable change (p = 0.959) |
  | Launch to history loaded | 1.03 (0.85 to 1.70) s | 0.60 (0.51 to 0.86) s | -0.43 s, -41.3% | lower (p = 0.000) |
  | CPU from launch to the idle window | 2.23 (1.98 to 3.00) s | 1.67 (1.59 to 1.87) s | -0.56 s, -24.9% | lower (p = 0.000) |
  | CPU energy from launch to the idle window | 7.12 (6.47 to 8.14) J | 5.32 (5.04 to 5.65) J | -1.80 J, -25.3% | lower (p = 0.000) |
  | Python helper start to ready, no network | 0.31 (0.23 to 0.61) s | 0.25 (0.24 to 0.48) s | -0.06 s, -19.4% | no measurable change (p = 0.835) |
  | Python helper start, CPU | 0.29 (0.23 to 0.38) s | 0.24 (0.24 to 0.28) s | -0.04 s, -14.0% | no measurable change (p = 0.331) |
  | Python helper memory once started | 71.0 (70.9 to 71.1) MB | 71.0 (70.9 to 71.0) MB | +0.0 MB, +0.0% | no measurable change (p = 1.000) |

  Of the two rows it was meant to move, launch to history loaded is lower by
  0.43 s and launch to first window did not move. So history is ready
  sooner, but the first window does not appear sooner, at least with the
  screen locked.

  Four rows moved that were not predicted: CPU and CPU energy from launch to
  the idle window (a quarter lower), peak memory (8.8 MB lower) and idle
  memory (6.9 MB lower). The likely reason, from reading the code and not
  measured separately: the old path built a set of every stored row's
  timestamp and merged before thinning, for every symbol, and the new path
  thins once and skips the merge when nothing is in memory. That is work
  removed, not only work moved. Idle memory has shown two levels for one
  build before (pull request 87), so that row carries less weight than the
  others.

  Without the two launches that had the display awake, the eight remaining
  "before" launches give the same picture: history loaded in 0.96 s against
  0.60 s, launch CPU 2.20 s against 1.67 s, peak memory 261.3 MB against
  253.0 MB.

  The heap the app holds allocated came out "possibly higher", by 0.3 MB.
  That needs a repeat before it counts and was not repeated. If it is real,
  it is 0.3 MB inside an idle memory figure that fell by 6.9 MB. The
  milestone comparison against the baseline will show the heap row again.
- Testing: 693 XCTest tests with 0 failures (eight new), 66 Python helper
  tests and 74 script tests pass. `checks`, `docs-check` and `build-release`
  pass. Every launch on both sides of the comparison logged the same 7000
  portfolio snapshots loaded.
- Reviews: two independent reviews by Opus. The first found the defect
  above. The second, of the corrected branch, found no defect and pointed out
  the behaviour change above, which the description had not mentioned.
- Known issues: two small ones, left as they are. No test pins that a read
  notes the invalidation count before it starts and not after; the manager
  cannot be built around a stand-in store in a test. And a symbol skipped
  because it was invalidated is not logged, while the "Loaded stored price
  history for N symbols" line still counts it.
- Verdict: retained, for history loaded 0.43 s sooner and a quarter less CPU
  at launch.

### 90: Keep each portfolio snapshot's positions in a sorted array

- What: every portfolio snapshot the app keeps in memory carries the
  positions held at that moment, and the app keeps thousands of snapshots.
  The positions were a dictionary keyed by symbol, whose hash table for 15
  holdings takes about 2.3 KB. They are now `PositionSnapshots`, an array
  sorted by symbol that is searched by halving: 56 bytes a position, about
  0.9 KB for 15. It is still written to and read from JSON as a dictionary
  keyed by symbol, and what is stored in Core Data does not change.
- Behaviour differences, none of them reachable from what the app writes
  today. Positions are now walked in order of symbol where a dictionary's
  order was arbitrary, so the risk figures add their terms in a fixed order.
  If one stored snapshot ever held the same symbol twice, the first is now
  kept, where the survivor used to depend on the order of an unordered set;
  nothing writes such a snapshot. A dictionary entry filed under a key other
  than its position's own symbol takes the key as its symbol, so it is still
  found under that key.
- Merged: 2026-11-12, squash commit `612d214`.
- Benchmark: before `8140395`, after `3f50c11`, six launches a side in turns
  on 2026-11-12 from 12:32 to 13:04 UTC, macOS 27.2.1, mains power. The row
  it was meant to move is the idle memory the app holds allocated, expected
  about 11 MB lower. All twelve launches ran with the screen unlocked and
  the display awake. When the run began Spotlight indexing and the file
  provider were using about three cores between them (load average 9.6,
  falling to about 6 by the end).

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 110.0 (108.0 to 111.6) MB | 95.8 (92.4 to 102.3) MB | -14.2 MB, -13.0% | lower (p = 0.002) |
  | Idle memory the app holds allocated | 62.9 (61.9 to 63.3) MB | 52.2 (51.6 to 53.4) MB | -10.7 MB, -17.0% | lower (p = 0.002) |
  | Peak memory, launch and history load | 271.1 (258.4 to 273.8) MB | 250.2 (240.7 to 261.0) MB | -20.8 MB, -7.7% | lower (p = 0.004) |
  | Idle memory growth across the window | 0.0 (-4.2 to 0.0) MB | 0.0 (0.0 to 0.0) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.079 (0.067 to 0.091) s/min | 0.082 (0.067 to 0.085) s/min | +0.003 s/min, +3.2% | no measurable change (p = 0.911) |
  | Idle CPU wake-ups | 28 (25 to 33) /min | 28 (24 to 30) /min | +0 /min, +1.8% | no measurable change (p = 1.000) |
  | Idle CPU power | 4.41 (3.88 to 4.95) mW | 4.04 (3.88 to 4.35) mW | -0.38 mW, -8.5% | no measurable change (p = 0.097) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.63 (0.46 to 1.00) s | 0.58 (0.48 to 1.32) s | -0.05 s, -7.9% | no measurable change (p = 0.974) |
  | Launch to history loaded | 0.75 (0.56 to 1.00) s | 0.62 (0.53 to 1.30) s | -0.13 s, -17.3% | no measurable change (p = 0.942) |
  | CPU from launch to the idle window | 1.83 (1.71 to 1.99) s | 1.77 (1.60 to 2.08) s | -0.06 s, -3.6% | no measurable change (p = 0.701) |
  | CPU energy from launch to the idle window | 5.59 (5.29 to 6.12) J | 5.47 (5.14 to 6.23) J | -0.12 J, -2.1% | no measurable change (p = 0.613) |
  | Python helper start to ready, no network | 0.33 (0.28 to 0.63) s | 0.28 (0.27 to 0.56) s | -0.05 s, -16.7% | no measurable change (p = 0.173) |
  | Python helper start, CPU | 0.30 (0.28 to 0.39) s | 0.28 (0.27 to 0.35) s | -0.03 s, -9.8% | no measurable change (p = 0.180) |
  | Python helper memory once started | 71.0 (71.0 to 71.1) MB | 71.0 (70.9 to 71.0) MB | -0.1 MB, -0.1% | possibly lower (p = 0.043) |

  The row it was meant to move fell by 10.7 MB, a sixth of the allocated
  heap. Two rows moved that were not predicted. Idle memory fell by 14.2 MB,
  more than the allocated heap did. Peak memory fell by 20.8 MB: the history
  load now builds an array for each snapshot where it built a dictionary.
  No CPU, energy or launch-time row moved.

  The helper's memory came out "possibly lower", by 0.1 MB. The helper is
  the same code on both sides, so that row is chance.

  A first attempt at 12:19 UTC stopped before measuring anything. The
  warm-up launch of the "before" build did not finish its first history
  calculation within the 180 s the script allows. The Mac's load average was
  between 46 and 64 at the time, from system work (the file provider, media
  analysis, on-device inference, a backup and Spotlight) on top of a test
  run and two builds for this pull request that had just finished. The
  script deleted the app's log with its temporary storage, so the cause is
  not established. Afterwards the same build completed a warm-up launch in
  62 s at 12:26 UTC, and all four warm-up launches of the second attempt
  completed. No crash report was written.
- Testing: 701 XCTest tests with 0 failures (eight new), 66 Python helper
  tests and 74 script tests pass. `checks`, `docs-check` and `build-release`
  pass. Every launch on both sides of the comparison logged the same 7000
  portfolio snapshots loaded.
- Review: one independent review by Opus, of the branch after
  `experimental` was merged into it and before anything was built. It found
  that the tests no longer compiled: two lines added by pull request 87
  still used the dictionary. Fixed before the test run. It found no defect
  in the change, confirmed that nothing else uses the dictionary's
  interface, and checked the memory arithmetic.
- Known issues: two small ones, left as they are. `symbols` builds an array
  where the dictionary's `keys` was a view; its two callers each use it once
  per snapshot for an export or an analysis. And no test pins the
  `compositionHash` text written with each stored snapshot. It is built from
  the same strings in the same sorted order as before, and nothing in the
  app reads it back.
- Verdict: retained, for 10.7 MB less allocated memory at idle and 20.8 MB
  less at the launch peak, with nothing given up.

### 91: Keep the app's log when a benchmark launch fails

- What: `Scripts/perf/benchmark.sh` runs the app against temporary storage
  and deletes that storage when it ends, the app's log with it. A run that
  failed therefore left nothing to explain the failure, which is what
  happened to the first attempt at pull request 90's comparison. A run that
  does not finish, whether it fails or is stopped, now copies the log to
  `app-failed.log` in its results folder, with anything the app printed as
  `app-output-failed.log`, and says where. The temporary storage is still deleted. The script's two error
  messages for a launch that exits or times out no longer name the log file
  that is about to be deleted. A successful run is unchanged. One new script
  test runs the script against a stand-in for the
  app that exits at once, and a paragraph in `Scripts/README_PERFORMANCE.md`
  describes it.
- Merged: 2026-11-12, squash commit `248280a`.
- Benchmark: not run. No file that goes into the app changes (nothing under
  `Stockbar/`, `StockbarTests/` or `Stockbar.xcodeproj`), so before and after
  are the same app and all fifteen rows are "not measured".
- Testing: 75 script tests pass (one new). The new test fails against the
  script as it was and passes with the change. `checks` and `docs-check`
  pass. A run stopped with a termination signal during its warm-up, tried by
  hand against a stand-in that stays running, kept the log as well; no
  script test covers that case. One real run of the changed script on its normal path (one launch of
  the build of `3f50c11`) ended without error, saved `app.log` and its
  figures as before, wrote no `app-failed.log`, and left no temporary
  storage or app process behind. The app's own tests were not run again: no
  file they build changes.
- Known issues: the new test needs macOS and its developer tools, and is
  skipped without them. The first time it runs in a checkout it compiles the
  benchmark's small measuring tool into `build/`, which takes a few seconds.
- Verdict: retained. It does not explain the failure that prompted it; it
  means the next one can be explained.

### 92: Read the portfolio chart's history without each snapshot's positions

- What: the chart of the portfolio's value, in the menu bar popover and the
  Overview window, draws one point per stored snapshot from its date, total
  and currency. For any range longer than a day, unless the value comes from
  Folync, it read whole snapshots from Core Data, each with the positions held at that moment: one more row per
  holding for every row it used, fifteen in the benchmark's portfolio. It now
  asks Core Data for those three columns only
  (`fetchPortfolioValues`, returning `StoredPortfolioValue`). The rows, their
  order and the defaults for a missing date or currency are the same. The
  chart reloads whenever the stored prices or portfolio history change while
  it is on screen, three or four times during a launch, so the read recurs.
  The function the chart used to call and the overload that turned whole
  snapshots into chart points had no other caller and are removed. The only
  difference to see is in the log, where the chart's read now says
  "portfolio values" where it said "portfolio snapshots".
- Merged: 2026-11-12, squash commit `f0fdcc3`.
- Benchmark: before `248280a`, after `42fea1f`, six launches a side in turns
  on 2026-11-12 from 13:43 to 14:16 UTC, macOS 27.2.1, mains power, all
  twelve launches with the screen unlocked and the display awake. Named in
  advance: the chart's own read of a week of stored history, timed from the
  app's log and expected several times shorter than about 25 ms; no standard
  row was expected to move. The Mac was busy with other work throughout
  (load average 7.9 at the start, after waiting 80 s for it to fall below
  8).

  | Change-specific row | Before | After | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | The chart's read of a week of stored history (730 or 731 snapshots): median (range) | 24 (21 to 30) ms, 20 reads | 2 (1 to 3) ms, 19 reads | -22 ms, about a twelfth of the time | lower: the longest read after is shorter than the shortest before |

  That row is the time between the two lines the read writes to the app's
  log, taken from the measured launches of the same comparison.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 89.7 (87.5 to 99.3) MB | 87.8 (83.0 to 92.0) MB | -1.8 MB, -2.1% | no measurable change (p = 0.225) |
  | Idle memory the app holds allocated | 50.5 (46.9 to 51.6) MB | 51.4 (43.8 to 56.4) MB | +0.8 MB, +1.6% | no measurable change (p = 0.515) |
  | Peak memory, launch and history load | 238.1 (235.1 to 245.8) MB | 240.0 (237.9 to 242.5) MB | +1.9 MB, +0.8% | no measurable change (p = 0.186) |
  | Idle memory growth across the window | 0.0 (-1.7 to 5.9) MB | 0.0 (-0.2 to 3.2) MB | +0.0 MB | no measurable change (p = 0.879) |
  | Idle CPU | 0.093 (0.076 to 1.724) s/min | 0.091 (0.087 to 0.398) s/min | -0.003 s/min, -2.7% | no measurable change (p = 0.732) |
  | Idle CPU wake-ups | 28 (26 to 501) /min | 30 (25 to 43) /min | +2 /min, +5.4% | no measurable change (p = 0.972) |
  | Idle CPU power | 4.54 (4.40 to 89.35) mW | 4.67 (3.97 to 12.87) mW | +0.13 mW, +3.0% | no measurable change (p = 0.818) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 1.14 (0.94 to 1.25) s | 1.08 (0.86 to 1.36) s | -0.06 s, -5.3% | no measurable change (p = 0.660) |
  | Launch to history loaded | 1.08 (0.89 to 1.20) s | 1.06 (0.85 to 1.34) s | -0.03 s, -2.8% | no measurable change (p = 0.894) |
  | CPU from launch to the idle window | 2.06 (1.93 to 2.16) s | 2.08 (1.99 to 2.14) s | +0.02 s, +0.7% | no measurable change (p = 0.712) |
  | CPU energy from launch to the idle window | 6.09 (6.01 to 6.44) J | 6.30 (5.64 to 6.50) J | +0.21 J, +3.5% | no measurable change (p = 0.485) |
  | Python helper start to ready, no network | 0.31 (0.30 to 0.74) s | 0.37 (0.31 to 0.71) s | +0.06 s, +19.4% | no measurable change (p = 0.455) |
  | Python helper start, CPU | 0.30 (0.29 to 0.42) s | 0.35 (0.30 to 0.43) s | +0.04 s, +14.8% | no measurable change (p = 0.251) |
  | Python helper memory once started | 71.0 (69.9 to 71.1) MB | 71.0 (71.0 to 71.3) MB | -0.0 MB, -0.1% | no measurable change (p = 0.760) |

  The read fell as expected and no standard row moved, also as expected:
  three or four reads of 24 ms come to less than 0.1 s, away from the main
  thread, in a launch that uses 2 s of CPU.

  Not measured, so theoretical: the saving for longer ranges and over a day
  of use. In these twelve launches the app's own launch read of all 7000
  snapshots with their positions took a median of 246 ms (222 to 332 ms).
  That is what the chart's read cost for the range "All" before this change;
  the new read was not timed at that size. How often the chart reloads in
  real use was not counted: the benchmark runs without market data.

  One launch on each side had a busier idle window than the rest (501 CPU
  wake-ups a minute before and 43 after, against 25 to 31 in the other ten).
  The cause is not established. The verdicts compare ranks, so a single
  launch does not decide a row. Launch times are longer than in pull request
  90's comparison for the same reason as the load average: the first window
  took 1.14 s here with the same app sources that took 0.58 s there.

  A first comparison, of an earlier head of the branch (`d6a5f96`), was
  stopped part of the way through its first round when the session running
  it restarted. It
  left the app's log behind, as pull request 91 arranged, and the log showed
  a fault in that version: over seven reads in two launches the new read
  took a median of 21 ms, between 5 and 53 ms, no better than the old one.
  It ran on the main actor and went back to it between its steps, waiting
  its turn each time while the launch kept the main actor busy. The read
  now runs clear of the main actor, as the read it replaces did
  (`readPortfolioValues`), and the figures above are of that version.
- Testing: 703 XCTest tests with 0 failures (two new: the values read
  returns the same snapshots in the same order as the read with positions,
  on a SQLite store, and it returns nothing when the fetch fails). `checks`,
  `docs-check` and `build-release` pass at `42fea1f`. The 66 Python helper
  tests and 75 script tests were run at `d6a5f96`, one commit earlier, and
  pass; that last commit changed two Swift files only. Every measured launch
  on both sides logged the same 7000 portfolio snapshots loaded, and the
  chart's reads returned the same 730 or 731 rows on both sides.
- Review: read by the author of the change after `experimental` was merged
  into the branch; no independent review, for a change of about a hundred
  lines with a test that sets the new read against the old one. The fault
  above was found by measuring, not by reading.
- Known issues: none.
- Verdict: retained. The gain is small and confined to the chart: 22 ms of
  background work less each time it reloads, more for longer ranges. No
  standard row improved and none got worse.

### 93: Size the in-memory price history arrays to fit

- What: the app keeps each symbol's price history in memory as one array,
  which `thinnedPriceHistory` built a point at a time. An array that grows
  that way doubles each time it fills, so each one ended with room for far
  more points than it held: in the benchmark's store, a 384 KB block for
  3181 points that need 224 KB. The thinning now reserves its room once and,
  if it dropped more than an eighth of what it reserved, copies the result
  into an array of the right size.

  A fitted array is full, and a full array doubles at the next append. Each
  held symbol gains a point with every recorded price, so the fit would
  have been undone at the first one. New prices are therefore added through
  `appendToPriceHistory`, which makes room for 256 more points (18 KB) when
  a series is full instead of doubling it. The branch as it was carried over
  did not have this part; it was added before anything was measured.

  The points kept and their order are the same.
- Merged: 2026-11-12, squash commit `c4f4cff`
- Benchmark: before `f0fdcc3`, after `a18eda4`, six launches a side in turns
  on 2026-11-12 from 14:31 to 15:04 UTC, macOS 27.2.1, mains power, all
  twelve launches with the screen unlocked and the display awake. Named in
  advance: the memory held by the price history arrays, read from each
  launch's heap listing, expected to fall from 8.69 MB to about 5.2 MB; of
  the standard rows, the idle memory the app holds allocated expected about
  3.5 MB lower and idle memory possibly lower by a similar amount; no other
  row expected to move. The Mac was busy with other work (load average 7.1
  at the start, after waiting 60 s for it to fall below 8).

  | Change-specific row | Before | After | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Memory held by the price history arrays (69,982 points for 22 symbols) | 8.69 MB in all six launches | 5.25 MB in all six launches | -3.44 MB, -39.6% | lower: the same figure in every launch on each side |

  That row is the line for `_ContiguousArrayStorage<PriceSnapshot>` in the
  `heap` listing saved with every measured launch.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 94.6 (87.4 to 99.2) MB | 90.0 (87.7 to 94.0) MB | -4.6 MB, -4.9% | no measurable change (p = 0.240) |
  | Idle memory the app holds allocated | 53.2 (50.5 to 57.5) MB | 47.8 (46.7 to 50.9) MB | -5.4 MB, -10.1% | lower (p = 0.004) |
  | Peak memory, launch and history load | 241.2 (230.3 to 244.1) MB | 238.6 (227.1 to 245.8) MB | -2.6 MB, -1.1% | no measurable change (p = 0.818) |
  | Idle memory growth across the window | 0.0 (-0.8 to 0.1) MB | 0.0 (-4.7 to 0.0) MB | +0.0 MB | no measurable change (p = 0.273) |
  | Idle CPU | 0.094 (0.088 to 0.103) s/min | 0.099 (0.090 to 0.170) s/min | +0.005 s/min, +5.3% | no measurable change (p = 0.240) |
  | Idle CPU wake-ups | 28 (27 to 31) /min | 31 (22 to 39) /min | +3 /min, +10.7% | no measurable change (p = 0.452) |
  | Idle CPU power | 4.53 (4.22 to 4.65) mW | 4.59 (3.65 to 5.26) mW | +0.06 mW, +1.4% | no measurable change (p = 0.390) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 1.00 (0.55 to 1.57) s | 1.19 (0.68 to 1.88) s | +0.19 s, +18.5% | no measurable change (p = 0.589) |
  | Launch to history loaded | 0.99 (0.65 to 1.48) s | 1.18 (0.81 to 1.88) s | +0.19 s, +19.2% | no measurable change (p = 0.420) |
  | CPU from launch to the idle window | 2.05 (1.86 to 2.13) s | 2.29 (1.98 to 2.65) s | +0.24 s, +11.7% | no measurable change (p = 0.180) |
  | CPU energy from launch to the idle window | 6.13 (4.87 to 6.40) J | 5.93 (5.14 to 6.56) J | -0.21 J, -3.3% | no measurable change (p = 0.937) |
  | Python helper start to ready, no network | 0.33 (0.30 to 0.66) s | 0.33 (0.31 to 0.65) s | +0.00 s, +0.0% | no measurable change (p = 1.000) |
  | Python helper start, CPU | 0.32 (0.30 to 0.42) s | 0.32 (0.31 to 0.41) s | +0.00 s, +0.0% | no measurable change (p = 0.749) |
  | Python helper memory once started | 71.0 (70.9 to 71.2) MB | 71.0 (70.9 to 71.2) MB | +0.0 MB, +0.0% | no measurable change (p = 0.866) |

  The arrays fell as predicted. The idle memory the app holds allocated is
  lower, by 5.4 MB between the medians. Only 3.44 MB of that is this change:
  between two launches of the same build in this run, untyped allocations
  alone differed by 5.9 MB, and that is the spread of the row. Idle memory
  as a whole came out 4.6 MB lower, which is not distinguishable from no
  change (p = 0.240).

  The launch rows did not change. The Mac slowed down over the half hour,
  for both builds alike: the first window took 0.55 to 0.79 s in the first
  three "before" launches and 1.21 to 1.57 s in the last three; the six
  "after" launches, run between them, took 0.68 to 1.88 s. Measuring in
  turns is what keeps that drift out of the verdict.

  Not measured in the running app: growth by a step when prices are
  recorded. The benchmark has no market data, so nothing is appended. It is
  checked by a test instead, which is a count and not a timing: a fitted
  series of 3000 points given 1000 more never has room for more than 1000
  spare, and with the old behaviour it had room for 3185 once it had
  doubled.
- Testing: 705 XCTest tests with 0 failures (two new), 66 Python helper
  tests and 75 script tests pass, and `checks`, `docs-check` and
  `build-release` pass, all at `a18eda4`. Both new tests fail when the old
  behaviour is put back (5460 points of room for 3000 kept) and pass with
  the change. Every measured launch on both sides logged the same 22
  symbols with 69,982 points in memory and the same 7000 portfolio snapshots.
- Review: read by the author of the change after `experimental` was merged
  into the branch, together with every place that assigns or appends to a
  price series. That reading found the doubling at the first append. No
  independent review, for about twenty lines of app code with tests that
  count capacity directly.
- Known issues: none in this change. One thing seen and left alone is
  recorded as plan item 11.
- Verdict: retained, for 3.44 MB less allocated memory at idle with nothing
  given up.

### 95: Keep the popover chart's line from doubling back at a gap in time

- What: a bug fix. The owner reported it from a second Mac running 3.7.0: in
  the popover's chart of the last 24 hours, the line swung back to the left
  just before the night between two trading sessions and overshot just after
  it.

  The two popover charts, the portfolio's and each stock's, smooth their
  line with a curve whose direction at each point comes from the points
  either side of it. Prices five minutes apart sit about a pixel apart, and
  the first price of the next morning sits more than a hundred pixels
  further on. That far neighbour set a pull over twenty pixels long on a
  piece of curve one pixel wide, so the curve ran backwards before the gap
  and past its end point after it.

  The pull is now shortened, keeping its direction, to reach no further
  than a third of the way across its own piece of the line. The line then
  only ever moves forward in time.

  Behaviour change, deliberate: evenly spaced points give a pull of exactly
  a third, so their curves are the same as before, to the last digit. Where
  a piece of the line sits beside a wider one, around a night or a weekend,
  its curve is tighter at that end. Nothing else changes: the same points,
  the same scale, the same hover. The main window's charts are drawn by
  Swift Charts and never had the fault.
- Merged: 2026-11-12, squash commit `c3c21ec`
- Benchmark: before `c4f4cff`, after `4ba6ea8`, measured twice on
  2026-11-12, each time six launches a side in turns on macOS 27.2.1 and
  mains power, all twelve launches with the screen unlocked and the display
  awake. Named in advance: no row expected to move, because the benchmark
  opens the main window and never the popover.

  That reason was checked, and it holds. A temporary copy of the branch,
  not committed, left an empty file behind whenever the popover chart was
  built, drew, or worked out a curve. Built and started the way the
  benchmark starts the app, for a warm-up launch and a measured one, it
  left none of the three files, and its binary did hold the three file
  names. The code this pull request changes does not run in the benchmark,
  so no row below can have moved because of what that code does.

  | Change-specific row | Before | After | Change | How measured |
  | --- | --- | --- | --- | --- |
  | Furthest the drawn line moves back to the left: a made-up day of two sessions with a night between, 158 points on a chart 300 points wide | 9.4 points | 0.0 points | -9.4 points | Each piece of the curve stepped through at 200 positions; exact arithmetic, one run |
  | Working out the control points of that whole line | 0.26 (0.24 to 0.38) µs | 0.51 (0.49 to 0.61) µs | +0.25 µs | A copy of both formulas compiled with `-O`, 25 timings of 2,000 lines each, in turns; a second run gave 0.26 and 0.50 |

  That is a quarter of a microsecond more for each line drawn, where one
  frame at 60 a second is 16,667 µs.

  First run, 16:06 to 16:40 UTC. The load average was 7.3 at the start,
  after waiting 80 s for it to fall below 8.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 99.8 (99.2 to 102.1) MB | 96.5 (92.4 to 102.6) MB | -3.2 MB, -3.2% | no measurable change (p = 0.457) |
  | Idle memory the app holds allocated | 54.6 (53.8 to 55.6) MB | 52.0 (48.3 to 55.3) MB | -2.6 MB, -4.7% | no measurable change (p = 0.292) |
  | Peak memory, launch and history load | 244.4 (241.5 to 251.6) MB | 243.9 (234.4 to 250.8) MB | -0.5 MB, -0.2% | no measurable change (p = 0.818) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.5) MB | 0.0 (0.0 to 0.1) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.085 (0.081 to 0.087) s/min | 0.089 (0.075 to 0.100) s/min | +0.005 s/min, +5.9% | no measurable change (p = 0.563) |
  | Idle CPU wake-ups | 27 (24 to 31) /min | 31 (24 to 43) /min | +4 /min, +14.8% | no measurable change (p = 0.121) |
  | Idle CPU power | 4.09 (3.97 to 4.22) mW | 4.33 (4.17 to 4.51) mW | +0.25 mW, +6.0% | higher (p = 0.006) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.47 (0.45 to 0.52) s | 0.63 (0.49 to 1.16) s | +0.16 s, +34.0% | higher (p = 0.004) |
  | Launch to history loaded | 0.58 (0.57 to 0.62) s | 0.77 (0.57 to 1.15) s | +0.19 s, +31.6% | no measurable change (p = 0.087) |
  | CPU from launch to the idle window | 1.89 (1.87 to 1.99) s | 1.96 (1.89 to 2.24) s | +0.07 s, +3.7% | no measurable change (p = 0.089) |
  | CPU energy from launch to the idle window | 6.21 (5.80 to 6.29) J | 6.07 (4.39 to 6.44) J | -0.14 J, -2.3% | no measurable change (p = 0.699) |
  | Python helper start to ready, no network | 0.36 (0.31 to 0.70) s | 0.29 (0.28 to 0.59) s | -0.07 s, -19.2% | no measurable change (p = 0.167) |
  | Python helper start, CPU | 0.34 (0.31 to 0.43) s | 0.29 (0.28 to 0.36) s | -0.05 s, -14.7% | no measurable change (p = 0.063) |
  | Python helper memory once started | 71.0 (70.9 to 71.2) MB | 71.0 (70.9 to 71.0) MB | -0.1 MB, -0.1% | no measurable change (p = 0.297) |

  Repeat, 17:34 to 18:06 UTC. The Mac had been asleep. It woke at 17:27 UTC
  on battery and was on mains by 17:32; the run waited until three checks
  in a row found it on mains with a load average below 8. The load average
  over the five minutes before the start was 28.6, and the battery charged
  from 47 to 68 percent while the run went on.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 102.6 (101.8 to 103.6) MB | 101.6 (101.3 to 102.5) MB | -1.0 MB, -1.0% | possibly lower (p = 0.013) |
  | Idle memory the app holds allocated | 57.0 (56.4 to 57.4) MB | 56.3 (55.2 to 57.0) MB | -0.8 MB, -1.3% | no measurable change (p = 0.071) |
  | Peak memory, launch and history load | 249.3 (247.5 to 251.4) MB | 248.9 (245.1 to 261.0) MB | -0.4 MB, -0.2% | no measurable change (p = 0.556) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.1) MB | 0.0 (0.0 to 0.0) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.190 (0.144 to 0.194) s/min | 0.198 (0.193 to 0.205) s/min | +0.009 s/min, +4.5% | higher (p = 0.006) |
  | Idle CPU wake-ups | 25 (24 to 27) /min | 24 (23 to 25) /min | -1 /min, -4.0% | possibly lower (p = 0.037) |
  | Idle CPU power | 3.69 (3.56 to 4.07) mW | 3.70 (3.61 to 4.27) mW | +0.01 mW, +0.3% | no measurable change (p = 0.665) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.55 (0.54 to 0.61) s | 0.59 (0.53 to 0.76) s | +0.04 s, +7.3% | no measurable change (p = 0.281) |
  | Launch to history loaded | 0.58 (0.56 to 0.72) s | 0.66 (0.55 to 0.74) s | +0.08 s, +12.8% | no measurable change (p = 0.561) |
  | CPU from launch to the idle window | 2.08 (2.04 to 2.13) s | 2.12 (2.07 to 2.24) s | +0.04 s, +1.9% | no measurable change (p = 0.130) |
  | CPU energy from launch to the idle window | 6.07 (5.98 to 6.36) J | 6.36 (6.30 to 6.54) J | +0.28 J, +4.6% | possibly higher (p = 0.017) |
  | Python helper start to ready, no network | 0.29 (0.27 to 0.56) s | 0.31 (0.27 to 0.87) s | +0.01 s, +3.4% | no measurable change (p = 0.983) |
  | Python helper start, CPU | 0.29 (0.27 to 0.36) s | 0.30 (0.27 to 0.38) s | +0.01 s, +3.4% | no measurable change (p = 0.814) |
  | Python helper memory once started | 71.0 (70.9 to 71.1) MB | 71.0 (70.9 to 71.2) MB | +0.0 MB, +0.1% | no measurable change (p = 0.374) |

  Three rows were marked "higher" across the two runs, none of them in
  both. Each follows a step in the Mac's state part of the way through a
  run:

  - Launch to first window, first run. The six launches of this branch
    were measured in two rounds of three. The first round took 0.70, 1.16
    and 1.04 s and the second 0.56, 0.56 and 0.49 s, against 0.45 to 0.52 s
    for `experimental` either side of them. In the repeat the two sides
    took 0.54 to 0.61 s and 0.53 to 0.76 s: no measurable change
    (p = 0.281).
  - Idle CPU power, first run: 4.33 mW against 4.09 mW. In the repeat, 3.70
    mW against 3.69 mW: no measurable change (p = 0.665).
  - Idle CPU, repeat. The first two launches of the run, both of
    `experimental`, used 0.150 and 0.144 s/min. The other ten used 0.189 to
    0.205 s/min: `experimental` 0.189 to 0.194 in four launches and this
    branch 0.193 to 0.205 in six. The verdict rests on those first two
    launches. In the first run the row was 0.085 against 0.089 s/min, no
    measurable change (p = 0.563). Every launch of the repeat, on both
    sides, used about twice the CPU that the same two builds had used
    ninety minutes earlier on the same workload, so that difference is the
    Mac, which had just woken and was charging.

  The three rows marked "possibly" in the repeat (idle memory 1.0 MB lower,
  wake-ups 1 a minute lower, launch energy 0.28 J higher) were "no
  measurable change" in the first run, two of them with the opposite sign.

  So this pull request made no measurable change. What the two runs do
  show is a limit of the benchmark: its verdict treats twelve launches as
  twelve independent measurements, and when the Mac changes state in a
  step during a run, launches measured together share that state. A row
  that moves without having been named in advance is therefore repeated
  before it counts, whatever its p value. "How this branch works" now says
  so.

  Not measured: the popover's drawing time in the running app, and energy
  while the popover is open. The benchmark has no step that opens the
  popover, and the arithmetic in the first table is the only part of the
  drawing that changed.
- Testing: 710 XCTest tests with 0 failures (five new), 66 Python helper
  tests and 75 script tests pass, and `checks`, `docs-check` and
  `build-release` pass, all at `4ba6ea8`. With the old formula put back,
  four of the five new tests fail: the line moves back, a pull reaches
  outside its own piece, the pull before the night is 22.8 points long
  where a third of the piece is 0.33, and two points at the same time are
  not joined by a straight line. The fifth, that evenly spaced points keep
  the curve they had, passes either way, as it should.

  The app's own chart view was also drawn to a picture by a temporary test,
  not committed, for a made-up day of two sessions: with the old formula it
  shows the hook before the night and the overshoot after it, as in the
  report, and with the fix neither. Six other made-up shapes were drawn
  both ways from a copy of the two formulas. Evenly spaced points and two
  points come out identical; daily closes with weekends differ by control
  points moved at most 2.3 points, with no visible change of shape; six
  unevenly spaced points, three sessions with two nights, and three points
  each lose a backward movement of 15.1, 7.3 and 1.3 points.

  Not checked on real data: the Mac that showed the fault runs the released
  3.7.0, and the fix reaches an installed app only through a release.
- Review: read by the author of the change, together with the arithmetic
  for why the line cannot turn back (a piece of curve whose two control
  points lie in order between its end points only moves forward). No
  independent review, for about twenty lines of drawing arithmetic whose
  result was looked at directly in seven shapes.
- Known issues: none in the change. The benchmark marked rows for code it
  never ran; see the record above.
- Verdict: retained. It is a correctness fix, the benchmark does not run
  its code, and no row moved in both of its two runs.

### 96: Record milestone 1: every merged change measured against the baseline

- What: the [Milestone 1](#milestone-1-2026-11-12) section above, the
  measured results of plan items 8, 9, 11 and 12, plan item 13, four rows
  in "Tried and rejected", and the merge line of pull request 95. Only this
  file changes.
- Merged: 2026-11-12, squash commit `dd56915`
- Benchmark: no before/after run. No file that goes into the app changes
  (nothing under `Stockbar/`, `StockbarTests/` or `Stockbar.xcodeproj`), so
  before, `c3c21ec`, and after build the same app. What this pull request
  records are the milestone's own measurements: the comparison of `47c1bda`
  with `c4f4cff` and the two soak runs, all under Milestone 1.
- Testing: 710 XCTest tests with 0 failures, 66 Python helper tests and 75
  script tests pass, and `checks`, `docs-check` and `build-release` pass, on
  this pull request's branch.
- Review: read by its author, with each figure checked again against the
  result files it comes from. No independent review, for a record of
  measurements that changes no code.
- Known issues: two things in the soak runs are not explained. The baseline
  held 6.8 MB more allocated than in its soak of the night before, and both
  runs used about four times the CPU of that earlier soak. See the notes
  under the soak's table.
- Verdict: retained.

### 97: Add an Experimental update channel that follows the experimental branch

- What: a feature the owner asked for, not an optimisation. **Settings →
  General → Updates** offers a third update channel, Experimental, beside
  Stable and Testing. Someone who chooses it is offered every build of the
  `experimental` branch.

  In the app, `UpdateChannel` gains `experimental`. That channel reads a
  second update feed, whose address is the new `StockbarExperimentalFeedURL`
  key of `Info.plist`; the updater's delegate hands it to Sparkle each time
  Sparkle checks. Stable and Testing read the feed they always have. In a
  test or acceptance run the second feed is read only when it is served
  from this Mac, the rule the first feed already follows.

  In the release workflow, a push to `experimental` is built, signed and
  published the way a push to `testing` is: as a prerelease, tagged
  `experimental-<build>`, and listed in a feed of its own, `appcast.xml` on
  a new `appcast-experimental` branch. A branch whose name starts
  `release-test/experimental` is a dry run of such a build and publishes
  nothing.

  The build number is `<base>.<A>.<M>`: the build of the last version tag,
  then the number of commits since that tag that `testing` also has, then
  the number it does not have. The head of `experimental` as this pull
  request was written would be 370.0.11. An experimental build therefore
  sorts above the testing build it contains and below the next one. The
  number depends on where `testing` is when the build is made, so only the
  newest commit of `experimental` is built. When `experimental` is moved
  onto a tagged commit, that commit is published to the channel as
  `<base>.0.0`, which Sparkle treats as the release itself; that is how a
  release reaches the channel.

  The builds have a feed of their own because the copy of
  `Scripts/release_feed.py` on `testing` and `main` refuses to rewrite a
  feed that holds a channel it does not know. In a shared feed the first
  experimental build would have stopped testing builds and releases from
  being published. The script now refuses to list the two kinds together,
  in either direction.

  Behaviour changes for the builds that already exist. All are in the step
  that removes superseded prereleases, which both kinds of build now share,
  except the last:

  - Given an empty feed, or the other kind's feed, the step now fails. It
    used to remove every `testing-` prerelease.
  - It removes only prereleases tagged `testing-<build number>`. A
    `testing-` tag that does not end in a build number is left alone.
  - A tag that spells a listed build number differently (`360.04` for
    `360.4`) is kept. It used to be removed.
  - The release notes of a testing build look for the previous build among
    tags matching `testing-[0-9]*` where they matched `testing-*`.

  Everything else about a testing build, a release and an ordinary dry run
  is as before: the same build numbers, tags, titles and feed, checked by
  the review on made-up histories and feeds (see Review).
- Merged: not merged. Open for the owner's word, because merging publishes
  the first experimental build. The date and squash commit are filled in by
  the pull request after it.
- Benchmark: before `dd56915`, after `fab1363`, six launches a side in turns
  on 2026-11-12, 21:10 to 21:43 UTC, on macOS 27.2.1 and mains power, all
  twelve launches with the screen unlocked and the display awake. Named in
  advance: no row expected to move. The benchmark runs the app isolated,
  where the updater does not start, so the delegate that chooses the feed
  is never created. The only new code a launch runs is the read of one more
  value from the bundle's `Info.plist`.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 101.8 (100.5 to 102.4) MB | 102.8 (100.4 to 103.5) MB | +1.1 MB, +1.1% | no measurable change (p = 0.141) |
  | Idle memory the app holds allocated | 57.1 (55.5 to 57.9) MB | 57.3 (55.1 to 57.9) MB | +0.1 MB, +0.3% | no measurable change (p = 0.981) |
  | Peak memory, launch and history load | 251.2 (243.1 to 256.8) MB | 255.9 (248.0 to 260.8) MB | +4.8 MB, +1.9% | no measurable change (p = 0.387) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.0) MB | 0.0 (0.0 to 0.2) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.204 (0.174 to 0.210) s/min | 0.197 (0.189 to 0.210) s/min | -0.007 s/min, -3.4% | no measurable change (p = 0.329) |
  | Idle CPU wake-ups | 24 (23 to 25) /min | 26 (24 to 29) /min | +2 /min, +8.3% | possibly higher (p = 0.022) |
  | Idle CPU power | 3.54 (3.42 to 3.82) mW | 3.84 (3.50 to 4.54) mW | +0.30 mW, +8.5% | no measurable change (p = 0.104) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.55 (0.50 to 0.65) s | 0.55 (0.51 to 0.60) s | -0.01 s, -0.9% | no measurable change (p = 0.846) |
  | Launch to history loaded | 0.56 (0.54 to 0.79) s | 0.56 (0.53 to 0.57) s | -0.00 s, -0.9% | no measurable change (p = 0.567) |
  | CPU from launch to the idle window | 2.09 (2.01 to 2.35) s | 2.04 (1.98 to 2.11) s | -0.05 s, -2.6% | no measurable change (p = 0.290) |
  | CPU energy from launch to the idle window | 6.28 (6.14 to 6.44) J | 6.13 (5.98 to 6.40) J | -0.14 J, -2.2% | no measurable change (p = 0.193) |
  | Python helper start to ready, no network | 0.28 (0.28 to 0.54) s | 0.29 (0.28 to 0.47) s | +0.01 s, +1.8% | no measurable change (p = 0.924) |
  | Python helper start, CPU | 0.28 (0.27 to 0.34) s | 0.28 (0.27 to 0.32) s | +0.01 s, +1.8% | no measurable change (p = 0.680) |
  | Python helper memory once started | 71.0 (70.9 to 71.0) MB | 71.0 (70.9 to 71.0) MB | +0.0 MB, +0.1% | no measurable change (p = 1.000) |

  Fourteen rows show no measurable change. Idle CPU wake-ups came out
  "possibly higher", 26 a minute against 24 (p = 0.022). Nothing this pull
  request adds runs while the benchmark's app idles, and a "possibly" row
  needs a repeat before it counts either way.

  Repeat, 21:46 to 22:19 UTC, with the same two commits under the same
  conditions:

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 100.2 (97.9 to 103.7) MB | 99.1 (98.1 to 100.4) MB | -1.1 MB, -1.0% | no measurable change (p = 0.554) |
  | Idle memory the app holds allocated | 54.9 (45.6 to 57.5) MB | 54.8 (54.3 to 55.5) MB | -0.1 MB, -0.1% | no measurable change (p = 0.974) |
  | Peak memory, launch and history load | 245.6 (240.1 to 256.1) MB | 244.8 (243.3 to 245.7) MB | -0.8 MB, -0.3% | no measurable change (p = 0.777) |
  | Idle memory growth across the window | 0.0 (-0.0 to -0.0) MB | 0.0 (0.0 to 0.0) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.079 (0.070 to 0.191) s/min | 0.079 (0.068 to 0.084) s/min | +0.001 s/min, +0.6% | no measurable change (p = 0.630) |
  | Idle CPU wake-ups | 26 (23 to 28) /min | 24 (24 to 25) /min | -2 /min, -7.7% | possibly lower (p = 0.050) |
  | Idle CPU power | 4.21 (4.08 to 4.50) mW | 4.09 (3.95 to 4.41) mW | -0.12 mW, -2.9% | no measurable change (p = 0.329) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.55 (0.51 to 0.55) s | 0.55 (0.53 to 0.56) s | +0.00 s, +0.0% | no measurable change (p = 0.387) |
  | Launch to history loaded | 0.59 (0.54 to 0.62) s | 0.59 (0.57 to 0.61) s | +0.01 s, +0.8% | no measurable change (p = 0.524) |
  | CPU from launch to the idle window | 1.97 (1.81 to 2.12) s | 1.82 (1.81 to 1.87) s | -0.15 s, -7.6% | possibly lower (p = 0.043) |
  | CPU energy from launch to the idle window | 6.19 (5.97 to 6.46) J | 5.97 (5.90 to 6.12) J | -0.21 J, -3.4% | possibly lower (p = 0.026) |
  | Python helper start to ready, no network | 0.28 (0.28 to 0.54) s | 0.28 (0.28 to 0.46) s | +0.00 s, +0.0% | no measurable change (p = 0.697) |
  | Python helper start, CPU | 0.28 (0.28 to 0.34) s | 0.28 (0.28 to 0.32) s | +0.00 s, +0.0% | no measurable change (p = 0.697) |
  | Python helper memory once started | 71.0 (71.0 to 71.4) MB | 71.0 (70.9 to 71.0) MB | +0.0 MB, +0.0% | no measurable change (p = 0.273) |

  In the repeat idle CPU wake-ups came out "possibly lower", 24 a minute
  against 26 (p = 0.050), the opposite of the first run. CPU and CPU energy
  from launch to the idle window came out "possibly lower" as well (p =
  0.043 and 0.026); in the first run both were "no measurable change" (p =
  0.290 and 0.193). No row moved in both runs, so this pull request made no
  measurable change, as named in advance. The first run's launches used
  about two and a half times the idle CPU of the repeat's, 0.20 against
  0.08 s/min on both sides, which is the Mac's state and not the build.

  An earlier attempt, started at 20:43 UTC, was cut short after six of its
  twelve launches when the tool that had started it restarted. Its launches
  are not used.

  Not measured: an update check on the Experimental channel. It is the same
  single request the other channels make, to a different address, and the
  benchmark runs with the updater off. The 30-minute soak is deferred to
  the next milestone.
- Testing: 717 XCTest tests with 0 failures (seven new), 66 Python helper
  tests and 89 script tests (fourteen new) pass, and `checks`, `docs-check`
  and `build-release` pass, all at `fab1363`.

  The new Swift tests cover which feed each channel reads, the rule for
  isolated runs, that the updater's delegate answers the Objective-C method
  Sparkle asks for the feed, that both shipped feed addresses are the
  branches the feed script publishes to, and that Sparkle's own comparison
  puts build numbers in the order the feed script's tests sort them. The new
  script tests cover the numbering, the skip of a commit the branch has
  moved on from, the tagged commit, the separate feeds and the removal of
  superseded builds.

  Tried end to end on this Mac at the first commit, `0f3a2e5`, with a
  scratch copy of the Release build under another bundle identifier, two
  feeds served from this Mac and a throwaway signing key. The project's own
  scripts signed four builds and wrote both feeds. Launched once on each
  channel, the copy asked for the ordinary feed on Stable and Testing and
  for the experimental feed on Experimental. In its Settings window the
  channel picker offered all three; running build 370.0.1, it was offered
  370.0.2 on Experimental, 370.1 on Testing and nothing on Stable, and a
  change of channel made it check again without a restart. The trial
  stopped at the offer: no update was installed from an experimental feed.
  `script/package_release.sh` packaged a build numbered 370.0.1, and its
  start check passed. The installed app was not touched, and everything the
  trial left behind was removed.

  The workflow's steps were run on this Mac for a push to `experimental`,
  to `testing`, to both kinds of dry-run branch and for a version tag, and
  again in throwaway repositories after the review's fixes: a branch moved
  onto a tagged commit, a commit the branch has moved on from, a second
  branch whose name ends the same way, and a version tag that `testing`
  does not have yet.

  Not tested: the workflow on GitHub. It cannot run there until this is
  merged or a `release-test/experimental…` branch is pushed, and both wait
  for the owner. Signing with the real update key, creating the
  `appcast-experimental` branch and publishing a prerelease happen for the
  first time in that first run.
- Review: one independent review by Opus of the first commit, by a reviewer
  that had not seen the implementation. It found no blocking defect, one
  fault worth fixing and several smaller points. Each was confirmed before
  it was acted on, and the fixes are the second commit, `fab1363`:

  - A push that moves `experimental` onto a tagged commit was skipped, as it
    is on `testing`, so a release would never have been offered on the
    channel. It is now published there as `<base>.0.0`.
  - The tests and the development notes said 360.9.0 sorts above 360.9.
    Sparkle's own comparison, run against the project's copy of Sparkle,
    calls them equal. The tests and notes are corrected, and a Swift test
    now asks Sparkle for the order.
  - The check that a commit is still the newest of its branch matched
    branch names by their ending. It could only have skipped a build
    wrongly, never published one. It now matches the whole name.
  - "How this branch works" in this file said that no workflow runs for
    `experimental`. Corrected below.

  The review also confirmed, on throwaway repositories and 300 made-up
  feeds, that the plan for a testing build, a release and an ordinary dry
  run is unchanged apart from one new line of output, that the ordinary
  feed is written byte for byte as before, and that experimental build
  numbers only rise as the two branches move, short of a force-push.
- Known issues, all consequences of the design:
  - The Experimental channel is offered experimental builds only. A release
    or a testing build reaches it once `experimental` contains it.
  - After a new version tag, a push to `experimental` fails in the
    workflow's first step until the tag is in the branch's history. The
    same rule already holds for `testing`.
  - After `experimental` is merged into `testing` with a merge commit, its
    builds are numbered below the testing build that merge made, until
    `testing` is brought back into `experimental`.
  - Every push to `experimental` publishes a build, including a merge that
    changes only this file.
  - The released 3.7.0 has no Experimental option. The first experimental
    build has to be installed by hand from its prerelease page; from then
    on the channel updates itself.
  - A build from before this change that finds the Experimental channel
    stored reads it as Stable. That can only follow a downgrade by hand,
    and the choice comes back with the next build that knows the channel.
  - Pre-existing, not changed here: a release run and a testing run are not
    kept apart, so a release's clean-up could remove a testing prerelease
    created at the same moment.
- Verdict: open for the owner's decision. Recommended: retain, and merge
  when the owner is ready for experimental builds to be published.

## Rust evaluation, 2026-11-12

No component was moved to Rust, and none is recommended. The one place where
a rewrite would save a large amount is the Python helper, and that saving
comes from leaving Python, not from arriving at Rust: Swift reaches the same
floor with the toolchain the app already has. Whether the market data fetch
should leave Python at all is a larger question, set out at the end for the
repository owner. Nothing here has been built beyond two ten-line programs
that start and wait.

### Candidates

| Candidate | What Rust could save | Finding |
| --- | --- | --- |
| The Python helper: `stockbar_worker.py` running `get_stock_data.py` and `get_ohlc_data.py` | At most what the helper holds: 92.1 MB on real data, all of the time (pull request 86) | Measured below. A compiled helper starts from 1 to 3 MB in either language |
| Arithmetic inside the app: history thinning, risk and attribution figures | Nothing found | The app is compiled Swift. Rust would run the same arithmetic over the same data and add a C boundary with copies across it. Idle CPU is 0.082 s/min, so there is nothing to win at idle; what the 2.29 s of launch CPU is spent on is not profiled yet (planned item 9). Both figures are the "after" side of pull request 87's comparison, which is the current `experimental`. This row is reasoning, not a measurement, and is reopened if that profile finds a loop of the app's own |
| Reading and storing history | Nothing found | The cost is in Core Data and in what the app keeps of what it reads. The carried-over changes cut both in Swift. Rust cannot replace the store without replacing Core Data |

### What the helper's memory is made of

`Scripts/perf/helper_layers.py` against the helper's own interpreter (Python
3.13, yfinance 1.8.0), five starts a row, 10:33 UTC, nothing fetched:

| Process | Memory held: median (range) of 5 starts | CPU to ready | Time to ready |
| --- | --- | --- | --- |
| Interpreter only | 6.5 (6.5 to 6.6) MB | 0.01 (0.01 to 0.02) s | 0.01 (0.01 to 0.04) s |
| + the standard library modules the helper uses | 12.1 (11.9 to 12.1) MB | 0.03 (0.03 to 0.03) s | 0.03 (0.03 to 0.05) s |
| + requests | 20.4 (20.4 to 20.4) MB | 0.06 (0.06 to 0.07) s | 0.07 (0.06 to 0.09) s |
| + pandas | 57.2 (57.1 to 57.4) MB | 0.22 (0.21 to 0.25) s | 0.22 (0.21 to 0.36) s |
| + yfinance: everything the helper imports | 70.6 (70.5 to 70.6) MB | 0.29 (0.29 to 0.30) s | 0.29 (0.29 to 0.34) s |
| Compiled Swift program with a URLSession and a JSON decoder ready | 2.4 (2.4 to 2.5) MB | 0.01 (0.01 to 0.01) s | 0.01 (0.01 to 0.18) s |
| Compiled Rust program, standard library only | 1.2 (1.2 to 1.2) MB | 0.00 (0.00 to 0.00) s | 0.00 (0.00 to 0.15) s |

- pandas accounts for 36.8 MB and yfinance for a further 13.4 MB: 50.2 MB of
  the 70.6 MB. The helper uses pandas only through the tables yfinance
  returns.
- After real fetches the helper holds more than it does straight after its
  imports: 92.1 MB in the sample of the installed app.
- The Rust program has no HTTP client, so a real Rust helper holds more than
  1.2 MB. That is not measured: it needs third-party crates, which were not
  downloaded. Neither floor has fetched anything.

### Why not Rust for the helper

- The two floors are 1.2 MB apart. Leaving Python saves 68 MB or more in
  either language.
- Swift code can do the fetch inside the app with `URLSession`, as the app
  already does for exchange rates, Folync and Trading 212. There is then no
  helper process, no 0.29 s of CPU to start one, and no second executable to
  sign. Rust would be a second process, or a library behind a C bridge with
  its own networking runtime inside the app.
- Rust adds a second toolchain to every build. `rustc` 1.99.1 is installed on
  this Mac through `rustup` but is not on the `PATH`; the GitHub workflows
  would need it as well, and the release workflow is outside what this branch
  may change. It also adds third-party crates to keep current.
- One point does favour Rust. Yahoo has no official interface, and maintained
  Yahoo clients exist as crates: `yfinance-rs`, which describes itself as a
  port of the Python library (0.9.1 on docs.rs), and `yahoo_finance_api`
  (4.1.0, with cookie and crumb handling in its source). For Swift a search
  found one package, SwiftYFinance, last released in March 2025. This comes
  from a web search on 2026-11-12. Neither crate was built or run, and how
  quickly they follow Yahoo's changes was not checked.

### The larger question: should the fetch leave Python?

What it would bring, on real data. The "now" figures are measured (pull
request 86); the rest is expected, not measured.

- Memory: the app and helper together hold 175.1 MB on average now, 92.1 MB
  of it the helper. Pull request 86 brings that to about 114 MB. With no
  helper it is about 83 MB plus whatever the fetch adds to the app.
- No Python environment: 123 MB in 5,013 files under Application Support
  today, with its set-up step, its missing-package alert and its own security
  updates.
- About 890 lines of Swift that exist to run Python (`PythonWorkerPool`,
  `PythonProcessRunner`, `PythonEnvironmentSetup`) would go.

What it would cost.

- 1,712 lines in `get_stock_data.py` and 213 in `get_ohlc_data.py`, with 759
  lines of tests, rewritten and shown to give the same answers. Twelve Data
  and Financial Modeling Prep are documented JSON interfaces and carry little
  risk.
- Yahoo is the risk. The helper asks yfinance for daily and intraday history,
  and for the market state and the pre-market and after-hours prices, which
  come from an endpoint that wants a session cookie and a token. yfinance
  1.8.0 requires `curl_cffi`, a library for making requests with a browser's
  network fingerprint. A native client takes that upkeep over from yfinance's
  maintainers. Whether Yahoo accepts `URLSession` as it is can only be found
  out against the live service.
- The tests here must not contact live providers, so equivalence needs
  recorded responses plus a supervised comparison against the live services.

The options:

| | Option | Memory, app and helper | Risk |
| --- | --- | --- | --- |
| A | Keep Python and take pull request 86 | about 114 MB on average (expected) | Smallest: one timeout value to tune |
| B | Fetch in Swift, with the Python helper kept as the fallback when a native fetch fails | about 83 MB while the native fetch works (expected) | Two implementations to keep until the native one has earned trust |
| C | Fetch in Swift and remove Python | about 83 MB (expected) | Largest: no fallback if Yahoo turns the native client away |
| D | A Rust helper on `yfinance-rs` | a few MB more than C (not measured) | Yahoo upkeep shared with the crate's one maintainer; the build and release costs above |

Recommended: A now. Then B in stages if the remaining 30 MB or so and the
end of the Python set-up are wanted, starting with a supervised trial of a
Swift fetch against Yahoo, since that settles whether C is reachable or D is
the candidate. B, C and D change where every price comes from, so none of
them starts without the repository owner's decision.

## Tried and rejected

| Idea | When | What was measured | Why dropped |
| --- | --- | --- | --- |
| Hand freed launch memory back to the system with `malloc_zone_pressure_relief` after the launch load | 2026-11-11, before the transition | It released 0 bytes in all 11 calls, and idle footprint stayed inside its usual spread | The allocator does not return those pages on request. Idle footprint comes down by lowering what the launch allocates, not by asking afterwards. Never committed |
| Move a component to Rust | 2026-11-12, pull request 88 | A compiled helper starts from 1.2 MB in Rust (standard library only) and 2.4 MB in Swift (with `URLSession` ready), against 70.6 MB for the Python helper after its imports | The saving comes from leaving Python, and Swift reaches it with the app's own toolchain and without a helper process. Nothing inside the app was found that Rust would make faster or smaller. See [Rust evaluation](#rust-evaluation-2026-11-12) |
| Precompiled bytecode for the Python helper's own scripts | 2026-11-12, plan item 8 | Compiling all three scripts takes 8.2 ms of a 330 ms helper start | About 2 percent of the start, for a build step and files to keep in step with the scripts. Never written |
| Thin only the newly aged part of each price series after a recorded snapshot | 2026-11-12, plan item 11 | A full pass costs 32.6 ms on the main actor for each recorded snapshot at the fixture's size, 0.0065 s/min at the default interval | The saving is about 2 s of CPU in a trading day, and it needs remembered state that every place replacing a series must keep true. Never written |
| Draw the main window's chart as one area plot and one line plot in place of a mark for every point | 2026-11-12, milestone 1 | Three launches of each build: Swift Charts' classes among the 27 largest fell from 5.02 MB to 4.38 MB (2.75 MB in one launch), and the untyped allocations it was meant to lower did not move (19.7 to 20.4 MB before, 20.2 to 20.6 MB after) | About 0.6 MB, for a change to how the chart is built that could be tried on one macOS version only. Appearance and VoiceOver were not compared. Never committed |
| Take the rolling-digit transition out of the main window's figures | 2026-11-12, milestone 1 | One launch of each build with allocations named: 6.52 MB of cached glyph bitmaps with the transition and 0.46 MB without | It removes an animation that is there on purpose, to empty a cache the system owns, and in normal use the app starts without a window. Six lines if the owner wants the memory more than the animation. Never committed |

## How this branch works

- `experimental` was created from `testing`. Nothing reaches `testing` or
  `main` from here without an explicit instruction; no releases, no changes to
  repository settings, no force-pushes or history rewrites. Once pull request
  97 is merged, at the owner's word, each push to `experimental` is published
  as an experimental build: a prerelease, offered only to people who chose
  the Experimental update channel.
- One optimisation is one branch (`perf/*`, `feature/*`, `refactor/*`,
  `rust/*`) from the latest `experimental`, one pull request, and one squash
  commit, so it can be read and reverted alone. A merged change is undone with
  `git revert` through a pull request.
- Every pull request carries its own before/after table from
  `bash Scripts/perf/compare.sh <before> <after>`, measured for that pull
  request. A row counts as "lower" or "higher" below p = 0.01. Between 0.01
  and 0.05 it is "possibly" and needs a repeat. Anything else is "no
  measurable change". Each pull request names the rows it is meant to move.
  A row that moves without having been named is repeated before it counts,
  whatever its p value: pull request 95 had three such rows across two runs,
  for code the benchmark never runs.
- Merge bar: the app builds cleanly, no new test failures, the affected
  behaviour still works, the benchmark record is complete, no known
  regression. A change that trades one metric for another stays open for a
  decision. A performance change with no measurable benefit is not merged.
- The CI workflow does not run for `experimental` or for pull requests into
  it, so every check is run locally: `bash script/develop.sh test`, `checks`,
  `python-tests`, `build-release`, and
  `python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py'`. From
  pull request 97 on, the release workflow does run for a push to
  `experimental`. It builds and publishes the newest commit and runs none of
  the tests.
- Checkpoint tags are named `experimental-checkpoint-<date>-<name>`. The
  release workflow reacts to `vX.Y.Z` tags and reads tags of the form
  `testing-<build>` and `experimental-<build>`, where the build starts with a
  digit. A checkpoint tag is none of these.
- The merge date and squash commit of a pull request are filled in by the next
  pull request, since they do not exist until after the merge.

## The transition, 2026-11-11

- `experimental` was created from `origin/testing` at `47c1bda` and pushed.
  That commit has the same files as `origin/main` (`75be612`), which is one
  merge commit ahead.
- `origin/main` was `75be6125b0f0` and `origin/testing` `47c1bdac9159` before
  and after.
- The earlier work was eight unpushed commits on a local branch based on
  `75be612`. It was moved, file for file, onto branches from `experimental`:
  `perf/benchmark-baseline` (pull request 84), `perf/helper-idle-exit`,
  `perf/release-without-coverage`, `perf/batched-history-read`,
  `perf/chart-values-read` (stacked on the batched read: both edit the same
  file and test class) and `perf/fitted-price-arrays`. The earlier log,
  `Docs/perf_2026-11-11.md`, is replaced by this file and was not carried over.
- Automation: the CI workflow runs for `main` and `testing` only; the release
  workflow for pushes to `testing`, `release-test/**` branches and `vX.Y.Z`
  tags; the Python lock update on a Monday schedule. None ran for any push
  made here. One ruleset blocks deletion and force-pushes on `main` and
  `testing`. GitHub deletes a merged pull request's branch itself.

## Before the transition

Earlier the same day the carried-over changes were measured together, against
`75be612`, with an earlier version of the benchmark. Those figures are not
repeated here: each change is measured again in its own pull request. Three
findings from that work shape the plan and are not visible in the isolated
benchmark:

- On real data the Python helper was running all of the time with the 15
  minute idle timeout and about a third of the time with 90 seconds, at the
  default five minute refresh. The helper holds about as much memory as the
  app.
- The idle footprint in the benchmark is bimodal on the baseline (roughly 100
  or 130 MB from launch to launch), because the allocator keeps or returns
  freed launch memory. The allocated-heap figure is the steadier one.
- The launch peak in the benchmark is mostly graphics memory for the first
  window, not the history load. On real data, where no window opens at launch,
  the history load is the peak.

Unrelated problems noticed and left alone: `MemoryManagementService` compares
resident size, not footprint, with its thresholds; `PythonWorker.stop()` sends
SIGTERM straight after closing stdin; acceptance and benchmark runs leave
`com.stockbar.acceptance` entries in `~/Library`; acceptance mode logs the
missing helper as an error; the popover chart reloads several times during
launch.

## Who did what

| Work | Model | How it went |
| --- | --- | --- |
| Transition, benchmark tooling, baseline, this log | Fable (orchestrator) | Done directly: git work and measuring, nothing to hand off |
| Before the transition: independent reviews of the helper change and of the history-read changes | Opus | Worth it both times. No defects; each found a real gap in the tests, since closed |
| Pull request 85 | Fable (orchestrator) | Done directly: a one-line scheme change, reviewed by reading the diff and inspecting the two builds |
| Pull request 87 | Fable (orchestrator) | Re-measured and re-read directly. The change itself was reviewed by Opus before the transition |
| Pull request 88, the Rust evaluation | Fable (orchestrator) | Done directly: measuring, two web searches and the write-up |
| Pull request 89 | Fable (orchestrator), with two independent reviews by Opus | Worth it. The first review found a real defect: a slow launch read could undo the UK price scale repair for the session. It was fixed, with tests, before the comparison. The second review, of the fix, found no defect and pointed out a behaviour change the description had missed |
| Pull request 90 | Fable (orchestrator), with one independent review by Opus | Worth it. The change was written before the transition. The review read the branch after `experimental` was merged into it and caught that the tests no longer compiled, before a build had been spent finding out |
| Pull request 91 | Fable (orchestrator) | Done directly: a dozen lines of shell and one test |
| Pull request 92 | Fable (orchestrator) | Done directly. The change was written before the transition; it was re-read, trimmed of the code it replaces and corrected after its first measurement |
| Pull request 93 | Fable (orchestrator) | Done directly. The carried-over change was nine lines; reading the append path before measuring showed it would undo itself in use, and the step growth and two tests were added |
| Pull request 94, open for a decision | Fable (orchestrator) | Done directly: seven lines of shell, two tests and a paragraph of documentation, tried by hand on a build with the counters and one without |
| Pull request 95 | Fable (orchestrator) | Done directly: found from the owner's screenshot and the drawing code, then checked by drawing the app's own chart view with the old formula and the new. A probe build showed the benchmark never draws that chart, which settled three rows the benchmark had marked |
| Milestone 1: the comparison, the soaks, the launch with allocations named and the two trial builds | Fable (orchestrator) | Done directly. Each step was a measurement to read before choosing the next, with nothing independent to hand to a subagent |
| Pull request 97, the Experimental update channel, open for a decision | Fable (orchestrator), with a check of the Settings window by Sonnet and one independent review by Opus | Sonnet was used at the owner's instruction for driving the screen: it worked through the trial copy's Settings window and reported what each channel was offered, in 53 tool calls and about 138,000 tokens. The Opus review was worth it: it found that a release would never have reached the channel and that the tests and notes had Sparkle's ordering wrong, in 62 tool calls, about 250,000 tokens and fifteen minutes |

Haiku has not been used, and Sonnet once, for pull request 97: nothing else
so far has been parallel or self-contained enough to repay a cold start, and
most of the elapsed time is benchmark runs, which no model speeds up.
