#!/usr/bin/env bash
# Creates Stockbar's own Python environment with a current Python and the
# pinned requirements. Stockbar uses it automatically unless the
# pythonInterpreterPath default names another interpreter.
#
# Run from Settings > Advanced > Python, or from a checkout:
#   bash script/setup_python_env.sh
#
# Uses uv when installed (it downloads the Python version if needed);
# otherwise a Homebrew or python.org Python 3.10+. Each run builds a fresh
# environment beside the current one and then switches the python-env link,
# so a running Stockbar never sees a half-installed environment.
# Environment:
#   STOCKBAR_PYTHON_VERSION   Python version for uv (default 3.13)
#   STOCKBAR_REQUIREMENTS     requirements file (default: beside this script)
#   STOCKBAR_SUPPORT_DIR      where python-env goes (default: Application Support/Stockbar)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIREMENTS="${STOCKBAR_REQUIREMENTS:-$SCRIPT_DIR/requirements.txt}"
PYTHON_VERSION="${STOCKBAR_PYTHON_VERSION:-3.13}"
SUPPORT_DIR="${STOCKBAR_SUPPORT_DIR:-$HOME/Library/Application Support/Stockbar}"
LINK="$SUPPORT_DIR/python-env"
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

if command -v uv >/dev/null 2>&1; then
  echo "Creating Python $PYTHON_VERSION environment with uv..."
  uv venv --quiet --python "$PYTHON_VERSION" "$BUILD"
  echo "Installing packages..."
  uv pip install --quiet --python "$BUILD/bin/python3" -r "$REQUIREMENTS"
else
  base=""
  for candidate in "python$PYTHON_VERSION" python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
      base="$(command -v "$candidate")"
      break
    fi
  done
  if [[ -z "$base" ]]; then
    echo "Needs uv (https://docs.astral.sh/uv/) or Python 3.10 or later (brew install python@3.13)." >&2
    exit 1
  fi
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
