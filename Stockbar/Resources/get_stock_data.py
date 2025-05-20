# ~/Scripts/get_stock_data.py (Example path)
import yfinance as yf
import sys
import warnings
import os
import math
try:
    from urllib3.exceptions import NotOpenSSLWarning
    warnings.filterwarnings("ignore", category=NotOpenSSLWarning)
except ImportError:
    pass

# Disable proxy environment variables which can interfere with yfinance
for proxy_var in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"]:
    os.environ.pop(proxy_var, None)

def _fetch_single(sym: str):
    """Fetch price for a single symbol as a fallback."""
    try:
        t = yf.Ticker(sym)
        hist = t.history(period="2d", auto_adjust=False)
        if hist.empty:
            info = t.fast_info
            price = info.get("last_price") or info.get("lastClose")
            prev = info.get("previousClose") or price
        else:
            price = hist["Close"].iloc[-1]
            prev = hist["Close"].iloc[-2] if len(hist["Close"]) > 1 else hist["Open"].iloc[-1]
        if price is None or (isinstance(price, float) and math.isnan(price)):
            price = prev
        return float(price), float(prev)
    except Exception as exc:
        print(f"Error fetching {sym}: {exc}", file=sys.stderr)
        return None


def fetch_batch(symbols):
    """Fetch closing and previous closing prices for a list of symbols."""
    results = {}
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
    except Exception as e:
        print(f"Error fetching batch: {e}", file=sys.stderr)
        data = None

    for sym in symbols:
        sym_data = None
        if data is not None:
            try:
                sym_data = data[sym] if len(symbols) > 1 else data
            except Exception:
                sym_data = None

        if sym_data is None or sym_data.empty:
            # Fall back to single fetch
            results[sym] = _fetch_single(sym)
            continue

        close_series = sym_data["Close"]
        current_price = close_series.iloc[-1]
        prev_close = (
            close_series.iloc[-2]
            if len(close_series) > 1
            else sym_data["Open"].iloc[-1]
        )
        if isinstance(current_price, float) and math.isnan(current_price):
            current_price = prev_close
        results[sym] = (float(current_price), float(prev_close))

    return results


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

