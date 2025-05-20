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

def _fetch_single(sym: str):
    """Fetch price for a single symbol as a fallback."""
    try:
        t = yf.Ticker(sym)
        hist = t.history(period="2d", auto_adjust=False) # auto_adjust=False for raw data
        
        price_raw = None
        prev_raw = None

        if not hist.empty:
            price_raw = hist["Close"].iloc[-1]
            if len(hist["Close"]) > 1:
                prev_raw = hist["Close"].iloc[-2]
            elif "Open" in hist.columns and not hist["Open"].empty: # Fallback to Open if only one day's history
                prev_raw = hist["Open"].iloc[-1]
            else: # If truly only one 'Close' data point and no 'Open', use price_raw for prev_raw
                prev_raw = price_raw 
        
        # If history was empty or didn't yield price_raw, try fast_info
        if price_raw is None: 
            info = t.fast_info
            # yfinance fast_info often uses 'lastPrice' or 'regularMarketPreviousClose'
            price_raw = info.get("lastPrice") or info.get("regularMarketPreviousClose")
            # For previous close, prioritize actual, then fallback to price_raw if necessary
            prev_raw = info.get("regularMarketPreviousClose") or price_raw 
        
        # Convert to float, handling None by converting to NaN
        cp_float = float(price_raw) if price_raw is not None else float('nan')
        prev_float = float(prev_raw) if prev_raw is not None else float('nan')

        # Fallback logic for NaN values
        if math.isnan(cp_float) and not math.isnan(prev_float): # If current is NaN, use previous if valid
            cp_float = prev_float
        elif math.isnan(prev_float) and not math.isnan(cp_float): # If previous is NaN, use current if valid
            prev_float = cp_float

        # If either is still NaN after fallbacks, this symbol fetch failed
        if math.isnan(cp_float) or math.isnan(prev_float):
            return None 
            
        return cp_float, prev_float
    except Exception as exc:
        print(f"Error in _fetch_single for {sym}: {exc}", file=sys.stderr)
        return None

def fetch_batch(symbols):
    """Fetch closing and previous closing prices for a list of symbols, with fallback."""
    results = {}
    batch_data_payload = None
    batch_download_attempted = False

    if symbols: # Only attempt download if there are symbols
        try:
            ticker_str = " ".join(symbols)
            batch_data_payload = yf.download(
                ticker_str,
                period="2d",
                group_by="ticker", # Returns a Panel-like (MultiIndex DataFrame) or DataFrame
                threads=False,
                progress=False,
                auto_adjust=False, # Crucial for raw data
            )
            batch_download_attempted = True
        except Exception as e:
            print(f"Initial yf.download for batch failed: {e}", file=sys.stderr)
            # batch_download_attempted remains True, batch_data_payload might be None or error structure

    for sym in symbols:
        processed_this_symbol_from_batch = False
        if batch_download_attempted and batch_data_payload is not None and not batch_data_payload.empty:
            sym_specific_data_from_batch = None
            try:
                if len(symbols) > 1:
                    # For multiple symbols, data is a MultiIndex DataFrame. Access by [sym].
                    if sym in batch_data_payload.columns.levels[0]: # Check if symbol is in the top level columns
                        sym_specific_data_from_batch = batch_data_payload[sym]
                else: # Single symbol, batch_data_payload is the DataFrame for that symbol
                    sym_specific_data_from_batch = batch_data_payload
                
                if sym_specific_data_from_batch is not None and not sym_specific_data_from_batch.empty:
                    # Use detailed processing for sym_specific_data_from_batch
                    close_series = sym_specific_data_from_batch["Close"]
                    if close_series.empty:
                         raise ValueError("Close series is empty for batch data.")

                    current_price_raw = close_series.iloc[-1]
                    
                    if len(close_series) > 1:
                        prev_close_raw = close_series.iloc[-2]
                    elif "Open" in sym_specific_data_from_batch.columns and not sym_specific_data_from_batch["Open"].empty:
                        prev_close_raw = sym_specific_data_from_batch["Open"].iloc[-1]
                    else:
                        prev_close_raw = current_price_raw # Fallback if only one close value and no open

                    cp_float = float(current_price_raw) if current_price_raw is not None else float('nan')
                    prev_float = float(prev_close_raw) if prev_close_raw is not None else float('nan')

                    # NaN fallback logic
                    if math.isnan(cp_float) and not math.isnan(prev_float): 
                        cp_float = prev_float
                    elif math.isnan(prev_float) and not math.isnan(cp_float): 
                        prev_float = cp_float

                    if not (math.isnan(cp_float) or math.isnan(prev_float)):
                        results[sym] = (cp_float, prev_float)
                        processed_this_symbol_from_batch = True
                    # else: data from batch was NaN for this symbol, will trigger fallback
            except Exception as batch_proc_err:
                # print(f"Error processing batch data for {sym}: {batch_proc_err}, falling back.", file=sys.stderr) # Optional debug
                pass # Error processing this symbol from batch, will fall through to _fetch_single

        if not processed_this_symbol_from_batch:
            # Fallback to single fetch if not processed from batch successfully
            results[sym] = _fetch_single(sym)
            
    return results

if __name__ == "__main__":
    if len(sys.argv) > 1:
        symbols_arg = sys.argv[1]
        # Ensure script handles empty symbol list gracefully
        if not symbols_arg.strip():
            print("Error: No symbols provided.", file=sys.stderr)
        else:
            # Clean up symbols: remove empty strings that might result from "MSFT,,AAPL"
            symbols = [s.strip().upper() for s in symbols_arg.split(",") if s.strip()]
            if not symbols:
                 print("Error: No valid symbols provided after stripping.", file=sys.stderr)
            else:
                batch_results = fetch_batch(symbols)
                for sym in symbols: # Iterate through original requested symbols
                    result = batch_results.get(sym)
                    # Check for None and ensure both parts of the tuple are valid numbers before printing
                    if result and isinstance(result, tuple) and len(result) == 2 and \
                       not (math.isnan(result[0]) or math.isnan(result[1])):
                        price, prev_close = result
                        print(f"{sym},{price},{prev_close}")
                    else:
                        print(f"{sym},FETCH_FAILED")
    else:
        print("Usage: python get_stock_data.py <SYMBOL[,SYMBOL...]>", file=sys.stderr)