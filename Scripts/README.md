# Stockbar backup and restore scripts

These scripts preserve the local Stockbar files needed to recover portfolio preferences and historical data. They do not include Keychain items, so a successful file restore is not proof that every credential or external data source can be recovered.

## Before you run either script

Quit Stockbar and verify that no `Stockbar` process is running. The scripts fail closed when they cannot verify this, and they never stop the app automatically. This is required so the SQLite database and its `-wal`/`-shm` sidecars are copied as one consistent set.

The scripts use the current user's home directory by default. For isolated fixture tests only, set `STOCKBAR_HOME_OVERRIDE` to a temporary directory and set `STOCKBAR_DEFAULTS_COMMAND` to an executable mock. The override refuses to run without that explicit defaults command, so fixture tests cannot accidentally write the real `com.stockbar` defaults domain. Do not point either variable at a real home directory or the real `defaults` command.

## Create a backup

```bash
bash Scripts/backup_stockbar_data.sh
```

Backups are written below:

```text
~/Library/Application Support/Stockbar/Backups/stockbar_complete_backup_YYYY-MM-DD_HHMMSS/
```

Each backup may contain:

- `UserDefaults.plist` — portfolio configuration and app preferences
- `StockbarDataModel.sqlite`, plus any matching `-wal` and `-shm` files
- `.stockbar_config.json` — API keys and provider settings
- `.stockbar_cache.json` — optional price cache (from `~/Library/Caches/stockbar-cache/quote_cache.json`, or the legacy `~/.stockbar_cache.json`)
- `MANIFEST.txt` — captured contents, canonical paths, and restore prerequisites

Existing backups are never deleted automatically. Remove an old backup only after checking its contents and confirming that it is no longer needed.

The API configuration is read from the canonical path used by the app:

```text
~/Library/Application Support/com.stockbar/.stockbar_config.json
```

The previous `~/Documents/.stockbar_config.json` path is not used by these scripts. If a legacy file is still present, let Stockbar migrate it or handle that migration explicitly before backing up.

## Restore a backup

```bash
bash Scripts/restore_stockbar_data.sh stockbar_complete_backup_2026-09-05_102800
```

The restore script:

1. Verifies the backup name and location, then verifies that Stockbar is stopped.
2. Requests an explicit `yes` confirmation before overwriting data.
3. Imports `UserDefaults.plist` when present.
4. Copies the SQLite database and matching sidecars. Existing database files are preserved in a timestamped `StockbarDataModel_pre_restore_*` directory first; stale destination sidecars are removed only after that safety copy.
5. Restores `.stockbar_config.json` to `~/Library/Application Support/com.stockbar/.stockbar_config.json` with mode `600`.
6. Restores the optional cache and prints the manifest.

Review the output and manifest before restarting Stockbar. Keychain items are not restored by this procedure and must be handled separately.

## What is covered

| Store | Location | Included |
| --- | --- | --- |
| UserDefaults | `~/Library/Preferences/com.stockbar.plist` (via `defaults`) | Yes |
| Core Data | `~/Library/Application Support/Stockbar/StockbarDataModel.sqlite*` | Yes, when present |
| API configuration | `~/Library/Application Support/com.stockbar/.stockbar_config.json` | Yes, when present |
| Price cache | `~/Library/Caches/stockbar-cache/quote_cache.json` (legacy: `~/.stockbar_cache.json`) | Optional |
| Keychain | macOS Keychain services | No |

The scripts do not publish backups, upload them, or validate provider credentials. Keep backup directories private because the configuration file contains sensitive API keys.

## Run the isolated checks

From the repository root:

```bash
python3 -m unittest discover -s Scripts/tests -v
```

The recovery tests use a temporary fixture home, a mocked `defaults` executable, and mocked process probes. They do not read or write your real defaults domain, database, config, cache, or Keychain.

## Troubleshooting

- If the script says Stockbar is running, quit the app and check `pgrep -x Stockbar` before retrying.
- If a backup is missing, list `~/Library/Application Support/Stockbar/Backups/` and pass the exact directory name.
- If a restore fails, keep the printed `StockbarDataModel_pre_restore_*` directory and inspect the manifest before attempting another restore.
- To inspect the restored SQLite store, use a read-only command such as `sqlite3 ... '.tables'` after Stockbar remains stopped.
