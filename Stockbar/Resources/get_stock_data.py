# ~/Scripts/get_stock_data.py (Example path)
import sys
import warnings
import os
import math

# Suppress urllib3 OpenSSL warnings before importing yfinance
try:
    from urllib3.exceptions import NotOpenSSLWarning
    warnings.filterwarnings("ignore", category=NotOpenSSLWarning)
except Exception:
    pass

import yfinance as yf

# Disable proxy environment variables which can interfere with yfinance
for proxy_var in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"]:
    os.environ.pop(proxy_var, None)

def fetch_batch(symbols):
    """Fetch closing and previous closing prices for a list of symbols."""
    try:
        ticker_str = " ".join(symbols)
        data = yf.download(
            ticker_str,
            period="2d",
            group_by="ticker",
            threads=False, # Kept threads=False as it was common, often better for stability in scripts
            progress=False,
            auto_adjust=False, # Explicitly setting auto_adjust
        )

        results = {}
        for sym in symbols:
            try:
                # Handle single vs multiple symbol data structure from yf.download
                sym_data = data[sym] if len(symbols) > 1 else data
            except Exception: # Broad exception if symbol not in data (e.g. delisted during 2d period)
                sym_data = None

            if sym_data is None or sym_data.empty:
                results[sym] = None
                continue

            close_series = sym_data["Close"]
            current_price = close_series.iloc[-1]
            prev_close = (
                close_series.iloc[-2]
                if len(close_series) > 1
                else sym_data["Open"].iloc[-1] # Fallback to open if only one day's data
            )

            # Use previous close if the most recent close is NaN (common for US stocks during trading hours)
            try:
                cp_float = float(current_price)
            except Exception:
                cp_float = float('nan')

            try:
                prev_float = float(prev_close)
            except Exception:
                prev_float = float('nan')

            if math.isnan(cp_float):
                cp_float = prev_float # Fallback to previous_close if current is NaN

            # Ensure both are valid numbers, otherwise mark as None (failed fetch for this sym)
            if math.isnan(cp_float) or math.isnan(prev_float):
                results[sym] = None
            else:
                results[sym] = (cp_float, prev_float)

    except Exception as e:
        # If yf.download itself fails massively, print error and return None for all.
        # Your Swift code expects specific "FETCH_FAILED" or data.
        # This script's main loop will handle converting None to FETCH_FAILED.
        print(f"Error during yfinance download or processing: {e}", file=sys.stderr)
        return {sym: None for sym in symbols} # Mark all as None if major failure
    
    return results


if __name__ == "__main__":
    if len(sys.argv) > 1:
        symbols_arg = sys.argv[1]
        # Ensure script handles empty symbol list gracefully if Swift code doesn't prevent it.
        if not symbols_arg.strip():
            print("Error: No symbols provided.", file=sys.stderr)
            # Output format consistent with no results for Swift parser
            # Or exit, depending on desired behavior for completely empty input
        else:
            symbols = symbols_arg.split(",")
            batch_results = fetch_batch(symbols)
            for sym in symbols: # Iterate through original requested symbols to ensure all get a line
                result = batch_results.get(sym)
                if result and not (math.isnan(result[0]) or math.isnan(result[1])): # Check for NaN again before printing
                    price, prev_close = result
                    print(f"{sym},{price},{prev_close}")
                else:
                    print(f"{sym},FETCH_FAILED")
    else:
        print("Usage: python get_stock_data.py <SYMBOL[,SYMBOL...]>", file=sys.stderr)