#!/bin/bash

# Stockbar Complete Data Restore Script
# Restores all Stockbar data from a complete backup

set -e  # Exit on error

# Check if backup name was provided
if [ -z "$1" ]; then
    echo "Usage: $0 <backup_name>"
    echo ""
    echo "Available backups:"
    BACKUP_DIR="$HOME/Library/Application Support/Stockbar/Backups"
    ls -1t "${BACKUP_DIR}" | grep "stockbar_complete_backup_"
    echo ""
    exit 1
fi

BACKUP_NAME="$1"
BACKUP_DIR="$HOME/Library/Application Support/Stockbar/Backups"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Verify backup exists
if [ ! -d "${BACKUP_PATH}" ]; then
    echo "❌ Error: Backup not found at ${BACKUP_PATH}"
    echo ""
    echo "Available backups:"
    ls -1t "${BACKUP_DIR}" | grep "stockbar_complete_backup_"
    exit 1
fi

echo "=================================================="
echo "Stockbar Complete Restore - $(date)"
echo "=================================================="
echo ""
echo "Restoring from: ${BACKUP_PATH}"
echo ""

# Warning prompt
read -p "⚠️  This will OVERWRITE current Stockbar data. Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
fi
echo ""

# Check if Stockbar is running
if pgrep -x "Stockbar" > /dev/null; then
    echo "⚠️  Stockbar is currently running!"
    read -p "Do you want to quit Stockbar now? (yes/no): " QUIT
    if [ "$QUIT" = "yes" ]; then
        echo "Quitting Stockbar..."
        killall Stockbar || true
        sleep 2
    else
        echo "❌ Please quit Stockbar manually and run this script again."
        exit 1
    fi
fi
echo ""

# 1. Restore UserDefaults
echo "[1/4] Restoring UserDefaults..."
if [ -f "${BACKUP_PATH}/UserDefaults.plist" ]; then
    defaults import com.fhl43211.Stockbar "${BACKUP_PATH}/UserDefaults.plist"
    echo "✅ UserDefaults restored"
else
    echo "⚠️  UserDefaults.plist not found in backup"
fi
echo ""

# 2. Restore Core Data
echo "[2/4] Restoring Core Data..."
COREDATA_DIR="$HOME/Library/Application Support/Stockbar"
mkdir -p "${COREDATA_DIR}"

if [ -f "${BACKUP_PATH}/StockbarDataModel.sqlite" ]; then
    # Backup current database before overwriting
    if [ -f "${COREDATA_DIR}/StockbarDataModel.sqlite" ]; then
        SAFETY_BACKUP="${COREDATA_DIR}/StockbarDataModel_pre_restore_$(date +%Y%m%d_%H%M%S).sqlite"
        cp "${COREDATA_DIR}/StockbarDataModel.sqlite" "${SAFETY_BACKUP}"
        echo "ℹ️  Current database backed up to: ${SAFETY_BACKUP}"
    fi

    # Restore database files
    cp "${BACKUP_PATH}/StockbarDataModel.sqlite" "${COREDATA_DIR}/"
    [ -f "${BACKUP_PATH}/StockbarDataModel.sqlite-wal" ] && \
        cp "${BACKUP_PATH}/StockbarDataModel.sqlite-wal" "${COREDATA_DIR}/"
    [ -f "${BACKUP_PATH}/StockbarDataModel.sqlite-shm" ] && \
        cp "${BACKUP_PATH}/StockbarDataModel.sqlite-shm" "${COREDATA_DIR}/"

    SIZE=$(du -h "${COREDATA_DIR}/StockbarDataModel.sqlite" | cut -f1)
    echo "✅ Core Data restored (${SIZE})"
else
    echo "⚠️  StockbarDataModel.sqlite not found in backup"
fi
echo ""

# 3. Restore API config
echo "[3/4] Restoring API configuration..."
CONFIG_FILE="$HOME/Documents/.stockbar_config.json"
if [ -f "${BACKUP_PATH}/.stockbar_config.json" ]; then
    cp "${BACKUP_PATH}/.stockbar_config.json" "${CONFIG_FILE}"
    echo "✅ Config file restored"
else
    echo "⚠️  .stockbar_config.json not found in backup"
fi
echo ""

# 4. Restore cache (optional)
echo "[4/4] Restoring cache file..."
CACHE_FILE="$HOME/.stockbar_cache.json"
if [ -f "${BACKUP_PATH}/.stockbar_cache.json" ]; then
    cp "${BACKUP_PATH}/.stockbar_cache.json" "${CACHE_FILE}"
    echo "✅ Cache file restored"
else
    echo "ℹ️  Cache file not in backup (will regenerate)"
fi
echo ""

echo "=================================================="
echo "Restore Complete!"
echo "=================================================="
echo ""
echo "Restored from: ${BACKUP_NAME}"
echo "Backup manifest:"
if [ -f "${BACKUP_PATH}/MANIFEST.txt" ]; then
    cat "${BACKUP_PATH}/MANIFEST.txt"
fi
echo ""
echo "You can now start Stockbar."
echo ""
