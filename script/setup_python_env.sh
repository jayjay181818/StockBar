#!/usr/bin/env bash
# Creates Stockbar's own Python environment with a current Python and the
# pinned requirements. Stockbar uses it automatically unless the
# pythonInterpreterPath default names another interpreter.
#
#   bash script/setup_python_env.sh
#
# Uses uv when installed (it downloads the Python version if needed);
# otherwise a Homebrew or python.org Python 3.10+. Each run builds a fresh
# environment beside the current one and then switches the python-env link,
# so a running Stockbar never sees a half-installed environment.
# Environment: STOCKBAR_PYTHON_VERSION (default 3.13)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIREMENTS="$ROOT_DIR/Stockbar/Resources/requirements.txt"
PYTHON_VERSION="${STOCKBAR_PYTHON_VERSION:-3.13}"
SUPPORT_DIR="$HOME/Library/Application Support/Stockbar"
LINK="$SUPPORT_DIR/python-env"
BUILD_NAME="python-env-$(date +%Y%m%d%H%M%S)"
BUILD="$SUPPORT_DIR/$BUILD_NAME"

mkdir -p "$SUPPORT_DIR"
trap '[[ -L "$LINK" && "$(readlink "$LINK")" == "$BUILD_NAME" ]] || rm -rf "$BUILD"' EXIT

if command -v uv >/dev/null 2>&1; then
  echo "Creating Python $PYTHON_VERSION environment with uv..."
  uv venv --quiet --python "$PYTHON_VERSION" "$BUILD"
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
  "$BUILD/bin/python3" -m pip install --quiet --disable-pip-version-check -r "$REQUIREMENTS"
fi

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

echo "Stockbar will use $LINK/bin/python3 unless pythonInterpreterPath is set."
echo "Quit and reopen Stockbar to switch."
