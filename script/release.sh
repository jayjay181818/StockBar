#!/usr/bin/env bash
# Sets the version everywhere it is written, and refuses to continue when the
# release notes or README entry for it are missing. It changes files only: it
# does not commit, tag or push.
#
#   bash script/release.sh 3.5.0
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: bash script/release.sh X.Y.Z" >&2
  exit 64
fi
IFS=. read -r major minor patch <<<"$version"
if (( minor > 9 || patch > 9 )); then
  echo "The build number is the version without dots (3.4.0 -> 340), so minor and patch must be 0-9." >&2
  exit 64
fi
build="${major}${minor}${patch}"
project="Stockbar.xcodeproj/project.pbxproj"
notes="Changelogs/release_notes_v${version}.md"

missing=0
if [[ ! -f "$notes" ]]; then
  echo "Missing $notes. Write the release notes first." >&2
  missing=1
fi
if ! grep -Eq "^### .*Version ${version//./\\.}([^0-9.]|$)" README.md; then
  echo "README.md has no release-history entry headed 'Version $version'. Add it first." >&2
  missing=1
fi
[[ "$missing" -eq 0 ]] || exit 1

/usr/bin/sed -i '' -E \
  -e "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = ${version};/" \
  -e "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${build};/" \
  "$project"
today="$(LC_ALL=en_US.UTF-8 date '+%B %-d, %Y')"
/usr/bin/sed -i '' -E \
  "s/Last updated: [^·<]*· Version [0-9.]+/Last updated: ${today} · Version ${version}/" README.md

python3 Scripts/validate_agent_docs.py >/dev/null
echo "Version set to $version (build $build) in the project and README."
echo "Next: commit on a branch, open a pull request into testing, and after it"
echo "is merged tag the merge commit:  git tag -a v$version -m \"Stockbar $version\""
