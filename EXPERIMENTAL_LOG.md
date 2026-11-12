# Stockbar experimental log

The record of the optimisation work on the `experimental` branch: the baseline,
what each pull request changed and measured, and what was tried and dropped.
It changes only through pull requests into `experimental`.

To resume this work, read this file and the open pull requests into
`experimental` before anything else. The rules of the branch are in
[How this branch works](#how-this-branch-works).

## Where things stand

One change is merged: release builds no longer carry test-coverage counters
(pull request 85). It made the executable 6.7 MB smaller and moved none of the
fifteen measured rows, so the figures under [Baseline](#baseline) still
describe how `experimental` runs.

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
2. Idle Python helper exits after 90 seconds (`perf/helper-idle-exit`). Its
   benefit shows only on real data; see [Not measured](#not-measured).
3. Portfolio history read in batches (`perf/batched-history-read`).
4. Read the stored history at launch off the main actor
   (`perf/launch-history-off-main`; it builds and passes every test, and is
   not yet measured).
   Before the transition, the changes below it left history ready about 0.3 s
   later at launch because the read waits on a busy main thread; this is meant
   to remove the wait.
5. Popover chart reads values without positions (`perf/chart-values-read`).
6. Price history arrays sized to fit (`perf/fitted-price-arrays`).
7. Compact storage for the positions kept with every portfolio snapshot, the
   largest single block of the idle heap (`perf/compact-positions`; it builds
   and passes every test, and is not yet measured).
8. The Python helper's start-up cost: precompiled bytecode, and retiring the
   helper straight after a refresh.
9. The graphics memory of the first window, and AppKit's Writing Tools check
   during launch.
10. Rust: evaluate honestly whether any component earns a language boundary.

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
- Merged: the date and squash commit are filled in by the next pull request
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

## Tried and rejected

| Idea | When | What was measured | Why dropped |
| --- | --- | --- | --- |
| Hand freed launch memory back to the system with `malloc_zone_pressure_relief` after the launch load | 2026-11-11, before the transition | It released 0 bytes in all 11 calls, and idle footprint stayed inside its usual spread | The allocator does not return those pages on request. Idle footprint comes down by lowering what the launch allocates, not by asking afterwards. Never committed |

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

Haiku and Sonnet have not been used: nothing so far has been parallel or
self-contained enough to repay a cold start, and most of the elapsed time is
benchmark runs, which no model speeds up.
