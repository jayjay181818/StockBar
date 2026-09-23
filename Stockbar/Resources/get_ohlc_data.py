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
    YFINANCE_AVAILABLE = True
except ImportError:
    yf = None
    YFINANCE_AVAILABLE = False


UK_SUFFIXES = ('.L', '.LON', '.XC')


def is_uk_symbol(symbol):
    """Match the UK suffix set used by get_stock_data.py."""
    return symbol.upper().endswith(UK_SUFFIXES)


def uses_pence_quotes(symbol, reported_currency):
    """Decide whether the provider quoted this symbol in pence (GBX).

    Mirrors normalize_currency() in get_stock_data.py: trust the provider's
    currency when it gives one, and fall back to the ticker suffix when it
    does not. LSE quotes come back as 'GBp' from yfinance.
    """
    if reported_currency is not None:
        return str(reported_currency).strip() in ("GBp", "GBX")
    return symbol.upper().endswith(('.L', '.LON'))


def fetch_ohlc_data(symbol, period="1mo", interval="1d"):
    """
    Fetch OHLC data for a symbol from Yahoo Finance

    UK symbols are quoted in pence (GBX) and are converted to pounds (GBP)
    here, so every downstream consumer receives major-currency units. This
    matches the GBX->GBP handling in get_stock_data.py.

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

        # Ask the provider what currency it quoted in; fall back to the suffix.
        reported_currency = None
        if is_uk_symbol(symbol):
            try:
                reported_currency = ticker.fast_info.get('currency')
            except Exception:
                reported_currency = None

        pence_divisor = 100.0 if uses_pence_quotes(symbol, reported_currency) else 1.0

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

            # Extract OHLC values, converting GBX -> GBP where applicable.
            # Volume is a share count and must never be scaled.
            ohlc_data.append({
                "timestamp": timestamp,
                "open": float(row['Open']) / pence_divisor,
                "high": float(row['High']) / pence_divisor,
                "low": float(row['Low']) / pence_divisor,
                "close": float(row['Close']) / pence_divisor,
                "volume": int(row['Volume'])
            })

        return {
            "success": True,
            "symbol": symbol,
            "period": period,
            "interval": interval,
            "currency": "GBP" if pence_divisor != 1.0 else None,
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

    if not YFINANCE_AVAILABLE:
        print(json.dumps({
            "success": False,
            "symbol": symbol,
            "period": period,
            "interval": interval,
            "data": [],
            "error": "yfinance library not installed. Run: pip3 install yfinance"
        }))
        sys.exit(1)

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
