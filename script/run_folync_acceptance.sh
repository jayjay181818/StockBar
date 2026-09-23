#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "Usage: $0 /tmp/folync-stockbar-acceptance-.../manifest.json"
  exit 64
fi

manifest_dir="$(cd "$(dirname "$1")" && pwd -P)"
manifest="$manifest_dir/$(basename "$1")"
temp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
case "$manifest_dir/" in
  "$temp_root"/*) ;;
  *) print -u2 "Folync acceptance manifest must be below the operating-system temporary directory"; exit 65 ;;
esac

token_file="$(/usr/bin/plutil -extract tokenFile raw -o - "$manifest")"
token_dir="$(cd "$(dirname "$token_file")" && pwd -P)"
if [[ "$token_dir" != "$manifest_dir" || "$(/usr/bin/stat -f %Lp "$token_file")" != "600" ]]; then
  print -u2 "Folync acceptance token must be a mode-0600 file beside the manifest"
  exit 65
fi
base_url="$(/usr/bin/plutil -extract baseURL raw -o - "$manifest")"
case "$base_url" in
  http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) ;;
  *) print -u2 "Folync acceptance endpoint must be loopback HTTP"; exit 65 ;;
esac

run_id="acceptance-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
acceptance_root="$temp_root/stockbar-folync-$run_id"
derived_data="$temp_root/stockbar-folync-derived-$run_id"
mkdir -m 700 "$acceptance_root" "$derived_data"

if [[ -n "${STOCKBAR_ACCEPTANCE_REUSE_APP:-}" ]]; then
  app="$STOCKBAR_ACCEPTANCE_REUSE_APP"
else
  xcodebuild build \
    -project Stockbar.xcodeproj \
    -scheme Stockbar \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    PRODUCT_BUNDLE_IDENTIFIER=com.stockbar.acceptance
  app="$derived_data/Build/Products/Debug/Stockbar.app"
fi
executable="$app/Contents/MacOS/Stockbar"
bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
if [[ "$bundle_id" == "com.stockbar" || "$bundle_id" != "com.stockbar.acceptance" ]]; then
  print -u2 "Refusing to launch a normal Stockbar bundle"
  exit 66
fi

export STOCKBAR_ACCEPTANCE_ROOT="$acceptance_root"
export STOCKBAR_ACCEPTANCE_RUN_ID="$run_id"
export STOCKBAR_DISABLE_LIVE_PROVIDERS=1
export STOCKBAR_FOLYNC_MANIFEST="$manifest"

preflight="$acceptance_root/preflight.json"
bootstrap="$acceptance_root/bootstrap.json"
preflight_staging="$derived_data/preflight.json"
"$executable" --acceptance-preflight > "$preflight_staging"
mv "$preflight_staging" "$preflight"
"$executable" --acceptance-bootstrap > "$bootstrap"

canonical_root="$(cd "$acceptance_root" && pwd -P)"
for index in {0..5}; do
  writable_path="$(/usr/bin/plutil -extract "resolvedWritablePaths.$index" raw -o - "$preflight")"
  if [[ -d "$writable_path" ]]; then
    canonical_path="$(cd "$writable_path" && pwd -P)"
  else
    canonical_path="$(cd "$(dirname "$writable_path")" && pwd -P)/$(basename "$writable_path")"
  fi
  case "$canonical_path/" in
    "$canonical_root"/*) ;;
    *) print -u2 "Preflight reported a writable path outside the acceptance root"; exit 67 ;;
  esac
done

app_log="$acceptance_root/stockbar.log"
/usr/bin/nohup "$executable" > "$app_log" 2>&1 < /dev/null &
app_pid=$!
sleep 2
if ! kill -0 "$app_pid" 2>/dev/null; then
  print -u2 "Acceptance Stockbar exited during startup; evidence retained at $acceptance_root"
  exit 68
fi

report="$acceptance_root/run-report.plist"
/usr/bin/plutil -create xml1 "$report"
/usr/bin/plutil -insert runID -string "$run_id" "$report"
/usr/bin/plutil -insert pid -integer "$app_pid" "$report"
/usr/bin/plutil -insert bundleIdentifier -string "$bundle_id" "$report"
/usr/bin/plutil -insert executable -string "$executable" "$report"
/usr/bin/plutil -insert executableSha256 -string "$(/usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')" "$report"
/usr/bin/plutil -insert stockbarBaseSHA -string "$(git rev-parse HEAD)" "$report"
/usr/bin/plutil -insert stockbarDiffSha256 -string "$(git diff --binary | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" "$report"
/usr/bin/plutil -insert folyncManifest -string "$manifest" "$report"
/usr/bin/plutil -insert preflight -string "$preflight" "$report"
/usr/bin/plutil -insert bootstrap -string "$bootstrap" "$report"
/usr/bin/plutil -insert appLog -string "$app_log" "$report"
/usr/bin/plutil -insert startedAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$report"
chmod 600 "$report" "$preflight" "$bootstrap" "$app_log"

print "Stockbar acceptance is running (PID $app_pid)."
print "Sanitized report: $report"
print "Evidence root: $acceptance_root"

wait "$app_pid"
