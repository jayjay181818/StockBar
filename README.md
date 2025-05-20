# StockBar

StockBar is a macOS menu bar application for tracking stock prices. It is written in Swift and uses a small Python helper script that fetches data from [yfinance](https://github.com/ranaroussi/yfinance).

## Building
1. Install Python 3 with `yfinance` available.
2. Open `Stockbar.xcodeproj` in Xcode and build the `Stockbar` target.

## How it works
- Swift code manages the menu bar UI and stores your tracked trades.
- When data is refreshed, the app executes `Resources/get_stock_data.py` to retrieve the latest price and previous close for each symbol.
- The script disables any proxy environment variables to avoid issues with network connections.

## Running
Launch the built application. Use the Preferences popover to add symbols and configure your currency preferences. The menu bar items will show current P&L values and update periodically.
