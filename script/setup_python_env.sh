#!/usr/bin/env bash
# Creates Stockbar's own Python environment from a checkout. The app ships the
# same script and runs it from Settings > Advanced > Python.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Stockbar/Resources/setup_python_env.sh" "$@"
