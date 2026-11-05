#!/usr/bin/env bash
# Creates Stockbar's own Python environment with a current Python and the
# pinned requirements. Stockbar uses it automatically unless the
# pythonInterpreterPath default names another interpreter.
#
# Run from Settings > Advanced > Python, or from a checkout:
#   bash script/setup_python_env.sh
#
# Uses uv when installed (it downloads the Python version if needed);
# otherwise a Homebrew or python.org Python 3.10+; otherwise it downloads a
# pinned uv release, checks its SHA-256 and keeps it, the Python it installs
# and its cache in Stockbar's own folders, so a Mac with only Apple's Python
# needs nothing installed first. Each run builds a fresh
# environment beside the current one and then switches the python-env link,
# so a running Stockbar never sees a half-installed environment.
# Environment:
#   STOCKBAR_PYTHON_VERSION   Python version for uv (default 3.13)
#   STOCKBAR_REQUIREMENTS     requirements file (default: beside this script)
#   STOCKBAR_SUPPORT_DIR      where python-env goes (default: Application Support/Stockbar)
#   STOCKBAR_CACHE_DIR        cache for the downloaded uv (default: ~/Library/Caches/Stockbar)
#   STOCKBAR_USE_OWN_UV=1     skip any installed uv or Python and use the downloaded uv
#   STOCKBAR_UV_URL, STOCKBAR_UV_SHA256
#                             override the uv download and its checksum (tests only)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIREMENTS="${STOCKBAR_REQUIREMENTS:-$SCRIPT_DIR/requirements.txt}"
PYTHON_VERSION="${STOCKBAR_PYTHON_VERSION:-3.13}"
SUPPORT_DIR="${STOCKBAR_SUPPORT_DIR:-$HOME/Library/Application Support/Stockbar}"
CACHE_DIR="${STOCKBAR_CACHE_DIR:-$HOME/Library/Caches/Stockbar}"
LINK="$SUPPORT_DIR/python-env"

# Pinned uv release used when nothing suitable is installed. To update, take the
# version and the .sha256 files from https://github.com/astral-sh/uv/releases.
UV_VERSION="0.13.7"
UV_SHA256_AARCH64="81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731"
UV_SHA256_X86_64="20c47e4c1f630b8abaff8c291fa9b9aa300fef92c4fbff95adf198b55287cda7"
BUILD_NAME="python-env-$(date +%Y%m%d%H%M%S)"
BUILD="$SUPPORT_DIR/$BUILD_NAME"

# Apps opened from Finder get a minimal PATH; look where uv and Python usually live.
PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
for framework in /Library/Frameworks/Python.framework/Versions/3.1[0-9]/bin; do
  if [[ -d "$framework" ]]; then PATH="$PATH:$framework"; fi
done
export PATH

[[ -f "$REQUIREMENTS" ]] || { echo "Requirements file not found: $REQUIREMENTS" >&2; exit 1; }

mkdir -p "$SUPPORT_DIR"
trap '[[ -L "$LINK" && "$(readlink "$LINK")" == "$BUILD_NAME" ]] || rm -rf "$BUILD"' EXIT

# Downloads the pinned uv into $SUPPORT_DIR/tools unless it is already there,
# and prints its path. Refuses a download whose SHA-256 does not match.
own_uv() {
  local arch expected url dir tmp archive
  case "$(uname -m)" in
    arm64|aarch64) arch="aarch64"; expected="$UV_SHA256_AARCH64" ;;
    x86_64) arch="x86_64"; expected="$UV_SHA256_X86_64" ;;
    *) echo "Unsupported Mac architecture: $(uname -m)" >&2; return 1 ;;
  esac
  url="${STOCKBAR_UV_URL:-https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$arch-apple-darwin.tar.gz}"
  expected="${STOCKBAR_UV_SHA256:-$expected}"
  dir="$SUPPORT_DIR/tools/uv-$UV_VERSION-$arch"
  if [[ -x "$dir/uv" && "$(cat "$dir/.sha256" 2>/dev/null)" == "$expected" ]]; then
    echo "$dir/uv"
    return 0
  fi

  echo "Downloading uv $UV_VERSION..." >&2
  mkdir -p "$SUPPORT_DIR/tools"
  tmp="$(mktemp -d "$SUPPORT_DIR/tools/.uv-download.XXXXXX")"
  archive="$tmp/uv.tar.gz"
  if ! /usr/bin/curl --fail --silent --show-error --location --proto '=https,file' \
      --retry 2 --output "$archive" "$url"; then
    rm -rf "$tmp"
    echo "Could not download uv from $url. Check the internet connection, or install uv or Python 3.10 or later." >&2
    return 1
  fi
  if [[ "$(/usr/bin/shasum -a 256 "$archive" | cut -d ' ' -f 1)" != "$expected" ]]; then
    rm -rf "$tmp"
    echo "The downloaded uv does not match its expected SHA-256; not using it." >&2
    return 1
  fi
  /usr/bin/tar -xzf "$archive" -C "$tmp"
  if [[ ! -x "$tmp/uv-$arch-apple-darwin/uv" ]]; then
    rm -rf "$tmp"
    echo "The downloaded uv archive has an unexpected layout." >&2
    return 1
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  mv "$tmp/uv-$arch-apple-darwin/uv" "$dir/uv"
  echo "$expected" > "$dir/.sha256"
  rm -rf "$tmp"
  echo "$dir/uv"
}

uv_bin=""
base=""
if [[ "${STOCKBAR_USE_OWN_UV:-}" != "1" ]]; then
  uv_bin="$(command -v uv || true)"
  if [[ -z "$uv_bin" ]]; then
    for candidate in "python$PYTHON_VERSION" python3.13 python3.12 python3.11 python3.10; do
      if command -v "$candidate" >/dev/null 2>&1; then
        base="$(command -v "$candidate")"
        break
      fi
    done
  fi
fi
if [[ -z "$uv_bin" && -z "$base" ]]; then
  uv_bin="$(own_uv)"
  # Keep the downloaded uv's Python and cache with Stockbar rather than in the
  # user's own uv folders, and never pick up a system Python.
  export UV_PYTHON_INSTALL_DIR="$SUPPORT_DIR/tools/python"
  export UV_CACHE_DIR="$CACHE_DIR/uv"
  export UV_PYTHON_PREFERENCE="only-managed"
  export UV_NO_CONFIG=1
fi

if [[ -n "$uv_bin" ]]; then
  echo "Creating Python $PYTHON_VERSION environment with uv..."
  "$uv_bin" venv --quiet --python "$PYTHON_VERSION" "$BUILD"
  echo "Installing packages..."
  "$uv_bin" pip install --quiet --python "$BUILD/bin/python3" -r "$REQUIREMENTS"
else
  echo "Creating environment with $base..."
  "$base" -m venv "$BUILD"
  echo "Installing packages..."
  "$BUILD/bin/python3" -m pip install --quiet --disable-pip-version-check -r "$REQUIREMENTS"
fi

echo "Checking the environment..."
"$BUILD/bin/python3" - <<'PY'
import ssl, sys
import requests, yfinance  # noqa: F401  (fails here rather than in the app)
print(f"Python {sys.version.split()[0]}, {ssl.OPENSSL_VERSION}")
PY

# Switch the link atomically. An older setup may have left a real directory.
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
  mv "$LINK" "$SUPPORT_DIR/python-env-previous-$(date +%Y%m%d%H%M%S)"
fi
previous="$( [[ -L "$LINK" ]] && readlink "$LINK" || true )"
ln -s "$BUILD_NAME" "$LINK.new"
# rename(2) replaces the link itself; mv would follow it into the old directory.
"$BUILD/bin/python3" -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$LINK.new" "$LINK"

# Keep the previous environment for a Stockbar still running on it; remove older ones.
for old in "$SUPPORT_DIR"/python-env-[0-9]*; do
  name="$(basename "$old")"
  if [[ -d "$old" && "$name" != "$BUILD_NAME" && "$name" != "$previous" ]]; then
    rm -rf "$old"
  fi
done

echo "Done. Stockbar uses $LINK/bin/python3 from its next refresh unless pythonInterpreterPath is set."
