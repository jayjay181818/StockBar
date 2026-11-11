#!/usr/bin/env bash
# Writes Stockbar/Resources/requirements.lock: every package the Python helper
# installs, at an exact version with checksums, for Python 3.10 and later on
# any platform. requirements.txt stays the hand-edited list of direct pins.
#
#   bash script/update_python_lock.sh            keep current versions; only add
#                                                or drop what requirements.txt needs
#   bash script/update_python_lock.sh --upgrade  move every package to its newest
#                                                release that is at least a week old
#   bash script/update_python_lock.sh --check    fail if the lock does not match
#                                                requirements.txt (used by CI)
#
# Releases younger than a week are left for the next run, so a package that is
# pulled or found to be malicious soon after release never reaches the lock.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$ROOT_DIR/Stockbar/Resources"
mode="${1:-}"
case "$mode" in ""|--upgrade|--check) ;; *) echo "Usage: $0 [--upgrade|--check]" >&2; exit 64 ;; esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--upgrade|--check]" >&2; exit 64; }
command -v uv >/dev/null 2>&1 || { echo "uv is required: https://docs.astral.sh/uv/" >&2; exit 69; }

compile() {  # $1: output file, relative to Resources; further arguments go to uv
  local output="$1"; shift
  (cd "$RESOURCES" && uv pip compile requirements.txt \
    --quiet --universal --python-version 3.10 --generate-hashes --no-header \
    --output-file "$output" "$@")
}

case "$mode" in
  --check)
    # Compiling over a copy keeps every locked version that still satisfies
    # requirements.txt, so newer releases since the lock was written do not
    # make this fail; only a real mismatch does.
    scratch="$(mktemp "$RESOURCES/.requirements.lock.check.XXXXXX")"
    trap 'rm -f "$scratch"' EXIT
    cp "$RESOURCES/requirements.lock" "$scratch"
    compile "$(basename "$scratch")"
    if ! diff -u "$RESOURCES/requirements.lock" "$scratch" >&2; then
      echo "requirements.lock does not match requirements.txt. Run: bash script/update_python_lock.sh" >&2
      exit 1
    fi
    echo "requirements.lock matches requirements.txt."
    ;;
  --upgrade)
    cutoff="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
    compile requirements.lock --upgrade --exclude-newer "$cutoff"
    ;;
  "")
    compile requirements.lock
    ;;
esac
