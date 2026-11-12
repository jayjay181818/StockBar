# Stockbar experimental log

The record of the optimisation work on the `experimental` branch: the baseline,
what each pull request changed and measured, and what was tried and dropped.
It changes only through pull requests into `experimental`.

To resume this work, read this file and the open pull requests into
`experimental` before anything else. The rules of the branch are in
[How this branch works](#how-this-branch-works).

## Where things stand

Four changes are merged.

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

Waiting for a decision:

- Pull request 86, where the idle Python helper exits after 90 seconds. It
  trades memory for CPU.
- Whether the market data fetch should leave Python. The
  [Rust evaluation](#rust-evaluation-2026-11-12) sets out the options; no
  component was moved to Rust.

This comparison is re-measured, baseline commit against the head of
`experimental` in turns on the same day, at each milestone. Figures from
different days are not set side by side, because the machine's state drifts.

| Measured | Baseline `47c1bda` | `experimental` now | Change |
| --- | --- | --- | --- |
| 2026-11-11 | see [Baseline](#baseline) | the same commit | none |

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
| Carried-over changes re-measured and merged one by one | Next |
| Stage 3 changes | After the carried-over changes |
| First checkpoint tag and soak run against the baseline | After the carried-over changes |
| Recommendation to promote to `testing` | Not yet |

### Planned next, in order

1. Done in pull request 85: release builds without test-coverage counters.
   The branch also carried a check in `script/package_release.sh` that refuses
   an instrumented binary. That is a change to the release packaging step, so
   it came off the branch and becomes a separate pull request that stays open
   for a decision.
2. Open as pull request 86, waiting for a decision: the idle Python helper
   exits after 90 seconds. It trades memory for CPU, and its effect shows only
   on real data.
3. Done in pull request 87: portfolio history read in batches.
4. Done in pull request 89: stored history read at launch away from the main
   actor.
5. Popover chart reads values without positions (`perf/chart-values-read`).
6. Price history arrays sized to fit (`perf/fitted-price-arrays`).
7. Done in pull request 90: compact storage for the positions kept with every
   portfolio snapshot, which were the largest single block of the idle heap.
8. The Python helper's start-up cost: precompiled bytecode, and retiring the
   helper straight after a refresh.
9. The graphics memory of the first window, and AppKit's Writing Tools check
   during launch. Also why one and the same build idles near 105 MB after
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
10. Done in pull request 88: Rust evaluated, no migration recommended. See
    the [Rust evaluation](#rust-evaluation-2026-11-12).

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
- Merged: the date and squash commit are filled in by the next pull request
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

## How this branch works

- `experimental` was created from `testing`. Nothing reaches `testing` or
  `main` from here without an explicit instruction; no releases, no changes to
  repository settings, no force-pushes or history rewrites.
- One optimisation is one branch (`perf/*`, `feature/*`, `refactor/*`,
  `rust/*`) from the latest `experimental`, one pull request, and one squash
  commit, so it can be read and reverted alone. A merged change is undone with
  `git revert` through a pull request.
- Every pull request carries its own before/after table from
  `bash Scripts/perf/compare.sh <before> <after>`, measured for that pull
  request. A row counts as "lower" or "higher" below p = 0.01. Between 0.01
  and 0.05 it is "possibly" and needs a repeat. Anything else is "no
  measurable change". Each pull request names the rows it is meant to move.
- Merge bar: the app builds cleanly, no new test failures, the affected
  behaviour still works, the benchmark record is complete, no known
  regression. A change that trades one metric for another stays open for a
  decision. A performance change with no measurable benefit is not merged.
- No workflow runs for `experimental` or for pull requests into it, so every
  check is run locally: `bash script/develop.sh test`, `checks`,
  `python-tests`, `build-release`, and
  `python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py'`.
- Checkpoint tags are named `experimental-checkpoint-<date>-<name>`. The
  release workflow reacts to `vX.Y.Z` tags and reads `testing-*` tags; this
  matches neither.
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

Haiku and Sonnet have not been used: nothing so far has been parallel or
self-contained enough to repay a cold start, and most of the elapsed time is
benchmark runs, which no model speeds up.
