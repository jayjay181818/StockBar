#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Stockbar"
BUNDLE_ID="com.stockbar"
PROJECT_NAME="Stockbar.xcodeproj"
SCHEME_NAME="Stockbar"
CONFIGURATION="${CONFIGURATION:-Debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${STOCKBAR_DERIVED_DATA:-$ROOT_DIR/build/DerivedData}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

ensure_app_stopped() {
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "Stockbar is already running. Quit it explicitly before launching this build." >&2
    exit 1
  else
    process_status=$?
    if [[ "$process_status" -ne 1 ]]; then
      echo "Cannot determine whether Stockbar is running (pgrep exit $process_status)." >&2
      exit "$process_status"
    fi
  fi
}

build_app() {
  xcodebuild build \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR"

  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Expected app bundle was not produced: $APP_BUNDLE" >&2
    exit 1
  fi
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

# Validate before any build or runtime side effects.
case "$MODE" in
  --help|-h|help) usage; exit 0 ;;
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *) usage; exit 64 ;;
esac
ensure_app_stopped
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    if [[ ! -x "$APP_BINARY" ]]; then
      echo "Expected app binary was not produced: $APP_BINARY" >&2
      exit 1
    fi
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    echo "Startup smoke check passed; this does not verify functional behavior. Stockbar remains running."
    ;;
  *)
    usage
    exit 2
    ;;
esac
