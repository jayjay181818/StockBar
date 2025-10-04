#!/usr/bin/env python3
"""
get_ohlc_data.py - Fetch OHLC data from Yahoo Finance

This script fetches Open, High, Low, Close, and Volume data for stock symbols
using the yfinance library. It outputs JSON formatted data for consumption by
the Swift app.

Usage:
    python3 get_ohlc_data.py SYMBOL [PERIOD] [INTERVAL]

Arguments:
    SYMBOL: Stock symbol (e.g., AAPL, GOOGL)
    PERIOD: Time period (1d, 5d, 1mo, 3mo, 6mo, 1y, 5y, max) - default: 1mo
    INTERVAL: Data interval (1m, 5m, 15m, 30m, 1h, 1d, 1wk, 1mo) - default: 1d

Output:
    JSON object with OHLC data
"""

import sys
import json
from datetime import datetime

try:
    import yfinance as yf
except ImportError:
    print(json.dumps({
        "success": False,
        "symbol": sys.argv[1] if len(sys.argv) > 1 else "UNKNOWN",
        "period": sys.argv[2] if len(sys.argv) > 2 else "1mo",
        "interval": sys.argv[3] if len(sys.argv) > 3 else "1d",
        "data": [],
        "error": "yfinance library not installed. Run: pip3 install yfinance"
    }))
    sys.exit(1)


def fetch_ohlc_data(symbol, period="1mo", interval="1d"):
    """
    Fetch OHLC data for a symbol from Yahoo Finance

    Args:
        symbol: Stock ticker symbol
        period: Time period for data (1d, 5d, 1mo, etc.)
        interval: Data interval (1m, 5m, 15m, 1h, 1d, etc.)

    Returns:
        Dictionary with success status and OHLC data
    """
    try:
        # Create ticker object
        ticker = yf.Ticker(symbol)

        # Fetch historical data
        hist = ticker.history(period=period, interval=interval)

        if hist.empty:
            return {
                "success": False,
                "symbol": symbol,
                "period": period,
                "interval": interval,
                "data": [],
                "error": f"No data available for {symbol}"
            }

        # Convert to list of dictionaries
        ohlc_data = []
        for index, row in hist.iterrows():
            # Convert timestamp to ISO 8601 format
            timestamp = index.isoformat()

            # Extract OHLC values
            ohlc_data.append({
                "timestamp": timestamp,
                "open": float(row['Open']),
                "high": float(row['High']),
                "low": float(row['Low']),
                "close": float(row['Close']),
                "volume": int(row['Volume'])
            })

        return {
            "success": True,
            "symbol": symbol,
            "period": period,
            "interval": interval,
            "data": ohlc_data,
            "error": None
        }

    except Exception as e:
        return {
            "success": False,
            "symbol": symbol,
            "period": period,
            "interval": interval,
            "data": [],
            "error": str(e)
        }


def main():
    """Main function to handle command line arguments and fetch data"""

    # Check arguments
    if len(sys.argv) < 2:
        print(json.dumps({
            "success": False,
            "symbol": "UNKNOWN",
            "period": "1mo",
            "interval": "1d",
            "data": [],
            "error": "Usage: python3 get_ohlc_data.py SYMBOL [PERIOD] [INTERVAL]"
        }))
        sys.exit(1)

    # Parse arguments
    symbol = sys.argv[1].upper()
    period = sys.argv[2] if len(sys.argv) > 2 else "1mo"
    interval = sys.argv[3] if len(sys.argv) > 3 else "1d"

    # Validate interval based on period
    # yfinance has restrictions on valid interval/period combinations
    if period == "1d" and interval in ["1d", "1wk", "1mo"]:
        interval = "5m"  # Use 5-minute intervals for 1-day period

    # Fetch data
    result = fetch_ohlc_data(symbol, period, interval)

    # Output JSON
    print(json.dumps(result, indent=None))


if __name__ == "__main__":
    main()
