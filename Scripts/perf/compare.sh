#!/usr/bin/env bash
# Measures two commits against each other and writes the before/after table a
# pull request carries.
#
#   bash Scripts/perf/compare.sh <before> <after> [--label name] [--rounds 2] [--runs 3]
#                                [--settle 75] [--window 60] [--refresh]
#
# <before> and <after> are commits, by any name git accepts. Each is exported
# to build/bench/src/ and built into build/bench/dd/, both named after the
# commit's tree: a tree that is already built is not built again, and edits
# that are not committed are never measured. Both sides get the same build
# flags, the same synthetic data and the same measuring, all from this checkout
# (see benchmark.sh).
#
# The sides take turns (before, after, then after, before, and so on), so a
# slow change in the state of the Mac falls on both alike. Each turn is --runs
# launches; a side ends up with --rounds times --runs of them. With fewer than
# four launches a side no difference can be told from noise, and a firm
# verdict needs five or more (see compare_report.py).
#
# Comparing a commit with itself gives the noise of the measurement.
#
# The table goes to the terminal and to report.md in
# build/bench/results/compare-<label>-<time>/, beside everything each turn
# saved. About (settle + window + 10) seconds a launch, plus the builds.
# --refresh adds the refresh workload to every turn (see benchmark.sh): as many
# launches again, about (settle + 130) seconds each, and rows of its own in the table.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERF_DIR="$ROOT_DIR/Scripts/perf"
cd "$ROOT_DIR"

usage() { sed -n '4,5p' "${BASH_SOURCE[0]}" >&2; exit 64; }
[[ $# -ge 2 ]] || usage
before_ref="$1"
after_ref="$2"
shift 2
label="run"
rounds=2
runs=3
settle=75
window=60
refresh=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) label="${2:-}"; shift 2 ;;
    --rounds) rounds="${2:-}"; shift 2 ;;
    --runs) runs="${2:-}"; shift 2 ;;
    --settle) settle="${2:-}"; shift 2 ;;
    --window) window="${2:-}"; shift 2 ;;
    --refresh) refresh=(--refresh); shift ;;
    *) usage ;;
  esac
done
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$rounds" =~ ^[1-9][0-9]*$ && "$runs" =~ ^[1-9][0-9]*$ \
    && "$settle" =~ ^[0-9]+$ && "$window" =~ ^[1-9][0-9]*$ ]] || usage

bench_dir="$ROOT_DIR/build/bench"
python_bin="${PYTHON:-/usr/bin/python3}"
out="$bench_dir/results/compare-$label-$(date +%Y%m%d-%H%M%S)"
note() { echo "[compare] $*" >&2; }

resolve() {
  git rev-parse --verify --quiet "$1^{commit}" || { echo "Not a commit: $1" >&2; exit 64; }
}
before_sha="$(resolve "$before_ref")"
after_sha="$(resolve "$after_ref")"

# Exports and builds one commit, unless its tree is already built. Prints the
# folder the build is in.
prepare() {
  local sha="$1" tree source derived
  tree="$(git rev-parse "$sha^{tree}")"
  source="$bench_dir/src/${tree:0:12}"
  derived="$bench_dir/dd/${tree:0:12}"
  if [[ ! -f "$derived/.built" ]]; then
    note "Exporting and building ${sha:0:7}"
    rm -rf "$source" "$derived"
    mkdir -p "$source"
    git archive "$sha" | tar -x -C "$source"
    # Only the folder name may reach this function's output.
    STOCKBAR_DERIVED_DATA="$derived" bash "$PERF_DIR/benchmark.sh" --source "$source" \
      --commit-label "${sha:0:7}" --build-only >&2
    touch "$derived/.built"
  fi
  printf '%s\n' "$derived"
}
before_build="$(prepare "$before_sha")"
after_build="$(prepare "$after_sha")"

mkdir -p "$out"
for round in $(seq 1 "$rounds"); do
  if (( round % 2 == 1 )); then order=(before after); else order=(after before); fi
  for side in "${order[@]}"; do
    if [[ "$side" == before ]]; then sha="$before_sha"; build="$before_build"; else sha="$after_sha"; build="$after_build"; fi
    note "Round $round of $rounds: $side (${sha:0:7})"
    STOCKBAR_DERIVED_DATA="$build" bash "$PERF_DIR/benchmark.sh" --skip-build --commit-label "${sha:0:7}" \
      --label "$side" --runs "$runs" --settle "$settle" --window "$window" ${refresh[@]+"${refresh[@]}"} \
      --output "$out/$side-$round" >/dev/null
  done
done

"$python_bin" "$PERF_DIR/compare_report.py" "$out" --before "$before_sha" --after "$after_sha" | tee "$out/report.md"
note "Saved to $out"
