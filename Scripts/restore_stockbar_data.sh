#!/bin/bash

# Stockbar data restore script.
#
# This restores the files captured by backup_stockbar_data.sh. It does not
# include Keychain items, and it never stops Stockbar automatically. Current
# UserDefaults, config, cache and database files are saved to a
# StockbarDataModel_pre_restore_* directory before anything is overwritten.

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
# Quote cache (optional) is restored to the 2.4.5+ Caches location; the backup
# archive keeps the historical file name.
CACHE_FILE="${STOCKBAR_HOME}/Library/Caches/stockbar-cache/quote_cache.json"

fail() {
    echo "Error: $*" >&2
    exit 1
}

list_backups() {
    local path
    for path in "${BACKUP_DIR}"/stockbar_complete_backup_*; do
        [[ -d "${path}" ]] || continue
        basename "${path}"
    done | sort -r
}

require_stockbar_stopped() {
    command -v pgrep >/dev/null 2>&1 || fail "cannot verify whether Stockbar is running (pgrep is unavailable)"
    set +e
    pgrep -x "Stockbar" >/dev/null 2>&1
    local pgrep_status=$?
    set -e
    case "${pgrep_status}" in
        0) fail "Stockbar is running; quit it and rerun this restore" ;;
        1) return ;;
        *) fail "cannot verify whether Stockbar is running (pgrep exited ${pgrep_status})" ;;
    esac
}

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: $0 <backup_name>" >&2
    echo
    echo "Available backups:"
    list_backups || true
    exit 1
fi

BACKUP_NAME="$1"
if [[ ! "${BACKUP_NAME}" =~ ^stockbar_complete_backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]]; then
    fail "invalid backup name; pass the directory name printed by the backup script"
fi

BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"
if [[ ! -d "${BACKUP_PATH}" ]]; then
    echo "Error: backup not found at ${BACKUP_PATH}" >&2
    echo
    echo "Available backups:"
    list_backups || true
    exit 1
fi

require_stockbar_stopped

echo "=================================================="
echo "Stockbar Data Restore - $(date)"
echo "=================================================="
echo
echo "Restoring from: ${BACKUP_PATH}"
echo

read -r -p "This will overwrite current Stockbar data. Continue? (yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Restore cancelled."
    exit 0
fi
require_stockbar_stopped
echo

echo "[0/4] Saving current data before restore..."
mkdir -p "${STOCKBAR_DATA_DIR}"
RESTORE_STAMP=$(date +%Y%m%d_%H%M%S)
SAFETY_BACKUP="${STOCKBAR_DATA_DIR}/StockbarDataModel_pre_restore_${RESTORE_STAMP}"
if [[ -e "${SAFETY_BACKUP}" ]]; then
    fail "safety backup path already exists at ${SAFETY_BACKUP}; refusing to overwrite it"
fi
mkdir "${SAFETY_BACKUP}" || fail "cannot create safety backup directory ${SAFETY_BACKUP}; restore aborted before any change"

if ! "${DEFAULTS_COMMAND}" export com.stockbar "${SAFETY_BACKUP}/UserDefaults.plist"; then
    # A missing domain (fresh install) has nothing to preserve; any other
    # failure must stop the restore before current settings are replaced.
    if "${DEFAULTS_COMMAND}" read com.stockbar >/dev/null 2>&1; then
        fail "cannot export current UserDefaults to ${SAFETY_BACKUP}; restore aborted before any change"
    fi
    echo "Note: no existing com.stockbar defaults to preserve"
fi
if [[ -f "${CONFIG_FILE}" ]]; then
    cp "${CONFIG_FILE}" "${SAFETY_BACKUP}/.stockbar_config.json" || fail "cannot save current config file; restore aborted before any change"
fi
if [[ -f "${CACHE_FILE}" ]]; then
    cp "${CACHE_FILE}" "${SAFETY_BACKUP}/quote_cache.json" || fail "cannot save current cache file; restore aborted before any change"
fi
for file in "StockbarDataModel.sqlite" "StockbarDataModel.sqlite-wal" "StockbarDataModel.sqlite-shm"; do
    if [[ -f "${STOCKBAR_DATA_DIR}/${file}" ]]; then
        cp "${STOCKBAR_DATA_DIR}/${file}" "${SAFETY_BACKUP}/${file}" || fail "cannot save current ${file}; restore aborted before any change"
    fi
done
STATE_FOLDERS=("BrokerLinks" "AliasIdentityMigration" "Folync" "FolyncSupplemental")
for folder in "${STATE_FOLDERS[@]}"; do
    if [[ -d "${STOCKBAR_DATA_DIR}/${folder}" ]]; then
        cp -R "${STOCKBAR_DATA_DIR}/${folder}" "${SAFETY_BACKUP}/${folder}" || fail "cannot save current ${folder}; restore aborted before any change"
    fi
done
echo "Current UserDefaults, config, cache, database and linked data preserved in: ${SAFETY_BACKUP}"
echo

echo "[1/4] Restoring UserDefaults..."
if [[ -f "${BACKUP_PATH}/UserDefaults.plist" ]]; then
    "${DEFAULTS_COMMAND}" import com.stockbar "${BACKUP_PATH}/UserDefaults.plist"
    echo "UserDefaults restored"
else
    echo "Warning: UserDefaults.plist not found in backup"
fi
echo

echo "[2/4] Restoring Core Data..."
if [[ -f "${BACKUP_PATH}/StockbarDataModel.sqlite" ]]; then
    cp "${BACKUP_PATH}/StockbarDataModel.sqlite" "${STOCKBAR_DATA_DIR}/"
    for sidecar in "StockbarDataModel.sqlite-wal" "StockbarDataModel.sqlite-shm"; do
        if [[ -f "${BACKUP_PATH}/${sidecar}" ]]; then
            cp "${BACKUP_PATH}/${sidecar}" "${STOCKBAR_DATA_DIR}/"
        elif [[ -f "${STOCKBAR_DATA_DIR}/${sidecar}" ]]; then
            # The old sidecar was preserved above. Remove it so it cannot be
            # paired with the restored main database.
            rm -f "${STOCKBAR_DATA_DIR}/${sidecar}"
        fi
    done
    echo "Core Data restored ($(du -h "${STOCKBAR_DATA_DIR}/StockbarDataModel.sqlite" | awk '{print $1}'))"
else
    echo "Warning: StockbarDataModel.sqlite not found in backup"
fi
echo

echo "Restoring broker links, alias records and Folync data..."
# Only folders present in the backup are replaced: an older backup without
# them leaves the current ones alone (they were preserved above either way).
for folder in "${STATE_FOLDERS[@]}"; do
    if [[ -d "${BACKUP_PATH}/${folder}" ]]; then
        rm -rf "${STOCKBAR_DATA_DIR:?}/${folder}"
        cp -R "${BACKUP_PATH}/${folder}" "${STOCKBAR_DATA_DIR}/${folder}"
        echo "${folder} restored"
    fi
done
echo

echo "[3/4] Restoring API configuration..."
if [[ -f "${BACKUP_PATH}/.stockbar_config.json" ]]; then
    mkdir -p "$(dirname "${CONFIG_FILE}")"
    cp "${BACKUP_PATH}/.stockbar_config.json" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    echo "Config file restored to ${CONFIG_FILE}"
else
    echo "Warning: .stockbar_config.json not found in backup"
fi
echo

echo "[4/4] Restoring cache file..."
if [[ -f "${BACKUP_PATH}/.stockbar_cache.json" ]]; then
    mkdir -p "$(dirname "${CACHE_FILE}")"
    cp "${BACKUP_PATH}/.stockbar_cache.json" "${CACHE_FILE}"
    echo "Cache file restored"
else
    echo "No cache file in backup (will regenerate)"
fi
echo

echo "=================================================="
echo "Restore Complete"
echo "=================================================="
echo
echo "Restored from: ${BACKUP_NAME}"
echo "Keychain items were not restored; review credentials separately."
echo "Review MANIFEST.txt before restarting Stockbar:"
if [[ -f "${BACKUP_PATH}/MANIFEST.txt" ]]; then
    cat "${BACKUP_PATH}/MANIFEST.txt"
fi
