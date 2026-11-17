#!/usr/bin/env bash
# Signs a packaged build for the updater and lists it in an update feed.
# The release workflow runs this after script/package_release.sh.
#
#   SPARKLE_ED_PRIVATE_KEY=... bash script/sign_release.sh \
#       --archive build/release/Stockbar-360.14.zip --appcast feed/appcast.xml \
#       --channel testing --url https://.../Stockbar-360.14.zip \
#       --notes-file notes.md [--link https://.../releases/tag/testing-360.14]
#
# The update key comes from SPARKLE_ED_PRIVATE_KEY and is only ever passed on
# standard input, never as an argument. The version, build number, minimum
# macOS and public key are read from the app inside the archive. The archive's
# signature is checked against that public key before the feed is touched: a
# build signed with the wrong key would be refused by every copy of Stockbar.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

archive="" appcast="" channel="" url="" notes_file="" link=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) archive="${2:-}"; shift 2 ;;
    --appcast) appcast="${2:-}"; shift 2 ;;
    --channel) channel="${2:-}"; shift 2 ;;
    --url) url="${2:-}"; shift 2 ;;
    --notes-file) notes_file="${2:-}"; shift 2 ;;
    --link) link="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done
if [[ -z "$archive" || -z "$appcast" || -z "$channel" || -z "$url" || -z "$notes_file" ]]; then
  echo "Usage: bash script/sign_release.sh --archive zip --appcast xml --channel stable|testing|experimental --url address --notes-file file [--link page]" >&2
  exit 64
fi
[[ -f "$archive" ]] || { echo "No archive at $archive" >&2; exit 66; }
[[ -f "$notes_file" ]] || { echo "No release notes at $notes_file" >&2; exit 66; }
if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_ED_PRIVATE_KEY is not set: the update key is needed to sign the build." >&2
  exit 78
fi

# Sparkle's own signing tool, from the package the build resolved.
sign_update="${STOCKBAR_SIGN_UPDATE:-}"
if [[ -z "$sign_update" ]]; then
  for derived_data in "${STOCKBAR_DERIVED_DATA:-$ROOT_DIR/build/ReleaseDerivedData}" "$ROOT_DIR/build/DevelopmentDerivedData"; do
    candidate="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
    if [[ -x "$candidate" ]]; then sign_update="$candidate"; break; fi
  done
fi
[[ -x "$sign_update" ]] || { echo "Sparkle's sign_update was not found. Build the app first." >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/stockbar-sign.XXXXXX")"
trap 'rm -rf "$work"' EXIT
/usr/bin/unzip -q -j "$archive" 'Stockbar.app/Contents/Info.plist' -d "$work"
read_plist() { /usr/bin/plutil -extract "$1" raw -o - "$work/Info.plist"; }
build="$(read_plist CFBundleVersion)"
version="$(read_plist CFBundleShortVersionString)"
minimum_system="$(read_plist LSMinimumSystemVersion)"
public_key="$(read_plist SUPublicEDKey)"

signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --ed-key-file - -p "$archive")"
/usr/bin/swift "$ROOT_DIR/script/verify_update_signature.swift" "$archive" "$signature" "$public_key"

mkdir -p "$(dirname "$appcast")"
python3 "$ROOT_DIR/Scripts/release_feed.py" add --appcast "$appcast" --channel "$channel" \
  --build "$build" --version "$version" --url "$url" --length "$(/usr/bin/stat -f %z "$archive")" \
  --signature "$signature" --minimum-system "$minimum_system" --notes-file "$notes_file" --link "$link"

# The app accepts a feed only with this signature (SURequireSignedFeed).
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$appcast"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --ed-key-file - --verify "$appcast"
echo "Signed Stockbar $version (build $build) and listed it on the $channel channel."
