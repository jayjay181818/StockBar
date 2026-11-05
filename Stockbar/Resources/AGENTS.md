# Python backend

- `get_stock_data.py` and `get_ohlc_data.py` supply provider data. App invocations emit valid JSON on stdout, diagnostics on stderr, and structured errors with `error`/`error_code`.
- Preserve reported-currency handling: GBX/GBp needs normalization; GBP does not. Use existing provider-specific fallback rules when currency is absent. Cover both cases in Python tests.
- Preserve rate limiting, atomic cache writes/locking and configurable provider priority. Inspect code for current delays and paths rather than copying constants into docs.
- Dependency versions come from `requirements.txt` and launch-time validation; do not upgrade them incidentally.
- `stockbar_worker.py` runs those scripts inside one long-lived interpreter. Scripts must keep working when re-executed with fresh globals: no import-time state that must reset, no direct writes to file descriptor 1.
- `setup_python_env.sh` builds Stockbar's own environment; the app runs it with `STOCKBAR_SUPPORT_DIR` and `STOCKBAR_REQUIREMENTS`. It must work with Finder's minimal `PATH` and switch environments atomically.
- Never skip or weaken the downloaded uv's SHA-256 check. Update `UV_VERSION` and both `UV_SHA256_*` together from the official release; the `STOCKBAR_UV_*` overrides are for tests.
- Run `bash script/develop.sh python-tests` for offline tests. Direct ticker commands call live providers; use `--json` when explicitly testing the app protocol.
