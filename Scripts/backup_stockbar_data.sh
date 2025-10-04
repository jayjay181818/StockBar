#!/bin/bash

# Stockbar Complete Data Backup Script
# Backs up all Stockbar data including UserDefaults, Core Data, and config files

set -e  # Exit on error

# Configuration
BACKUP_DIR="$HOME/Library/Application Support/Stockbar/Backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
BACKUP_NAME="stockbar_complete_backup_${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

echo "=================================================="
echo "Stockbar Complete Backup - $(date)"
echo "=================================================="
echo ""

# Create backup directory if it doesn't exist
mkdir -p "${BACKUP_PATH}"

echo "Backup location: ${BACKUP_PATH}"
echo ""

# 1. Backup UserDefaults (portfolio, preferences)
echo "[1/4] Backing up UserDefaults..."
defaults export com.fhl43211.Stockbar "${BACKUP_PATH}/UserDefaults.plist"
if [ -f "${BACKUP_PATH}/UserDefaults.plist" ]; then
    SIZE=$(du -h "${BACKUP_PATH}/UserDefaults.plist" | cut -f1)
    echo "✅ UserDefaults backed up (${SIZE})"
else
    echo "⚠️  UserDefaults backup failed"
fi
echo ""

# 2. Backup Core Data (historical data, OHLC)
echo "[2/4] Backing up Core Data database..."
COREDATA_DIR="$HOME/Library/Application Support/Stockbar"
if [ -f "${COREDATA_DIR}/StockbarDataModel.sqlite" ]; then
    # Copy main database file
    cp "${COREDATA_DIR}/StockbarDataModel.sqlite" "${BACKUP_PATH}/"

    # Copy WAL and SHM files if they exist (for SQLite write-ahead logging)
    [ -f "${COREDATA_DIR}/StockbarDataModel.sqlite-wal" ] && \
        cp "${COREDATA_DIR}/StockbarDataModel.sqlite-wal" "${BACKUP_PATH}/"
    [ -f "${COREDATA_DIR}/StockbarDataModel.sqlite-shm" ] && \
        cp "${COREDATA_DIR}/StockbarDataModel.sqlite-shm" "${BACKUP_PATH}/"

    SIZE=$(du -h "${BACKUP_PATH}/StockbarDataModel.sqlite" | cut -f1)
    echo "✅ Core Data backed up (${SIZE})"
else
    echo "⚠️  Core Data database not found"
fi
echo ""

# 3. Backup API config file
echo "[3/4] Backing up API configuration..."
CONFIG_FILE="$HOME/Documents/.stockbar_config.json"
if [ -f "${CONFIG_FILE}" ]; then
    cp "${CONFIG_FILE}" "${BACKUP_PATH}/"
    SIZE=$(du -h "${BACKUP_PATH}/.stockbar_config.json" | cut -f1)
    echo "✅ Config file backed up (${SIZE})"
else
    echo "⚠️  Config file not found (may be first run)"
fi
echo ""

# 4. Backup cache file (optional)
echo "[4/4] Backing up cache file..."
CACHE_FILE="$HOME/.stockbar_cache.json"
if [ -f "${CACHE_FILE}" ]; then
    cp "${CACHE_FILE}" "${BACKUP_PATH}/"
    SIZE=$(du -h "${BACKUP_PATH}/.stockbar_cache.json" | cut -f1)
    echo "✅ Cache file backed up (${SIZE})"
else
    echo "ℹ️  No cache file found (expected)"
fi
echo ""

# Create backup manifest
echo "[5/5] Creating backup manifest..."
cat > "${BACKUP_PATH}/MANIFEST.txt" << EOF
Stockbar Complete Backup
========================

Backup Date: $(date)
Backup Location: ${BACKUP_PATH}

Contents:
---------
1. UserDefaults.plist - Portfolio configuration and app preferences
2. StockbarDataModel.sqlite* - Historical price data and OHLC snapshots
3. .stockbar_config.json - API keys and configuration
4. .stockbar_cache.json - Price cache (optional)

Restore Instructions:
--------------------
To restore this backup:

1. Close Stockbar application
2. Run: ./restore_stockbar_data.sh ${BACKUP_NAME}
   OR manually restore each file:

   # Restore UserDefaults
   defaults import com.fhl43211.Stockbar "${BACKUP_PATH}/UserDefaults.plist"

   # Restore Core Data
   cp "${BACKUP_PATH}/StockbarDataModel.sqlite"* "$HOME/Library/Application Support/Stockbar/"

   # Restore config
   cp "${BACKUP_PATH}/.stockbar_config.json" "$HOME/Documents/"

3. Restart Stockbar

EOF

TOTAL_SIZE=$(du -sh "${BACKUP_PATH}" | cut -f1)
echo "✅ Manifest created"
echo ""

echo "=================================================="
echo "Backup Complete!"
echo "=================================================="
echo "Total backup size: ${TOTAL_SIZE}"
echo "Location: ${BACKUP_PATH}"
echo ""
echo "Files backed up:"
ls -lh "${BACKUP_PATH}"
echo ""
echo "To restore this backup later:"
echo "  ./restore_stockbar_data.sh ${BACKUP_NAME}"
echo ""

# Cleanup old backups (keep last 10)
echo "Cleaning up old backups (keeping 10 most recent)..."
cd "${BACKUP_DIR}"
ls -t | grep "stockbar_complete_backup_" | tail -n +11 | xargs -I {} rm -rf {}
REMAINING=$(ls -t | grep "stockbar_complete_backup_" | wc -l | tr -d ' ')
echo "ℹ️  ${REMAINING} complete backups retained"
echo ""
