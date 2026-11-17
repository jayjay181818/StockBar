#!/usr/bin/env bash
# Measures a running Stockbar and its Python helper.
#
#   bash Scripts/measure_performance.sh [--duration 600] [--interval 10] [--pid PID] [--raw]
#
# Read-only: it samples kernel counters (Scripts/perf/proc_usage.swift) and never
# attaches to, pauses or signals the app. Memory is the physical footprint, the
# figure Activity Monitor shows, for the app and for its helper process.
#
# The default ten minutes spans two refresh passes at the default five-minute
# interval, which is what shows how long the helper stays running between them.
# For a controlled before/after comparison use Scripts/perf/benchmark.sh.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

duration=600
interval=10
pid=""
raw=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) duration="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --pid) pid="${2:-}"; shift 2 ;;
    --raw) raw=1; shift ;;
    *) sed -n '2,4p' "${BASH_SOURCE[0]}" >&2; exit 64 ;;
  esac
done
[[ "$duration" =~ ^[0-9]+$ && "$interval" =~ ^[1-9][0-9]*$ && "$pid" =~ ^[0-9]*$ ]] || {
  echo "--duration, --interval and --pid take whole numbers." >&2; exit 64
}

if [[ -z "$pid" ]]; then
  found="$(pgrep -x Stockbar || true)"
  if [[ -z "$found" ]]; then
    echo "Stockbar is not running. Start it, let it finish its first refresh, then run this again." >&2
    exit 1
  fi
  if [[ "$(wc -l <<<"$found" | tr -d ' ')" -ne 1 ]]; then
    echo "More than one Stockbar is running; choose one with --pid:" >&2
    ps -o pid=,comm= -p "$(paste -sd, - <<<"$found")" >&2
    exit 1
  fi
  pid="$found"
fi

proc_usage="$ROOT_DIR/build/bench/bin/proc_usage"
if [[ ! -x "$proc_usage" || "$ROOT_DIR/Scripts/perf/proc_usage.swift" -nt "$proc_usage" ]]; then
  mkdir -p "$(dirname "$proc_usage")"
  xcrun swiftc -O "$ROOT_DIR/Scripts/perf/proc_usage.swift" -o "$proc_usage"
fi

[[ "$duration" -eq 0 ]] || echo "Sampling Stockbar (pid $pid) every $interval s for $duration s..." >&2
output="$("$proc_usage" "$pid" --interval "$interval" --duration "$duration")"
if [[ "$raw" -eq 1 ]]; then
  printf '%s\n' "$output"
  exit 0
fi

awk -F= '
  { value[$1] = $2 }
  END {
    printf "Stockbar pid %s: %d samples over %.0f s\n", value["pid"], value["samples"], value["window_s"]
    printf "  App memory           %7.1f MB  (min %.1f, max %.1f; peak since launch %.1f)\n",
      value["app_footprint_mb_median"], value["app_footprint_mb_min"], value["app_footprint_mb_max"], value["app_lifetime_peak_mb"]
    printf "  Helper memory        %7.1f MB  while running; running in %.0f%% of samples\n",
      value["helper_footprint_mb_median_alive"], value["helper_alive_fraction"] * 100
    printf "  App + helper         %7.1f MB  on average (max %.1f)\n",
      value["total_footprint_mb_mean"], value["total_footprint_mb_max"]
    if ("app_cpu_s_per_min" in value) {
      printf "  App CPU              %7.2f s per minute (%.1f%% of one core)\n",
        value["app_cpu_s_per_min"], value["app_cpu_s_per_min"] / 0.6
      printf "  Helper CPU           %7.2f s per minute\n", value["helper_cpu_s_per_min"]
      printf "  App wakeups          %7.0f per minute\n", value["app_wakeups_per_min"]
      printf "  App disk writes      %7.2f MB per minute\n", value["app_disk_written_mb_per_min"]
      cpu = value["app_cpu_s_per_min"] + value["helper_cpu_s_per_min"]
      printf "  Target: CPU under 5%% of one core      %s\n", (cpu < 3 ? "met" : "MISSED")
    }
    printf "  Target: app + helper under 200 MB     %s\n", (value["total_footprint_mb_max"] < 200 ? "met" : "MISSED")
  }' <<<"$output"
