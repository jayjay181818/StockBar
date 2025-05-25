import yfinance as yf
import pandas as pd
import time
from datetime import datetime, timedelta
import sys
import os
import json

# Use a cache file in the user's home directory
CACHE_FILE = os.path.expanduser("~/.stockbar_cache.json")
CACHE_DURATION_SECONDS = 300  # 5 minutes

# Load cache from file
if os.path.exists(CACHE_FILE):
    with open(CACHE_FILE, 'r') as f:
        try:
            cache = json.load(f)
        except Exception:
            cache = {}
else:
    cache = {}

def save_cache():
    with open(CACHE_FILE, 'w') as f:
        json.dump(cache, f)

def get_cached(symbol):
    entry = cache.get(symbol)
    if entry:
        ts = entry.get('timestamp')
        if ts and (time.time() - ts < CACHE_DURATION_SECONDS):
            return entry.get('result')
    return None

def set_cache(symbol, result):
    cache[symbol] = {
        'timestamp': time.time(),
        'result': result
    }
    save_cache()

def format_price(val):
    if isinstance(val, pd.Series):
        val = val.iloc[0]
    return float(val)

def get_previous_close(symbol):
    """Get the previous day's close price using daily data"""
    try:
        ticker = yf.Ticker(symbol)
        # Get last 5 days of daily data to ensure we get previous close
        daily_data = ticker.history(period='5d', interval='1d')
        if daily_data is not None and len(daily_data) >= 2:
            # Get the second-to-last day's close (previous close)
            prev_close = format_price(daily_data['Close'].iloc[-2])
            return prev_close
    except Exception as e:
        print(f"Failed to get previous close for {symbol}: {e}", file=sys.stderr)
    return None

def fetch_batch(symbols):
    # Try batch download
    try:
        print(f"Batch fetching {symbols} using yf.download...", file=sys.stderr)
        data = yf.download(tickers=symbols, period='2d', interval='5m', progress=False, auto_adjust=True, timeout=10, group_by='ticker')
        results = {}
        for symbol in symbols:
            try:
                # If only one symbol, data is not multi-indexed
                symbol_data = data if len(symbols) == 1 else data[symbol]
                if symbol_data is not None and not symbol_data.empty:
                    latest_timestamp = symbol_data.index[-1]
                    latest_day_data = symbol_data[symbol_data.index.date == latest_timestamp.date()]
                    if not latest_day_data.empty:
                        last_row = latest_day_data.iloc[-1]
                        required_cols = ['Low', 'High', 'Close']
                        if all(col in last_row for col in required_cols):
                            actual_timestamp = latest_day_data.index[-1]
                            timestamp_str = actual_timestamp.strftime('%Y-%m-%d %H:%M:%S%z')
                            low_price = format_price(last_row['Low'])
                            high_price = format_price(last_row['High'])
                            close_price = format_price(last_row['Close'])
                            
                            # Get previous day's close price
                            prev_close = get_previous_close(symbol)
                            if prev_close is not None:
                                results[symbol] = (timestamp_str, low_price, high_price, close_price, prev_close)
                                continue
                            else:
                                print(f"Could not get previous close for {symbol}", file=sys.stderr)
                        else:
                            print(f"Missing columns for {symbol}: {last_row.index}", file=sys.stderr)
            except Exception as e:
                print(f"Batch fetch failed for {symbol}: {e}", file=sys.stderr)
            results[symbol] = None
        return results
    except Exception as e:
        print(f"Batch yf.download failed: {e}", file=sys.stderr)
        return {symbol: None for symbol in symbols}

def fetch_single(symbol):
    # Fallback to single fetch logic
    try:
        ticker_obj = yf.Ticker(symbol)
        hist = ticker_obj.history(period='2d', interval='5m', auto_adjust=True, timeout=10)
        if hist is not None and not hist.empty:
            latest_timestamp = hist.index[-1]
            latest_day_data = hist[hist.index.date == latest_timestamp.date()]
            if not latest_day_data.empty:
                last_row = latest_day_data.iloc[-1]
                required_cols = ['Low', 'High', 'Close']
                if all(col in last_row for col in required_cols):
                    actual_timestamp = latest_day_data.index[-1]
                    timestamp_str = actual_timestamp.strftime('%Y-%m-%d %H:%M:%S%z')
                    low_price = format_price(last_row['Low'])
                    high_price = format_price(last_row['High'])
                    close_price = format_price(last_row['Close'])
                    
                    # Get previous day's close price
                    prev_close = get_previous_close(symbol)
                    if prev_close is not None:
                        return (timestamp_str, low_price, high_price, close_price, prev_close)
                    else:
                        print(f"Could not get previous close for {symbol}", file=sys.stderr)
                else:
                    print(f"Missing columns for {symbol}: {last_row.index}", file=sys.stderr)
    except Exception as e:
        print(f"Fallback Ticker().history() for {symbol} failed: {e}", file=sys.stderr)
    return None

def main():
    if len(sys.argv) < 2:
        print("Usage: python get_stock_data.py <TICKER_SYMBOL> [<TICKER_SYMBOL> ...]", file=sys.stderr)
        print("Error: No ticker symbol provided.")
        print("FETCH_FAILED")
        sys.exit(1)
    symbols = [s.upper() for s in sys.argv[1:]]
    results = {}
    # Check cache first
    symbols_to_fetch = []
    for symbol in symbols:
        cached = get_cached(symbol)
        if cached:
            results[symbol] = cached
        else:
            symbols_to_fetch.append(symbol)
    # Batch fetch uncached
    if symbols_to_fetch:
        batch_results = fetch_batch(symbols_to_fetch)
        for symbol, res in batch_results.items():
            if res:
                set_cache(symbol, res)
                results[symbol] = res
            else:
                # Fallback to single fetch
                single_res = fetch_single(symbol)
                if single_res:
                    set_cache(symbol, single_res)
                    results[symbol] = single_res
                else:
                    results[symbol] = None
    # Output results
    for symbol in symbols:
        res = results.get(symbol)
        if res:
            timestamp_str, low_price, high_price, close_price, prev_close = res
            print(f"{symbol} @ {timestamp_str} | 5m Low: {low_price:.2f}, High: {high_price:.2f}, Close: {close_price:.2f}, PrevClose: {prev_close:.2f}")
        else:
            print(f"Error fetching {symbol}: No data received.")
            print("FETCH_FAILED")

if __name__ == "__main__":
    main()