# Measuring Stockbar's resource use

Four tools, all run from the repository root. None of them needs administrator
rights, and none touches the real portfolio except the first, which only reads
counters from an app that is already running.

| Question | Tool |
| --- | --- |
| What is the app I am running using right now? | `Scripts/measure_performance.sh` |
| What does this checkout use, on fixed data? | `Scripts/perf/benchmark.sh` |
| Did a change make a difference? | `Scripts/perf/compare.sh` |
| What is the Python helper's memory made of? | `Scripts/perf/helper_layers.py` |

The results of the optimisation work, and the baseline they are compared with,
are in [the experimental log](../EXPERIMENTAL_LOG.md).

## A running app: `measure_performance.sh`

```bash
bash Scripts/measure_performance.sh                 # ten minutes
bash Scripts/measure_performance.sh --duration 60   # a quick look
```

Samples the running Stockbar and its Python helper: memory (physical
footprint, the figure Activity Monitor shows), how much of the time the helper
was running, CPU seconds, wake-ups and disk writes per minute. It reads kernel
counters and never pauses or signals the app. Leave the app alone for an idle
figure. This is the only tool that sees the helper at work and real refreshes,
so its figures depend on the portfolio, the network and the time of day: use
it to look, not to compare two builds.

## One build on fixed data: `benchmark.sh`

```bash
bash Scripts/perf/benchmark.sh --label my-change
```

Builds the Release configuration as a separate app (`com.stockbar.acceptance`)
and runs it in the isolated acceptance mode: its own storage below the
temporary folder, live providers off, no Keychain. It fills that storage with
synthetic history (`Scripts/perf/make_fixture.py`: 11 holdings, 7,000 portfolio
snapshots of 15 positions, about 70,000 prices), does one warm-up launch, then
measures five launches. A window and menu-bar items appear for each launch and
go when it is stopped; the Mac and its display are kept awake meanwhile.

For every launch it records:

| Figure | What it is |
| --- | --- |
| `app_footprint_mb_median` | Idle memory: physical footprint over a 60 s window that starts 75 s after launch |
| `app_heap_allocated_mb` | Bytes the app holds allocated at the end of the window. Steadier than the footprint, which also counts freed pages not yet handed back |
| `app_lifetime_peak_mb` | The most memory the app held at any point: the launch, the first window and the history load |
| `app_footprint_drift_mb` | Later half of the idle window against the earlier half. Use a long `--window` for this |
| `app_cpu_s_per_min`, `app_wakeups_per_min` | Idle CPU time and CPU wake-ups |
| `app_power_mw` | Idle CPU power, from the kernel's per-process energy estimate |
| `app_cpu_s_before_window`, `app_energy_j_before_window` | CPU time and CPU energy from launch to the start of the idle window |
| `launch_to_window_s` | Launch until the main window is on screen |
| `launch_to_history_s` | Launch until the stored portfolio history is loaded |
| `helper_start_s`, `helper_start_cpu_s`, `helper_footprint_mb` | One start of the Python helper to the point it can take a request, with no network: the local part of a quote refresh |

Beside the summary it keeps the app's log and, for each launch, the figures,
the memory samples, a breakdown by kind of memory (`footprint`) and the largest
heap classes (`heap`), in `build/bench/results/`.

A soak run is the same thing with one long window:

```bash
bash Scripts/perf/benchmark.sh --label soak --runs 1 --window 1800
```

## Two commits against each other: `compare.sh`

```bash
bash Scripts/perf/compare.sh experimental HEAD --label my-change
```

Exports and builds each commit (never the uncommitted working tree), then
measures them in turns: before, after, after, before. It prints the table a
pull request carries: for every figure the median and range of each side, the
change, and a verdict from a rank-sum permutation test over the launches.
Below p = 0.01 a row is "lower" or "higher". Between 0.01 and 0.05 it is
"possibly lower" or "possibly higher": the table has fifteen rows, and the
same commit measured against itself reaches that on some row often enough
(it did in the baseline) that such a row needs a repeat before it counts.
Anything else is "no measurable change". The default is six launches a side
and takes about 35 minutes. Four a side can reach "possibly" at best, and
with fewer nothing can be told apart.

Comparing a commit with itself shows the noise of the method.

Do not build, run tests or use the Mac heavily while either benchmark runs,
and do not edit the scripts in `Scripts/perf/` until it has finished.

## What the Python helper holds: `helper_layers.py`

```bash
python3 Scripts/perf/helper_layers.py \
  "$HOME/Library/Application Support/Stockbar/python-env/bin/python" \
  build/bench/bin/proc_usage
```

Starts the helper's interpreter with one more layer of its imports each time
(the interpreter alone, the standard library modules, `requests`, `pandas`,
`yfinance`) and prints the memory each holds once the imports are done, with
the CPU and time that took. Nothing is fetched. `build/bench/bin/proc_usage`
is the sampler either benchmark builds on its first run.

To set a helper with no interpreter beside them, compile the two floor
programs and pass each with `--floor`:

```bash
xcrun swiftc -O Scripts/perf/native_floor.swift -o build/bench/bin/native_floor_swift
rustc -O Scripts/perf/native_floor.rs -o build/bench/bin/native_floor_rust
python3 Scripts/perf/helper_layers.py <interpreter> build/bench/bin/proc_usage \
  --floor "Swift, URLSession ready=build/bench/bin/native_floor_swift" \
  --floor "Rust, standard library only=build/bench/bin/native_floor_rust"
```

A floor is a program that writes one line and waits, so it shows where a
compiled helper starts from, not what it holds after fetching. The Rust one
needs `rustc`, which no other part of the project uses.

## What these do not measure

- Whole-system battery drain. `app_power_mw` covers the CPU work the kernel
  bills to the process; the display, the graphics processor and the network
  are left out. `sudo powermetrics --samplers tasks,battery -i 10000 -n 60`
  gives the whole-system view.
- How smooth the interface is: dropped frames, or how long a click takes to
  show. Instruments does this (Time Profiler, Hangs or SwiftUI templates)
  against the Release build.
- A quote refresh over the network, or the helper's lifetime between
  refreshes. Acceptance mode never starts the helper, so only
  `measure_performance.sh` against the real app sees them, and the provider
  and the network are part of what it then measures.
