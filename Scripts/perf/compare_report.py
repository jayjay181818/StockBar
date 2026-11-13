#!/usr/bin/env python3
"""Turn the launches compare.sh measured into a before/after table.

    python3 Scripts/perf/compare_report.py <results folder> --before <commit> --after <commit>

The folder holds before-<round>/ and after-<round>/ as benchmark.sh writes
them. Each metric gets the median and the range of each side, the change in
the median, and a verdict from an exact two-sided rank-sum permutation test
over the launches: of all the ways of dealing the same figures out between the
two sides, how many separate them as far. Below 1% the row is "lower" or
"higher". Between 1% and 5% it is "possibly lower" or "possibly higher":
with fifteen rows, a commit measured against itself lands there on some row
in a good share of comparisons, so such a row wants repeating before it
counts. Anything else is "no measurable change".
"""
import argparse
import glob
import itertools
import math
import os
import random
import statistics

# key, what it is, unit, decimal places, how it is read
METRICS = [
    ("app_footprint_mb_median", "Idle memory (physical footprint)", "MB", 1, "proc_pid_rusage, idle window"),
    ("app_heap_allocated_mb", "Idle memory the app holds allocated", "MB", 1, "heap, after the window"),
    ("app_lifetime_peak_mb", "Peak memory, launch and history load", "MB", 1, "proc_pid_rusage"),
    ("app_footprint_drift_mb", "Idle memory growth across the window", "MB", 1, "proc_pid_rusage, idle window"),
    ("app_cpu_s_per_min", "Idle CPU", "s/min", 3, "proc_pid_rusage, idle window"),
    ("app_wakeups_per_min", "Idle CPU wake-ups", "/min", 0, "proc_pid_rusage, idle window"),
    ("app_power_mw", "Idle CPU power", "mW", 2, "proc_pid_rusage, idle window"),
    ("app_disk_written_mb_per_min", "Idle disk writes", "MB/min", 3, "proc_pid_rusage, idle window"),
    ("launch_to_window_s", "Launch to first window", "s", 2, "window list, every 20 ms"),
    ("launch_to_history_s", "Launch to history loaded", "s", 2, "app log"),
    ("app_cpu_s_before_window", "CPU from launch to the idle window", "s", 2, "proc_pid_rusage"),
    ("app_energy_j_before_window", "CPU energy from launch to the idle window", "J", 2, "proc_pid_rusage"),
    ("helper_start_s", "Python helper start to ready, no network", "s", 2, "helper_cost.py"),
    ("helper_start_cpu_s", "Python helper start, CPU", "s", 2, "helper_cost.py"),
    ("helper_footprint_mb", "Python helper memory once started", "MB", 1, "helper_cost.py"),
]
# With --refresh: four "Refresh now" passes on made-up quotes, 30 s apart, after
# the idle window. Shown only when a side measured them.
REFRESH_METRICS = [
    ("refresh_passes", "Refresh passes completed in the refresh window", "passes", 0, "app log"),
    ("refresh_cpu_s", "CPU over the refresh window", "s", 3, "proc_pid_rusage, refresh window"),
    ("refresh_energy_j", "CPU energy over the refresh window", "J", 3, "proc_pid_rusage, refresh window"),
    ("refresh_wakeups", "CPU wake-ups over the refresh window", "wake-ups", 0, "proc_pid_rusage, refresh window"),
    ("refresh_disk_written_mb", "Disk writes over the refresh window", "MB", 3, "proc_pid_rusage, refresh window"),
    ("refresh_footprint_mb_median", "Memory during the refresh window (physical footprint)", "MB", 1,
     "proc_pid_rusage, refresh window"),
    ("refresh_heap_growth_mb", "Allocated memory added by the refreshes", "MB", 1,
     "heap, before and after the refresh window"),
]
# Launches that differ in these were not measured under the same conditions.
CONDITIONS = [
    ("full_recalculation", "recalculated the whole portfolio history"),
    ("display_asleep", "ran with the display asleep"),
    ("screen_locked", "ran with the screen locked"),
    ("refresh_display_asleep", "ran the refresh window with the display asleep"),
    ("refresh_screen_locked", "ran the refresh window with the screen locked"),
    ("refresh_unsupported", "were builds without the refresh workload"),
]
SIGNIFICANCE = 0.01
SUGGESTIVE = 0.05
# Four a side can reach "possibly" at best; a firm verdict needs five or more.
MINIMUM_LAUNCHES = 4
EXACT_LIMIT = 400_000


def midranks(values):
    """Ranks from 1, with equal values sharing the mean of their ranks."""
    order = sorted(range(len(values)), key=values.__getitem__)
    ranks = [0.0] * len(values)
    start = 0
    while start < len(order):
        end = start
        while end + 1 < len(order) and values[order[end + 1]] == values[order[start]]:
            end += 1
        for position in range(start, end + 1):
            ranks[order[position]] = (start + end) / 2 + 1
        start = end + 1
    return ranks


def rank_sum_p(before, after):
    """Two-sided permutation p-value for the rank-sum of two samples."""
    ranks = midranks(list(before) + list(after))
    size, total = len(before), len(before) + len(after)
    expected = size * (total + 1) / 2
    observed = abs(sum(ranks[:size]) - expected) - 1e-9
    if math.comb(total, size) <= EXACT_LIMIT:
        sums = [sum(combination) for combination in itertools.combinations(ranks, size)]
    else:
        generator = random.Random(0)
        sums = [sum(generator.sample(ranks, size)) for _ in range(EXACT_LIMIT)]
    return sum(abs(value - expected) >= observed for value in sums) / len(sums)


def verdict(before, after):
    """(change in the median, p-value or None, what to call it)."""
    change = statistics.median(after) - statistics.median(before)
    if min(len(before), len(after)) < MINIMUM_LAUNCHES:
        return change, None, "too few launches to tell"
    p_value = rank_sum_p(before, after)
    if p_value > SUGGESTIVE or change == 0:
        return change, p_value, "no measurable change"
    direction = "lower" if change < 0 else "higher"
    return change, p_value, direction if p_value <= SIGNIFICANCE else f"possibly {direction}"


def read_side(folder, side):
    """Every launch's figures for one side, pooled over its rounds."""
    values = {}
    for path in sorted(glob.glob(os.path.join(folder, f"{side}-*", "*-metrics.txt"))):
        with open(path) as handle:
            for line in handle:
                key, _, value = line.strip().partition("=")
                try:
                    values.setdefault(key, []).append(float(value))
                except ValueError:
                    continue
    return values


def summary_field(folder, name):
    try:
        with open(os.path.join(folder, "before-1", "summary.txt")) as handle:
            for line in handle:
                if line.startswith(name + ": "):
                    return line.split(": ", 1)[1].strip()
    except FileNotFoundError:
        pass
    return "not recorded"


def spread(values, digits):
    return f"{statistics.median(values):.{digits}f} ({min(values):.{digits}f} to {max(values):.{digits}f})"


def report(folder, before_commit, after_commit):
    before, after = read_side(folder, "before"), read_side(folder, "after")
    launches = len(before.get("app_footprint_mb_median", []))
    lines = [
        f"Before `{before_commit}`, after `{after_commit}`. {launches} launches a side, taken in turns, "
        f"{summary_field(folder, 'settings')}.",
        f"{summary_field(folder, 'system')}. {summary_field(folder, 'date')}.",
        "",
        "| Metric | Before: median (range) | After: median (range) | Change | Verdict | Read with |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    refresh_measured = any(key in side for side in (before, after) for key, *_ in REFRESH_METRICS)
    for key, name, unit, digits, method in METRICS + (REFRESH_METRICS if refresh_measured else []):
        if key not in before or key not in after:
            lines.append(f"| {name} | not measured | not measured | | | {method} |")
            continue
        change, p_value, word = verdict(before[key], after[key])
        base = statistics.median(before[key])
        percent = f", {change / base * 100:+.1f}%" if base else ""
        shown = f"{change:+.{digits}f} {unit}{percent}"
        if word == "no measurable change":
            shown = f"({shown})"
        note = word if p_value is None else f"{word} (p = {p_value:.3f})"
        lines.append(
            f"| {name} | {spread(before[key], digits)} {unit} | {spread(after[key], digits)} {unit} "
            f"| {shown} | {note} | {method} |"
        )
    if any("| possibly " in line for line in lines):
        lines += ["", "A \"possibly\" row lies between p = 0.01 and p = 0.05. A commit measured against "
                  "itself reaches that on some row often enough that it needs a repeat before it counts."]
    for key, meaning in CONDITIONS:
        counts = [int(sum(side.get(key, []))) for side in (before, after)]
        if any(counts):
            lines += ["", f"Warning: {counts[0]} launch(es) before and {counts[1]} after {meaning}. "
                      "Those launches are not like the others."]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("folder")
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    arguments = parser.parse_args()
    print(report(arguments.folder, arguments.before, arguments.after))
