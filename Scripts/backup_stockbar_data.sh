#!/bin/bash

# Stockbar data backup script.
#
# This backs up the data files used by Stockbar. It does not include Keychain
# items, and it must not run while Stockbar is using its SQLite store.

set -euo pipefail
umask 077

# STOCKBAR_HOME_OVERRIDE is intended for isolated fixture tests. In normal use
# the script resolves paths below the current user's home directory.
STOCKBAR_HOME="${STOCKBAR_HOME_OVERRIDE:-$HOME}"
if [[ -n "${STOCKBAR_HOME_OVERRIDE:-}" ]]; then
    [[ -n "${STOCKBAR_DEFAULTS_COMMAND:-}" ]] || {
        echo "Error: STOCKBAR_HOME_OVERRIDE requires STOCKBAR_DEFAULTS_COMMAND to isolate defaults" >&2
        exit 1
    }
fi
DEFAULTS_COMMAND="${STOCKBAR_DEFAULTS_COMMAND:-defaults}"
command -v "${DEFAULTS_COMMAND}" >/dev/null 2>&1 || {
    echo "Error: defaults command is unavailable: ${DEFAULTS_COMMAND}" >&2
    exit 1
}
APP_SUPPORT_DIR="${STOCKBAR_HOME}/Library/Application Support"
STOCKBAR_DATA_DIR="${APP_SUPPORT_DIR}/Stockbar"
BACKUP_DIR="${STOCKBAR_DATA_DIR}/Backups"
CONFIG_FILE="${APP_SUPPORT_DIR}/com.stockbar/.stockbar_config.json"
# Quote cache (optional). 2.4.5+ keeps it in Caches; older versions used the
# home folder. The backup archive keeps the historical file name.
CACHE_FILE="${STOCKBAR_HOME}/Library/Caches/stockbar-cache/quote_cache.json"
LEGACY_CACHE_FILE="${STOCKBAR_HOME}/.stockbar_cache.json"

TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
BACKUP_NAME="stockbar_complete_backup_${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_stockbar_stopped() {
    command -v pgrep >/dev/null 2>&1 || fail "cannot verify whether Stockbar is running (pgrep is unavailable)"
    set +e
    pgrep -x "Stockbar" >/dev/null 2>&1
    local pgrep_status=$?
    set -e
    case "${pgrep_status}" in
        0) fail "Stockbar is running; quit it and rerun this backup so SQLite files are copied consistently" ;;
        1) return ;;
        *) fail "cannot verify whether Stockbar is running (pgrep exited ${pgrep_status})" ;;
    esac
}

file_size() {
    du -h "$1" | awk '{print $1}'
}

STATE_FOLDERS=("BrokerLinks" "AliasIdentityMigration" "Folync" "FolyncSupplemental")

require_stockbar_stopped
mkdir -p "${BACKUP_DIR}"
if ! mkdir "${BACKUP_PATH}"; then
    fail "backup already exists at ${BACKUP_PATH}; refusing to overwrite it"
fi

echo "=================================================="
echo "Stockbar Data Backup - $(date)"
echo "=================================================="
echo
echo "Backup location: ${BACKUP_PATH}"
echo

echo "[1/4] Backing up UserDefaults..."
"${DEFAULTS_COMMAND}" export com.stockbar "${BACKUP_PATH}/UserDefaults.plist"
echo "UserDefaults backed up ($(file_size "${BACKUP_PATH}/UserDefaults.plist"))"
echo

echo "[2/4] Backing up Core Data database..."
if [[ -f "${STOCKBAR_DATA_DIR}/StockbarDataModel.sqlite" ]]; then
    cp "${STOCKBAR_DATA_DIR}/StockbarDataModel.sqlite" "${BACKUP_PATH}/"
    for sidecar in "StockbarDataModel.sqlite-wal" "StockbarDataModel.sqlite-shm"; do
        if [[ -f "${STOCKBAR_DATA_DIR}/${sidecar}" ]]; then
            cp "${STOCKBAR_DATA_DIR}/${sidecar}" "${BACKUP_PATH}/"
        fi
    done
    echo "Core Data backed up ($(file_size "${BACKUP_PATH}/StockbarDataModel.sqlite"))"
else
    echo "Warning: Core Data database not found"
fi
echo

echo "[3/4] Backing up API configuration..."
if [[ -f "${CONFIG_FILE}" ]]; then
    cp "${CONFIG_FILE}" "${BACKUP_PATH}/.stockbar_config.json"
    chmod 600 "${BACKUP_PATH}/.stockbar_config.json"
    echo "Config file backed up ($(file_size "${BACKUP_PATH}/.stockbar_config.json"))"
else
    echo "Warning: config file not found (may be first run)"
fi
echo

echo "Backing up broker links, alias records and Folync data..."
# These live beside the database and describe it: which broker account each
# holding belongs to, renamed tickers, and Folync's saved portfolio.
for folder in "${STATE_FOLDERS[@]}"; do
    if [[ -d "${STOCKBAR_DATA_DIR}/${folder}" ]]; then
        cp -R "${STOCKBAR_DATA_DIR}/${folder}" "${BACKUP_PATH}/${folder}"
        echo "${folder} backed up"
    fi
done
echo

echo "[4/4] Backing up cache file..."
SOURCE_CACHE_FILE="${CACHE_FILE}"
[[ -f "${SOURCE_CACHE_FILE}" ]] || SOURCE_CACHE_FILE="${LEGACY_CACHE_FILE}"
if [[ -f "${SOURCE_CACHE_FILE}" ]]; then
    cp "${SOURCE_CACHE_FILE}" "${BACKUP_PATH}/.stockbar_cache.json"
    echo "Cache file backed up ($(file_size "${BACKUP_PATH}/.stockbar_cache.json"))"
else
    echo "No cache file found (expected)"
fi
echo

echo "Creating backup manifest..."
cat > "${BACKUP_PATH}/MANIFEST.txt" <<EOF
Stockbar Data Backup
====================

Backup Date: $(date)
Backup Location: ${BACKUP_PATH}

Contents:
---------
1. UserDefaults.plist - Portfolio configuration and app preferences
2. StockbarDataModel.sqlite* - Historical price data and OHLC snapshots
3. .stockbar_config.json - API keys and configuration (if present)
4. .stockbar_cache.json - Price cache (optional)
5. BrokerLinks, AliasIdentityMigration, Folync, FolyncSupplemental - broker
   account links, renamed-ticker records and Folync data (if present)

Keychain items are not included. This backup alone does not prove complete
recovery of credentials or other data held outside these files.

Restore prerequisites:
---------------------
1. Quit Stockbar and verify that no Stockbar process is running.
2. From the repository root, run: bash Scripts/restore_stockbar_data.sh ${BACKUP_NAME}
3. Review the restore output before restarting Stockbar.

Canonical config path:
${CONFIG_FILE}
EOF

echo "Manifest created"
echo
echo "=================================================="
echo "Backup Complete"
echo "=================================================="
echo "Total backup size: $(du -sh "${BACKUP_PATH}" | awk '{print $1}')"
echo "Location: ${BACKUP_PATH}"
echo
echo "Files backed up:"
ls -lh "${BACKUP_PATH}"
echo
echo "To restore this backup later:"
echo "  bash Scripts/restore_stockbar_data.sh ${BACKUP_NAME}"
echo
echo "Existing backups were left untouched; retention cleanup is manual."
