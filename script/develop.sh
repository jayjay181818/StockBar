#!/usr/bin/env bash
# Shared local/CI entrypoint. Full output stays in a per-invocation log.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
usage() {
  cat <<'HELP'
Usage: bash script/develop.sh <action> [argument]
  build                       Compile only; no app launch or process termination
  build-release               The same for the Release configuration
  test [Target/Class[/method]] Run XCTest (all tests if no filter)
  python-tests                Offline Python syntax and unit tests
  checks                      Lint and all invariant/documentation validators
  docs-check                  Documentation links, duplicates and size review
  coverage                    Full XCTest run with coverage; prints the least-covered files
  acceptance <manifest.json>  Isolated harness; remains attached to its app
  run                         Explicit normal-app build and launch
Environment: PYTHON, STOCKBAR_DERIVED_DATA, STOCKBAR_LOG_DIR, STOCKBAR_RESULT_DIR
HELP
}
action="${1:-help}"
case "$action" in
  help|--help|-h) usage; exit 0 ;;
  build|build-release|python-tests|checks|docs-check|coverage|run) [[ $# -eq 1 ]] || { usage >&2; exit 64; } ;;
  test) [[ $# -le 2 ]] || { usage >&2; exit 64; }
    if [[ $# -eq 2 && ! "$2" =~ ^StockbarTests/[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)?$ ]]; then
      echo 'Test filter must be StockbarTests/ClassName[/methodName].' >&2; exit 64
    fi ;;
  acceptance) [[ $# -eq 2 && -f "$2" ]] || { usage >&2; exit 64; } ;;
  *) usage >&2; exit 64 ;;
esac
# Stockbar's own Python environment when it exists, so local runs use the
# interpreter and pinned packages the app and CI use. PYTHON overrides it.
app_python="$HOME/Library/Application Support/Stockbar/python-env/bin/python3"
if [[ -n "${PYTHON:-}" ]]; then
  python_bin="$PYTHON"
elif [[ -x "$app_python" ]]; then
  python_bin="$app_python"
else
  python_bin="python3"
fi
derived_data="${STOCKBAR_DERIVED_DATA:-$ROOT_DIR/build/DevelopmentDerivedData}"
log_dir="${STOCKBAR_LOG_DIR:-$ROOT_DIR/build/logs}"
result_dir="${STOCKBAR_RESULT_DIR:-$ROOT_DIR/build/results}"
umask 077
mkdir -p "$log_dir"
log_file="$(mktemp "$log_dir/$action.XXXXXX")"
# One array keeps build and test flags consistent between local work and CI.
configuration=Debug
[[ "$action" == build-release ]] && configuration=Release
xcode_args=(-project "$ROOT_DIR/Stockbar.xcodeproj" -scheme Stockbar -configuration "$configuration"
  -destination 'platform=macOS' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO)
# A fresh result bundle per run; CI uploads it when the tests fail.
new_result_bundle() {
  mkdir -p "$result_dir"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  printf '%s/%s-%s.xcresult' "$result_dir" "$1" "$stamp"
}
run_action() {
  case "$action" in
    build|build-release) xcodebuild build "${xcode_args[@]}" ;;
    test)
      if [[ $# -eq 2 ]]; then
        xcodebuild test "${xcode_args[@]}" -resultBundlePath "$(new_result_bundle test)" "-only-testing:$2"
      else
        xcodebuild test "${xcode_args[@]}" -resultBundlePath "$(new_result_bundle test)"
      fi ;;
    coverage)
      bundle="$(new_result_bundle coverage)"
      xcodebuild test "${xcode_args[@]}" -enableCodeCoverage YES -resultBundlePath "$bundle"
      xcrun xccov view --report --json "$bundle" >"$result_dir/coverage.json"
      "$python_bin" Scripts/coverage_summary.py "$result_dir/coverage.json" | tee "$result_dir/coverage.txt" ;;
    python-tests)
      PYTHONPYCACHEPREFIX="$ROOT_DIR/build/python-cache" "$python_bin" -m py_compile Stockbar/Resources/get_stock_data.py Stockbar/Resources/get_ohlc_data.py Stockbar/Resources/stockbar_worker.py
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
if [[ "$action" == coverage ]]; then
  cat "$result_dir/coverage.txt"
fi
