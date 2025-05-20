# ~/Scripts/get_stock_data.py (Example path)
import yfinance as yf
import sys
import warnings
import os
try:
    from urllib3.exceptions import NotOpenSSLWarning
    warnings.filterwarnings("ignore", category=NotOpenSSLWarning)
except ImportError:
    pass

# Disable proxy environment variables which can interfere with yfinance
for proxy_var in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"]:
    os.environ.pop(proxy_var, None)

def get_data(ticker_symbol):
    """Fetches current price, previous close, currency, and timestamp for a ticker using yfinance."""
    try:
        stock = yf.Ticker(ticker_symbol)
        hist = stock.history(period="2d")
        stock_info = stock.info
        current_price = None
        prev_close = None
        currency = None
        timestamp = None

        if hist.empty or len(hist) < 1:
            if stock_info and 'symbol' in stock_info:
                current_price = stock_info.get('currentPrice', stock_info.get('regularMarketPrice'))
                prev_close = stock_info.get('previousClose')
                currency = stock_info.get('currency')
                timestamp = stock_info.get('regularMarketTime')
            else:
                return None, None, None, None
        else:
            current_price = hist['Close'].iloc[-1]
            prev_close = hist['Close'].iloc[-2] if len(hist) > 1 else hist['Open'].iloc[-1]
            currency = stock_info.get('currency')
            timestamp = stock_info.get('regularMarketTime')

        if current_price is not None and prev_close is not None and currency is not None and timestamp is not None:
            return float(current_price), float(prev_close), str(currency), int(timestamp)
        else:
            return None, None, None, None

    except Exception as e:
        print(f"Error fetching {ticker_symbol}: {e}", file=sys.stderr)
        return None, None, None, None


if __name__ == "__main__":
    if len(sys.argv) > 1:
        symbol = sys.argv[1]
        price, prev_close, currency, timestamp = get_data(symbol)
        if price is not None and prev_close is not None:
            # Output: price,prev_close (only)
            print(f"{price},{prev_close}")
        else:
            print("FETCH_FAILED")
    else:
        print("Usage: python get_stock_data.py <SYMBOL>", file=sys.stderr)
        print("FETCH_FAILED") # Indicate failure due to wrong usage
