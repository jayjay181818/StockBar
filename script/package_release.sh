#!/usr/bin/env bash
# Builds the Release configuration, signs it and zips it for distribution.
# The release workflow runs this; it also works locally.
#
#   bash script/package_release.sh --build 360.14 [--version "3.6.0 (testing 14)"]
#                                  [--app path/to/unsigned/Stockbar.app] [--output dir]
#
# --build    CFBundleVersion: what the updater compares. Required.
# --version  CFBundleShortVersionString: what people see. Default: the project's.
# --app      Sign and zip this already-built app instead of building.
# --output   Where the zip goes. Default: build/release.
#
# The signature is ad hoc: it names no person and no certificate. There is no
# Apple account behind Stockbar, and a self-signed certificate was tried and
# gains nothing: macOS ties Keychain access to the exact build for any
# certificate Apple did not issue. Updates are trusted through Sparkle's EdDSA
# signature instead (see Docs/Development.md, "Release builds and updates").
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

build_number=""
version=""
prebuilt_app=""
output_dir="$ROOT_DIR/build/release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) build_number="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --app) prebuilt_app="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done
# CFBundleVersion allows one to three dot-separated whole numbers.
if [[ ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Usage: bash script/package_release.sh --build 360[.14] [--version text] [--app path] [--output dir]" >&2
  exit 64
fi

entitlements="$ROOT_DIR/Stockbar/Stockbar.entitlements"
derived_data="${STOCKBAR_DERIVED_DATA:-$ROOT_DIR/build/ReleaseDerivedData}"
staging="$(mktemp -d "${TMPDIR:-/tmp}/stockbar-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Stockbar.app"

if [[ -n "$prebuilt_app" ]]; then
  [[ -d "$prebuilt_app" ]] || { echo "No app at $prebuilt_app" >&2; exit 66; }
  /usr/bin/ditto "$prebuilt_app" "$app"
else
  mkdir -p "$ROOT_DIR/build/logs"
  log="$(mktemp "$ROOT_DIR/build/logs/package-release.XXXXXX")"
  echo "Building Release. Full log: $log"
  # The package versions recorded in Package.resolved, and nothing newer.
  if ! xcodebuild build -project "$ROOT_DIR/Stockbar.xcodeproj" -scheme Stockbar -configuration Release \
      -destination 'platform=macOS' -derivedDataPath "$derived_data" \
      -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO >"$log" 2>&1; then
    grep -E ': error:|^error:' "$log" | head -n 15 >&2 || true
    tail -n 20 "$log" >&2
    exit 1
  fi
  /usr/bin/ditto "$derived_data/Build/Products/Release/Stockbar.app" "$app"
fi

# Test-coverage counters run on every code path of the app. A scheme whose test
# action auto-creates its test plan builds them into every configuration, so
# check the binary itself rather than the settings.
sections="$(size -m "$app/Contents/MacOS/Stockbar")"
if grep -q '__llvm_prf' <<<"$sections"; then
  echo "Refusing to package: the app was built with test-coverage instrumentation." >&2
  exit 1
fi

plist="$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$plist"
if [[ -n "$version" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$plist"
fi
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")"

# Sign from the inside out: Sparkle's helpers, then the framework, then the app.
sign() {
  local output
  if ! output="$(/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$@" 2>&1)"; then
    echo "$output" >&2
    exit 1
  fi
}
sparkle="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$sparkle" ]] || { echo "Sparkle.framework is missing from the build" >&2; exit 1; }
sparkle_version="$sparkle/Versions/Current"
for nested in "$sparkle_version/XPCServices/Installer.xpc" "$sparkle_version/XPCServices/Downloader.xpc" \
    "$sparkle_version/Autoupdate" "$sparkle_version/Updater.app"; do
  [[ -e "$nested" ]] && sign --preserve-metadata=entitlements "$nested"
done
sign "$sparkle"
sign --entitlements "$entitlements" "$app"

/usr/bin/codesign --verify --deep --strict "$app"
# Nothing in the signature may identify a person: a certificate carries its
# owner's name, and an Apple one from a free account their email address.
if /usr/bin/codesign -dvv "$app" 2>&1 | grep -Eq '^Authority=|^TeamIdentifier=[A-Z0-9]{10}$'; then
  echo "Refusing to package: the app is signed with a certificate, whose owner's name would be published." >&2
  exit 1
fi
# Nor may the bundle carry a home-directory path from the machine that built it.
home_paths="$(find "$app" -type f -print0 | xargs -0 strings -a 2>/dev/null \
  | grep -Eo '/Users/[A-Za-z0-9._-]+/' | sort -u | grep -vxE '/Users/(runner|Shared)/' || true)"
if [[ -n "$home_paths" ]]; then
  echo "Refusing to package: the build contains $(wc -l <<<"$home_paths" | tr -d ' ') home-directory path(s)." >&2
  exit 1
fi

mkdir -p "$output_dir"
zip_path="$output_dir/Stockbar-$build_number.zip"
rm -f "$zip_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"

# Unpack the archive as a Mac would and start it. A build that cannot load its
# frameworks stops here rather than on someone's Mac. The run is isolated: it
# reads and writes only its own temporary folder and exits before any window.
check_dir="$(cd "$staging" && pwd -P)/check"
mkdir -p "$check_dir/app"
mkdir -m 700 "$check_dir/run"
/usr/bin/ditto -x -k "$zip_path" "$check_dir/app"
/usr/bin/codesign --verify --deep --strict "$check_dir/app/Stockbar.app"
if ! STOCKBAR_ACCEPTANCE_ROOT="$check_dir/run" STOCKBAR_ACCEPTANCE_RUN_ID="package-check-$$" \
    STOCKBAR_DISABLE_LIVE_PROVIDERS=1 "$check_dir/app/Stockbar.app/Contents/MacOS/Stockbar" \
    --acceptance-preflight >/dev/null 2>"$check_dir/start.log"; then
  echo "Refusing to package: the packaged app does not start." >&2
  head -n 5 "$check_dir/start.log" >&2
  rm -f "$zip_path"
  exit 1
fi

echo "Packaged Stockbar $version (build $build_number): $zip_path"
