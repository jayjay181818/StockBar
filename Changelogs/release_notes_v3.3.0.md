# StockBar v3.3.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-06

A minor release that adds encrypted export and import of Stockbar's settings, keys and portfolio, for example to move to another Mac. It also fixes a hang after an import and a misleading Python alert. No stored data changes, and the Python pins are the same as in 3.2.0.

## Export & Import

- **Settings → Advanced → Export & Import** (a new section after Backups) has **Export…** and **Import…**.
- **Settings & Keys** exports preferences and configuration (general, menu bar, appearance, refresh, backups and logging, Trading 212 and Folync settings, provider priority), the FMP and Twelve Data API keys, the Trading 212 API key and secret for each stored environment, and the Folync client token.
- **Everything** adds the portfolio database, copied consistently through Core Data, plus broker links. Its estimated size is shown before exporting.
- Machine-specific state is never exported or overwritten: the Python interpreter and dependency-check state, window positions, caches and timestamps. Set up Stockbar's Python on the new Mac when asked.

### Security

- Every `.stockbarexport` file is encrypted with a password of at least 8 characters: AES-256-GCM, with the key derived by PBKDF2-HMAC-SHA256 (600,000 iterations, random 32-byte salt, fresh nonce). The whole header is authenticated.
- A wrong password or a damaged or altered file gives "Wrong password, or the file is damaged." Files from a newer format, with the wrong header or cut short are rejected. In every case nothing is applied.
- The file contains your API keys and broker credentials, so keep it and its password safe.

### Import

- Stockbar decrypts and checks the whole file first, including opening the database as a trial, and shows what the file contains before asking to replace anything.
- It then pauses refresh and sync, backs up the portfolio, keeps a safety copy of the database and applies the file. Any failure restores the previous settings, credentials and database. Keys not in the file stay as they are.
- On success it offers **Relaunch Now** or **Quit**, with the prompt shown in front.

## Fixes

- **Relaunch Now** and **Quit** after an import no longer hang and need a force quit.
- **Python Dependencies Required** offers **Copy Command** and **Open Terminal** only when `pythonInterpreterPath` points at another Python. For Stockbar's own environment, which is built without pip, the copied `pip install` command failed; the alert now offers **Set Up Automatically** or **Dismiss** and explains that packages are missing or outdated, for example after an update.

## Development

- 16 new `SettingsTransferTests` cover round trips, a wrong password, tampering, truncation, version and header checks, an incompatible database, excluded keys and rollback.
- Tests and acceptance runs use a per-run Trading 212 Keychain service, like Folync. Production still uses `com.stockbar.trading212`.

## Comparison basis

These notes cover the changes on `testing` after tag `v3.2.0`.
