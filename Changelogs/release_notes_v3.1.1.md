# StockBar v3.1.1 Release Notes

**Status:** Implemented  
**Date:** 2026-11-05

A security patch for 3.1.0. It updates the Python HTTP packages that fetch market data. No stored data changes.

## Security

- Stockbar's own Python environment (Settings > Advanced > Python) now installs urllib3 2.8.0 and requests 2.34.2. They fix seven published urllib3 vulnerabilities (six rated high) and one requests vulnerability (medium).
- After updating, Stockbar checks its Python packages again on the next launch. If the environment still has the old versions, choose **Set Up Automatically** in the prompt, or **Rebuild** in Settings > Advanced > Python.

## Python fallback

- Apple's `/usr/bin/python3` 3.9 is built on LibreSSL, which urllib3 2.x does not support, and the fixed releases need Python 3.10 or later. When Stockbar falls back to it, it keeps urllib3 1.26.20 and requests 2.32.5. Use Stockbar's own environment to get the fixes.
- `requirements.txt` chooses the right versions with `python_version` markers, so pip and uv install the matching set for each interpreter.

## Fixes

- The launch-time dependency check reads the interpreter's Python version and compares the installed packages with the pins meant for it. It also runs again whenever an update changes the pins, not only when the interpreter changes.

## Development

- CI also runs the Python tests on Python 3.13, which installs the current pins. The existing job keeps covering the 3.9 fallback.
- Dependabot no longer updates urllib3 or requests, because it cannot tell the two pin sets apart. Bump the `python_version >= "3.10"` lines by hand.
- GitHub Actions used by CI were updated to their latest major versions.

## Comparison basis

These notes cover the changes on `testing` after tag `v3.1.0`.
