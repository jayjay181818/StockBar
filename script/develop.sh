#!/usr/bin/env bash
# Shared local/CI entrypoint. Full output stays in a per-invocation log.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
usage() {
  cat <<'HELP'
Usage: bash script/develop.sh <action> [argument]
  build                       Compile only; no app launch or process termination
  test [Target/Class[/method]] Run XCTest (all tests if no filter)
  python-tests                Offline Python syntax and unit tests
  checks                      Lint and all invariant/documentation validators
  docs-check                  Documentation links, duplicates and size review
  analyze                     Xcode static analysis
  acceptance <manifest.json>  Isolated harness; remains attached to its app
  run                         Explicit normal-app build and launch
Environment: PYTHON, STOCKBAR_DERIVED_DATA, STOCKBAR_LOG_DIR
HELP
}
action="${1:-help}"
case "$action" in
  help|--help|-h) usage; exit 0 ;;
  build|python-tests|checks|docs-check|analyze|run) [[ $# -eq 1 ]] || { usage >&2; exit 64; } ;;
  test) [[ $# -le 2 ]] || { usage >&2; exit 64; }
    if [[ $# -eq 2 && ! "$2" =~ ^StockbarTests/[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)?$ ]]; then
      echo 'Test filter must be StockbarTests/ClassName[/methodName].' >&2; exit 64
    fi ;;
  acceptance) [[ $# -eq 2 && -f "$2" ]] || { usage >&2; exit 64; } ;;
  *) usage >&2; exit 64 ;;
esac
python_bin="${PYTHON:-python3}"
derived_data="${STOCKBAR_DERIVED_DATA:-$ROOT_DIR/build/DevelopmentDerivedData}"
log_dir="${STOCKBAR_LOG_DIR:-$ROOT_DIR/build/logs}"
umask 077
mkdir -p "$log_dir"
log_file="$(mktemp "$log_dir/$action.XXXXXX")"
# One array keeps build/test/analyze flags consistent between local work and CI.
xcode_args=(-project "$ROOT_DIR/Stockbar.xcodeproj" -scheme Stockbar -configuration Debug
  -destination 'platform=macOS' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO)
run_action() {
  case "$action" in
    build|analyze) xcodebuild "$action" "${xcode_args[@]}" ;;
    test)
      if [[ $# -eq 2 ]]; then
        xcodebuild test "${xcode_args[@]}" "-only-testing:$2"
      else
        xcodebuild test "${xcode_args[@]}"
      fi ;;
    python-tests)
      PYTHONPYCACHEPREFIX="$ROOT_DIR/build/python-cache" "$python_bin" -m py_compile Stockbar/Resources/get_stock_data.py Stockbar/Resources/get_ohlc_data.py
      PYTHONDONTWRITEBYTECODE=1 "$python_bin" -m unittest discover -s PythonTests -p 'test_*.py' ;;
    checks)
      mkdir -p "$ROOT_DIR/build/swiftlint-cache"
      swiftlint lint --cache-path "$ROOT_DIR/build/swiftlint-cache"
      bash Scripts/validate_entitlements.sh
      bash Scripts/validate_unchecked_sendable.sh
      bash Scripts/validate_invariants.sh
      "$python_bin" Scripts/validate_agent_docs.py ;;
    docs-check) "$python_bin" Scripts/validate_agent_docs.py ;;
    acceptance) /bin/zsh script/run_folync_acceptance.sh "$2" ;;
    run) bash script/build_and_run.sh ;;
  esac
}
echo "Running $action. Full log: $log_file"
# Do not invoke run_action as an if/! condition: that disables errexit in its body.
set +e
(set -e; run_action "$@") >"$log_file" 2>&1
result=$?
set -e
if [[ "$result" -ne 0 ]]; then
  echo "$action failed (exit $result). Diagnostics:" >&2
  diagnostics="$(grep -E ': error:|^error:|^ERROR:|^Error:' "$log_file" | head -n 15 || true)"
  if [[ -n "$diagnostics" ]]; then
    printf '%s\n' "$diagnostics" >&2
    tail -n 12 "$log_file" >&2
  else
    tail -n 60 "$log_file" >&2
  fi
  echo "Full log: $log_file" >&2
  exit "$result"
fi
echo "$action passed. Full log: $log_file"
# Documentation size warnings should remain visible without dumping successful build logs.
if [[ "$action" == docs-check || "$action" == checks ]]; then
  sed -n '/^WARNING:/p' "$log_file"
fi
