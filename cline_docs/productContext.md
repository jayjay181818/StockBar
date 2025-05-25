# Product Context

This file describes why the Stockbar project exists, what problems it solves, and how it should work.

**Why this project exists:**
StockBar exists to provide macOS users with a convenient, always-visible way to monitor their stock portfolio directly from the menu bar without needing to open separate applications or websites.

**What problems it solves:**
- **Quick Portfolio Monitoring**: Instant visibility of stock performance without context switching
- **Real-time Day Gains**: Shows daily profit/loss for each position at a glance
- **Multi-currency Support**: Handles international stocks (USD, GBP, GBX) with automatic conversion
- **Offline Resilience**: Retains last known data when network is unavailable
- **Portfolio Aggregation**: Calculates total net gains across all positions
- **Minimal Resource Usage**: Efficient caching reduces API calls and system impact

**How it should work:**
- **Menu Bar Integration**: Each tracked stock appears as a separate menu bar item showing symbol and day P&L
- **Color Coding**: Optional green/red indicators for gains/losses
- **Detailed Information**: Click any stock item to see detailed menu with price, market value, total P&L, etc.
- **Preferences Panel**: Main "StockBar" item provides access to configuration and portfolio management
- **Persistent Data**: Remembers stock prices across app restarts, showing last known values until updates succeed
- **Smart Refresh**: Updates every 15 minutes during market hours, with 5-minute retry on failures
- **Currency Intelligence**: Automatically detects and converts UK stocks from pence to pounds
- **Graceful Degradation**: Shows meaningful data even when network requests fail