# StockBar v3.2.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-05

A minor release that makes Stockbar's own Python the only built-in way to fetch market data. Setup now works on a Mac with nothing installed, Apple's outdated Python 3.9 is no longer used, and yfinance is current. No stored data changes.

**After updating:** if Stockbar was using Apple's `/usr/bin/python3`, it asks once to **Set Up Stockbar's Python**. If it already used its own Python environment, it shows **Python Dependencies Required** instead, because the pinned versions changed. Either way, choose **Set Up Automatically**; it needs an internet connection and usually takes under a minute. Until then, prices from the Python providers (yfinance, FMP, Twelve Data, Stooq) are unavailable. Trading 212 and Folync data are not affected.

## Setup on any Mac

- **Settings > Advanced > Python > Set Up** no longer needs uv or a Python 3.10+ installed first. When neither is found, Stockbar downloads a pinned release of uv (0.13.7) from its official GitHub releases, refuses it unless its SHA-256 matches the value built into Stockbar, and keeps it and the Python 3.13 it installs in `~/Library/Application Support/Stockbar/tools`. Its download cache is in `~/Library/Caches/Stockbar`.
- That copy of uv ignores other Pythons and your own uv settings, so it neither depends on nor changes anything else on the Mac.
- An installed uv or Python 3.10+ is still used first, as before.

## No more system Python

- Stockbar uses the `pythonInterpreterPath` setting if set, otherwise its own environment. It no longer falls back to Apple's `/usr/bin/python3` 3.9, which could not run current, security-fixed versions of urllib3, requests or yfinance.
- Settings shows **Not set up** when the environment does not exist yet. The launch alert then offers **Set Up Automatically** or **Dismiss**; it asks once, not on every launch.
- An interpreter set with `pythonInterpreterPath` must be Python 3.10 or later.

## Market data

- yfinance 1.8.0 (from 1.2.0). The bridge scripts needed no changes. The `Pandas4Warning` lines that yfinance used to print on every fetch are gone.
- `requirements.txt` now has a single set of pins: yfinance 1.8.0, requests 2.34.2, urllib3 2.8.0, and pandas below 4 until pandas 4 is released and tested.

## Fixes

- When Stockbar's own Python is not set up, fetch errors say so and point to **Settings > Advanced > Python > Set Up**, instead of asking you to install Python 3.

## Development

- CI runs on Python 3.13 only.
- Dependabot manages urllib3 and requests again.
- `Scripts/tests/test_setup_python_env.py` tests the uv download offline: a verified download, reuse, refusal on a checksum mismatch, re-download after the pin changes, and a failed download.
- To update the uv pin, change `UV_VERSION` and both `UV_SHA256_*` values in `setup_python_env.sh` together (see Docs/Development.md).

## Comparison basis

These notes cover the changes on `testing` after tag `v3.1.1`.
