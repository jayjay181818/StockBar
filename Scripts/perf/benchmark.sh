#!/usr/bin/env bash
# Repeatable resource benchmark for Stockbar.
#
#   bash Scripts/perf/benchmark.sh [--label name] [--runs 5] [--settle 75] [--window 60] [--skip-build]
#                                  [--source dir --commit-label text] [--output dir] [--build-only]
#
# To compare two commits use Scripts/perf/compare.sh, which runs this for each.
#
# 1. Builds the Release configuration with the flags script/package_release.sh
#    uses, as the separate bundle com.stockbar.acceptance. --source builds a
#    copy of the project kept somewhere else (compare.sh exports one for each
#    commit); the workload and the measuring always come from this checkout.
# 2. Runs that build in the app's isolated acceptance mode: storage below the
#    temporary directory and live providers off, so it never touches the real
#    portfolio, its Keychain items or the network.
# 3. Fills the isolated store with synthetic history (make_fixture.py) and runs
#    one warm-up launch, so first-run migrations and the first history
#    recalculation are done. Then measures each launch: time to the first
#    window and to history loaded, peak memory, and memory, CPU, energy and
#    wakeups over an idle window that starts --settle seconds after launch.
# 4. Measures one start of the Python helper on its own, because acceptance
#    mode never starts it.
#
# Every launch shows a Stockbar window and menu-bar items until it is stopped.
# Only processes this script started are stopped. The Mac and its display are
# kept awake while it runs. The summary goes to the terminal and to
# build/bench/results/ (or --output), with the app's log and, for each launch,
# its figures, the memory samples, a memory breakdown and its largest heap
# classes beside it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERF_DIR="$ROOT_DIR/Scripts/perf"
cd "$ROOT_DIR"

label="run"
runs=5
settle=75
window=60
skip_build=0
build_only=0
source_dir="$ROOT_DIR"
commit_label=""
output_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) label="${2:-}"; shift 2 ;;
    --runs) runs="${2:-}"; shift 2 ;;
    --settle) settle="${2:-}"; shift 2 ;;
    --window) window="${2:-}"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    --build-only) build_only=1; shift ;;
    --source) source_dir="${2:-}"; shift 2 ;;
    --commit-label) commit_label="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    *) sed -n '2,6p' "${BASH_SOURCE[0]}" >&2; exit 64 ;;
  esac
done
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$runs" =~ ^[1-9][0-9]*$ && "$settle" =~ ^[0-9]+$ && "$window" =~ ^[1-9][0-9]*$ ]] || {
  echo "--label takes a simple name; --runs, --settle and --window take whole numbers." >&2; exit 64
}
[[ -f "$source_dir/Stockbar.xcodeproj/project.pbxproj" ]] || { echo "No Stockbar project in $source_dir" >&2; exit 66; }
source_dir="$(cd "$source_dir" && pwd)"
if [[ "$source_dir" != "$ROOT_DIR" && -z "$commit_label" ]]; then
  echo "--source needs --commit-label: a copy of the project cannot say which commit it is." >&2; exit 64
fi

bundle_id="com.stockbar.acceptance"
bench_dir="$ROOT_DIR/build/bench"
derived_data="${STOCKBAR_DERIVED_DATA:-$bench_dir/DerivedData}"
[[ "$derived_data" == /* ]] || derived_data="$ROOT_DIR/$derived_data"  # the app is started from another folder
app_bundle="$derived_data/Build/Products/Release/Stockbar.app"
executable="$app_bundle/Contents/MacOS/Stockbar"
proc_usage="$bench_dir/bin/proc_usage"
python_bin="${PYTHON:-/usr/bin/python3}"
helper_python="${STOCKBAR_HELPER_PYTHON:-$HOME/Library/Application Support/Stockbar/python-env/bin/python3}"
stamp="$(date +%Y%m%d-%H%M%S)"
results="${output_dir:-$bench_dir/results/$label-$stamp}"
mkdir -p "$bench_dir/bin" "$ROOT_DIR/build/logs"

# Taken now: the sources may be edited while the launches run.
if [[ -z "$commit_label" ]]; then
  commit_label="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- Stockbar Stockbar.xcodeproj || echo ' + uncommitted app changes')"
fi

temp_base="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
work="$(mktemp -d "${temp_base%/}/stockbar-bench-work.XXXXXX")"
root=""
app_log=""
log_saved=0
app_pid=""
stop_app() {
  [[ -n "$app_pid" ]] || return 0
  # Signal the process only while it is still the build this script launched.
  if [[ "$(ps -p "$app_pid" -o comm= 2>/dev/null)" == "$executable" ]]; then
    kill -TERM "$app_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.2; done
    kill -KILL "$app_pid" 2>/dev/null || true
  fi
  app_pid=""
}
cleanup() {
  stop_app
  # A run that fails or is stopped part of the way keeps what the app logged,
  # which is otherwise deleted with the isolated storage, so that it can be
  # explained afterwards.
  if [[ "$log_saved" -eq 0 && -n "$app_log" && -f "$app_log" ]]; then
    if mkdir -p "$results" 2>/dev/null && cp "$app_log" "$results/app-failed.log" 2>/dev/null; then
      echo "The run did not finish. The app's log is kept in $results/app-failed.log" >&2
    fi
    [[ -s "$work/app-output.log" ]] && cp "$work/app-output.log" "$results/app-output-failed.log" 2>/dev/null || true
  fi
  [[ -n "$root" && "$root" == "${temp_base%/}"/stockbar-bench.* ]] && rm -rf "$root"
  rm -rf "$work"
}
trap cleanup EXIT

now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
note() { echo "[benchmark] $*" >&2; }

if [[ "$skip_build" -eq 0 ]]; then
  build_log="$(mktemp "$ROOT_DIR/build/logs/benchmark-build.XXXXXX")"
  note "Building Release as $bundle_id (log: $build_log)"
  # One copy of the Swift packages serves every build made for a comparison.
  if ! xcodebuild build -project "$source_dir/Stockbar.xcodeproj" -scheme Stockbar -configuration Release \
      -destination 'platform=macOS' -derivedDataPath "$derived_data" -disableAutomaticPackageResolution \
      -clonedSourcePackagesDirPath "$bench_dir/SourcePackages" \
      CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" >"$build_log" 2>&1; then
    grep -E ': error:|^error:' "$build_log" | head -n 15 >&2 || true
    echo "Benchmark build failed. Full log: $build_log" >&2
    exit 65
  fi
fi
[[ -x "$executable" ]] || { echo "No build at $app_bundle; run without --skip-build." >&2; exit 66; }
built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")"
[[ "$built_id" == "$bundle_id" ]] || { echo "Refusing to benchmark bundle $built_id; expected $bundle_id." >&2; exit 65; }
if [[ ! -x "$proc_usage" || "$PERF_DIR/proc_usage.swift" -nt "$proc_usage" ]]; then
  xcrun swiftc -O "$PERF_DIR/proc_usage.swift" -o "$proc_usage"
fi
if [[ "$build_only" -eq 1 ]]; then
  note "Built $app_bundle"
  exit 0
fi
mkdir -p "$results"
# A Mac that sleeps, or a display that turns off, part of the way through
# would change what is being measured. Ends when this script does.
/usr/bin/caffeinate -di -w $$ &

# --- Isolated storage and synthetic data -----------------------------------
root="$(mktemp -d "${temp_base%/}/stockbar-bench.XXXXXX")"
export STOCKBAR_ACCEPTANCE_ROOT="$root"
export STOCKBAR_ACCEPTANCE_RUN_ID="bench-$stamp"
export STOCKBAR_DISABLE_LIVE_PROVIDERS=1
app_log="$root/Logs/com.stockbar/stockbar.log"
store="$root/Application Support/Stockbar/StockbarDataModel.sqlite"
# The app runs from the work folder: an instrumented build writes its coverage
# profile to the current directory when it exits.
(cd "$work" && "$executable" --acceptance-preflight >"$work/preflight.json")
grep -q '"liveProviderRequestsAllowed" : false' "$work/preflight.json" || {
  echo "Preflight did not confirm that live providers are off." >&2; exit 67
}
"$python_bin" "$PERF_DIR/make_fixture.py" "$store" >"$work/fixture.txt"

launch() {
  log_start=0
  [[ -f "$app_log" ]] && log_start="$(wc -l <"$app_log" | tr -d ' ')"
  launched_at="$(now)"
  (cd "$work" && exec /usr/bin/nohup "$executable" >"$work/app-output.log" 2>&1 </dev/null) &
  app_pid=$!
  disown "$app_pid"  # the shell would otherwise report the stop as a failed job
}
# Seconds from one clock time to another.
elapsed() { "$python_bin" -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.2f}")' "$1" "$2"; }
# Waits for a line logged by the current launch. Prints the line.
wait_for_log() {
  local pattern="$1" seconds="$2" line
  for _ in $(seq 1 $((seconds * 10))); do
    kill -0 "$app_pid" 2>/dev/null || { echo "Stockbar exited during the benchmark." >&2; return 1; }
    if [[ -f "$app_log" ]] && line="$(tail -n "+$((log_start + 1))" "$app_log" | grep -m 1 -- "$pattern")"; then
      printf '%s\n' "$line"
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out after $seconds s waiting for the app to log \"$pattern\"." >&2
  return 1
}

note "Warm-up launch (first-run migrations and history recalculation)"
launch
wait_for_log "RETROACTIVE: Portfolio history calculation completed" 180 >/dev/null
sleep 5
stop_app

for run in $(seq 1 "$runs"); do
  note "Measured launch $run of $runs (about $((settle + window)) s)"
  launch
  "$proc_usage" "$app_pid" --wait-window 60 >"$work/window.txt" 2>"$work/window-error.txt" &
  window_watch=$!
  ready_line="$(wait_for_log "historical portfolio snapshots from Core Data\." 120)"
  wait "$window_watch" || { cat "$work/window-error.txt" >&2; exit 1; }
  # The log stamps each line in UTC with milliseconds.
  ready_at="$("$python_bin" -c 'import sys, datetime
stamp = sys.argv[1][:23]
print(datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp())' "$ready_line")"
  remaining="$("$python_bin" -c 'import sys; print(max(0.0, float(sys.argv[1]) + float(sys.argv[2]) - float(sys.argv[3])))' "$launched_at" "$settle" "$(now)")"
  sleep "$remaining"
  run_file="$work/run-$run.txt"
  "$proc_usage" "$app_pid" --interval 5 --duration "$window" --series "$results/launch-$run-series.txt" >"$run_file"
  echo "launch_to_history_s=$(elapsed "$launched_at" "$ready_at")" >>"$run_file"
  echo "launch_to_window_s=$(elapsed "$launched_at" "$(cut -d = -f 2 "$work/window.txt")")" >>"$run_file"
  recalculated=0
  tail -n "+$((log_start + 1))" "$app_log" | grep -q "FULL RECALC: Starting" && recalculated=1
  echo "full_recalculation=$recalculated" >>"$run_file"
  # Where the memory is, by kind. Taken after the window so it cannot disturb it.
  /usr/bin/footprint "$app_pid" >"$results/launch-$run-footprint.txt" 2>&1 || true
  # Bytes the app has allocated and not freed, largest classes first. The
  # footprint also counts freed pages the allocator has not handed back, which
  # varies from launch to launch; this figure does not.
  /usr/bin/heap -s "$app_pid" >"$work/heap.txt" 2>&1 || true
  head -n 60 "$work/heap.txt" >"$results/launch-$run-heap.txt"
  awk '/^All zones:/ { for (i = 2; i <= NF; i++) if ($i ~ /^\(?bytes\)?$/) { gsub(/[^0-9]/, "", $(i - 1)); printf "app_heap_allocated_mb=%.1f\n", $(i - 1) / 1048576; exit } }' \
    "$work/heap.txt" >>"$run_file"
  cp "$run_file" "$results/launch-$run-metrics.txt"
  stop_app
done
cp "$app_log" "$results/app.log"
log_saved=1

# --- Python helper ----------------------------------------------------------
worker="$app_bundle/Contents/Resources/stockbar_worker.py"
if [[ -x "$helper_python" && -f "$worker" ]]; then
  note "Measuring the Python helper start ($runs times)"
  for run in $(seq 1 "$runs"); do
    "$python_bin" "$PERF_DIR/helper_cost.py" "$helper_python" "$worker" "$proc_usage" >"$work/helper-$run.txt"
    cp "$work/helper-$run.txt" "$results/helper-$run-metrics.txt"
  done
else
  note "Helper not measured: no interpreter at $helper_python"
fi

# --- Report -----------------------------------------------------------------
coverage_bytes="$(size -m "$executable" | awk '/__llvm_(prf|cov)/ {sum += $NF} END {print sum + 0}')"
{
  echo "label: $label"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit: $commit_label"
  echo "system: macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) / 1073741824)) GB, $(pmset -g batt | head -n 1 | sed -E "s/.*'(.*)'.*/\1/")"
  echo "settings: runs=$runs settle=${settle}s window=${window}s"
  echo "fixture: $(cat "$work/fixture.txt")"
  echo
  printf '%-34s %10s   %s\n' metric median "each run"
  "$python_bin" - "$work" "$runs" <<'PY'
import statistics
import sys

work, runs = sys.argv[1], int(sys.argv[2])
order = [
    "app_footprint_mb_median", "app_heap_allocated_mb", "app_lifetime_peak_mb", "app_resident_mb_median",
    "app_footprint_drift_mb", "app_cpu_s_per_min", "app_power_mw", "app_wakeups_per_min",
    "app_disk_written_mb_per_min", "app_cpu_s_before_window", "app_energy_j_before_window",
    "launch_to_window_s", "launch_to_history_s", "full_recalculation", "display_asleep", "screen_locked",
    "helper_start_s", "helper_start_cpu_s", "helper_footprint_mb", "helper_resident_mb",
]
values = {}
for prefix in ("run", "helper"):
    for index in range(1, runs + 1):
        try:
            lines = open(f"{work}/{prefix}-{index}.txt").read().splitlines()
        except FileNotFoundError:
            continue
        for line in lines:
            key, _, value = line.partition("=")
            if key in order:
                values.setdefault(key, []).append(float(value))
for key in order:
    if key in values:
        each = "  ".join(f"{value:g}" for value in values[key])
        print(f"{key:<34} {statistics.median(values[key]):>10g}   {each}")
PY
  printf '%-34s %10s\n' binary_bytes "$(stat -f %z "$executable")"
  printf '%-34s %10s\n' coverage_instrumentation_bytes "$coverage_bytes"
  printf '%-34s %10s\n' app_bundle_kb "$(du -sk "$app_bundle" | cut -f 1)"
} | tee "$results/summary.txt"
note "Saved to $results"
