# StockBar v3.1.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-05

A minor release focused on speed. Quotes and charts load faster, the app redraws less, and Stockbar can set up its own modern Python. No stored data changes.

## Faster market data

- Stockbar keeps up to two Python workers running instead of starting Python for every quote, history and OHLC request. Each request still runs the bundled script with fresh settings and API keys, but no longer pays Python's start-up and import cost. Live quotes took about 1.5 seconds instead of 2.4–3.9 seconds in testing, and history requests about 0.2 seconds.
- Workers stop after 15 minutes idle, when a request times out or is cancelled, and when Stockbar quits. If a worker cannot start, or both are busy, the request runs as a separate process as before.

## Stockbar's own Python

- **Settings > Advanced > Python** shows which interpreter Stockbar uses and its version, and offers **Set Up** (or **Rebuild**) to create Stockbar's own Python 3.13 environment in `~/Library/Application Support/Stockbar/python-env`. It uses uv when installed, otherwise a Homebrew or python.org Python 3.10 or later.
- The missing-packages alert offers **Set Up Automatically**, alongside copying the install command or opening Terminal.
- Stockbar picks its interpreter in this order: the `pythonInterpreterPath` setting, its own environment, then `/usr/bin/python3`. Existing setups keep working unchanged.
- A rebuild never disturbs a running Stockbar: the new environment is built beside the old one and switched in a single step.
- `requirements.txt` caps pandas below 4 until yfinance supports it.

## Smoother interface

- The shared data models use Swift's Observation framework, so SwiftUI redraws only the views whose data changed instead of every view watching a model.
- A holding added from the empty Holdings table now appears immediately.

## Fixes

- Settings > Menu Bar no longer crashes when VoiceOver or another accessibility tool reads it. The preview is still announced.
- The Python section says "Not available" when the interpreter's version cannot be read, instead of "Checking…" forever.

## Development

- The app compiles in Swift 6 language mode.
- `script/setup_python_env.sh` builds the same environment from the command line.
- New tests cover the worker protocol, the worker pool (reuse, timeouts, cancellation, fallback) and the environment set-up.

## Comparison basis

These notes cover the changes on `testing` after the v3.0.1 release commit (`8494ab8`).
