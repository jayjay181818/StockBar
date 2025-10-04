# Stockbar Backup & Restore Scripts

Complete backup and restore scripts for all Stockbar data.

## Overview

Stockbar stores data in three locations:

1. **UserDefaults** - Portfolio configuration, preferences, menu bar settings
2. **Core Data** - Historical price data, OHLC snapshots (~89 MB)
3. **Config File** - API keys (plain-text JSON since removing Keychain)

## Quick Start

### Create a Complete Backup

```bash
cd Scripts
./backup_stockbar_data.sh
```

This creates a timestamped backup containing:
- `UserDefaults.plist` - All app preferences and portfolio config
- `StockbarDataModel.sqlite*` - Complete historical data database
- `.stockbar_config.json` - API keys
- `MANIFEST.txt` - Backup details and restore instructions

**Backup Location:** `~/Library/Application Support/Stockbar/Backups/`

### Restore from Backup

```bash
cd Scripts
./restore_stockbar_data.sh stockbar_complete_backup_2025-10-03_102800
```

**⚠️ Warning:** This will overwrite your current data!

The script will:
1. Prompt for confirmation
2. Offer to quit Stockbar if running
3. Backup current database before overwriting
4. Restore all data from the specified backup
5. Display manifest showing what was restored

## Backup Retention

- Automatic cleanup keeps the 10 most recent complete backups
- Older portfolio-only backups (created by app) are not affected
- Manual backups in custom locations are not deleted

## Data Storage Locations

### 1. UserDefaults
**Path:** `~/Library/Preferences/com.fhl43211.Stockbar.plist`

**Contains:**
- Portfolio trades (`usertrades`)
- Preferred currency
- Color coding preferences
- Menu bar display settings
- Last refresh timestamps

**Export manually:**
```bash
defaults export com.fhl43211.Stockbar ~/Desktop/stockbar_prefs.plist
```

### 2. Core Data Database
**Path:** `~/Library/Application Support/Stockbar/StockbarDataModel.sqlite`

**Contains:**
- Historical price snapshots
- Portfolio value history
- OHLC candlestick data
- Volume data

**Size:** ~89 MB (varies with history length)

**Files:**
- `StockbarDataModel.sqlite` - Main database
- `StockbarDataModel.sqlite-wal` - Write-ahead log
- `StockbarDataModel.sqlite-shm` - Shared memory

**Backup manually:**
```bash
cp -r ~/Library/Application\ Support/Stockbar/StockbarDataModel.sqlite* ~/Desktop/
```

### 3. Configuration File
**Path:** `~/Documents/.stockbar_config.json`

**Contains:**
- FMP API key (plain-text)

**Format:**
```json
{
  "FMP_API_KEY": "your_api_key_here"
}
```

**⚠️ Important:** After removing Keychain storage, this file is now plain-text. It's included in backups but contains sensitive API keys.

**Backup manually:**
```bash
cp ~/Documents/.stockbar_config.json ~/Desktop/
```

## Migration Notes

### From Keychain to File-Based Storage

If you previously used Keychain storage (before this change):

1. **API Key Migration:** The app automatically migrated your API key from Keychain to `~/.stockbar_config.json` on first launch
2. **Data Loss:** You may have noticed missing data because the Keychain was storing the API key but portfolio data is in UserDefaults/Core Data
3. **What Happened:** No data was actually lost - your portfolio is still in UserDefaults and historical data is still in Core Data

### Checking Your Data

```bash
# Check if portfolio data exists
defaults read com.fhl43211.Stockbar usertrades

# Check Core Data size
du -h ~/Library/Application\ Support/Stockbar/StockbarDataModel.sqlite

# Check API key
cat ~/Documents/.stockbar_config.json
```

## Automated Backups

To create automated daily backups, add to your crontab:

```bash
# Edit crontab
crontab -e

# Add line (runs at 2 AM daily)
0 2 * * * /Users/josh/Downloads/Stockbar\ Claude/Stockbar/Scripts/backup_stockbar_data.sh >> /tmp/stockbar_backup.log 2>&1
```

Or use launchd for macOS-native scheduling.

## Troubleshooting

### Backup Failed
- Ensure Stockbar is not running during backup (not required but recommended)
- Check disk space: `df -h ~`
- Verify permissions: `ls -la ~/Library/Application\ Support/Stockbar/`

### Restore Failed
- Make sure Stockbar is quit before restoring
- Check backup exists: `ls ~/Library/Application\ Support/Stockbar/Backups/`
- Verify backup integrity: Check MANIFEST.txt in backup folder

### Data Still Missing After Restore
1. Check UserDefaults was restored: `defaults read com.fhl43211.Stockbar`
2. Verify Core Data file exists and has data:
   ```bash
   ls -lh ~/Library/Application\ Support/Stockbar/StockbarDataModel.sqlite
   sqlite3 ~/Library/Application\ Support/Stockbar/StockbarDataModel.sqlite "SELECT COUNT(*) FROM ZPRICESNAPSHOTENTITY;"
   ```
3. Check logs: `cat ~/Documents/stockbar.log`

## Security Note

⚠️ **API Key Storage:** Since moving from Keychain to file-based storage, your API keys are now stored in plain-text at `~/Documents/.stockbar_config.json`. This file is included in backups.

**Recommendations:**
- Keep backups in secure locations
- Don't share backups publicly (they contain API keys)
- Consider encrypting backup archives if storing externally
- Set restrictive permissions: `chmod 600 ~/.stockbar_config.json`

## Support

For issues or questions:
- Check logs: `~/Documents/stockbar.log`
- Review MANIFEST.txt in backup folder
- Consult CLAUDE.md for architecture details
