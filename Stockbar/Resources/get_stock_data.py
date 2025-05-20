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
            threads=False,
            progress=False,
            auto_adjust=False,
        )

        results = {}
        for sym in symbols:
            try:
                sym_data = data[sym] if len(symbols) > 1 else data
            except Exception:
                sym_data = None

            if sym_data is None or sym_data.empty:
                results[sym] = None
                continue

            close_series = sym_data["Close"]
            current_price = close_series.iloc[-1]
            prev_close = (
                close_series.iloc[-2]
                if len(close_series) > 1
                else sym_data["Open"].iloc[-1]
            )

            # Fallback to prev_close if current price is NaN
            if isinstance(current_price, float) and math.isnan(current_price):
                current_price = prev_close

            results[sym] = (float(current_price), float(prev_close))

        return results
    except Exception as e:
        print(f"Error fetching batch: {e}", file=sys.stderr)
        return {sym: None for sym in symbols}


if __name__ == "__main__":
    if len(sys.argv) > 1:
        symbols = sys.argv[1].split(",")
        batch = fetch_batch(symbols)
        for sym in symbols:
            result = batch.get(sym)
            if result:
                price, prev_close = result
                print(f"{sym},{price},{prev_close}")
            else:
                print(f"{sym},FETCH_FAILED")
    else:
        print("Usage: python get_stock_data.py <SYMBOL[,SYMBOL...]>", file=sys.stderr)

