import requests
import time
from datetime import datetime, timedelta
import sys
import os
import json
import argparse

# Try to import yfinance for real-time data
try:
    import yfinance as yf
    YFINANCE_AVAILABLE = True
except ImportError:
    YFINANCE_AVAILABLE = False
    print("Warning: yfinance not available, falling back to FMP for real-time data", file=sys.stderr)

# Use a cache file in the user's home directory
CACHE_FILE = os.path.expanduser("~/.stockbar_cache.json")
CACHE_DURATION_SECONDS = 300  # 5 minutes

# Financial Modeling Prep API configuration
FMP_BASE_URL = "https://financialmodelingprep.com/api/v3"

def get_api_key():
    """Get API key from local configuration file"""
    # Try environment variable first (for backward compatibility)
    env_key = os.getenv("FMP_API_KEY")
    if env_key:
        return env_key
    
    # Try local configuration file
    try:
        home_dir = os.path.expanduser("~")
        config_file = os.path.join(home_dir, "Documents", ".stockbar_config.json")
        
        if os.path.exists(config_file):
            with open(config_file, 'r') as f:
                config = json.load(f)
                return config.get("FMP_API_KEY", "")
    except Exception as e:
        print(f"Error reading config file: {e}", file=sys.stderr)
    
    return ""

API_KEY = get_api_key()

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

def make_fmp_request(url, params=None):
    """Make a request to Financial Modeling Prep API with error handling"""
    if not API_KEY:
        raise Exception("FMP API key not found. Please set up your API key in StockBar preferences or via FMP_API_KEY environment variable.")
    
    if params is None:
        params = {}
    params['apikey'] = API_KEY
    
    try:
        response = requests.get(url, params=params, timeout=15)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"API request failed: {e}", file=sys.stderr)
        return None

def handle_lse_symbol(symbol):
    """Convert London Stock Exchange symbols for FMP API"""
    # FMP uses .L suffix for LSE stocks, ensure proper format
    if symbol.upper().endswith('.L'):
        return symbol.upper()
    elif symbol.upper().endswith('.LON'):
        # Convert .LON to .L format
        return symbol.upper().replace('.LON', '.L')
    return symbol.upper()

def fetch_real_time_quote_yfinance(symbol):
    """Fetch real-time quote using yfinance with pre-market data and fallbacks."""
    if not YFINANCE_AVAILABLE:
        return None
        
    try:
        ticker = yf.Ticker(symbol)
        
        # 1. Get daily history to find a reliable previous day's close.
        daily_hist = ticker.history(period="2d", interval="1d", auto_adjust=False)
        if daily_hist.empty:
            return None
        previous_close = float(daily_hist.iloc[-1]['Close'])

        current_price = None

        # 2. Try to get the latest price using fast_info (often most reliable)
        try:
            current_price = float(ticker.fast_info['last_price'])
        except Exception as e:
            print(f"yfinance fast_info failed for {symbol}: {e}. Falling back to intraday history.", file=sys.stderr)

        # 3. If fast_info failed, try intraday history
        if current_price is None:
            intraday_hist = ticker.history(period="2d", interval="5m", prepost=True, auto_adjust=False)
            if not intraday_hist.empty:
                current_price = float(intraday_hist.iloc[-1]['Close'])
        
        # 4. Final fallback: If all else fails, use the latest daily close (previous close).
        if current_price is None:
            print(f"All yfinance real-time methods failed for {symbol}. Using previous close as current price.", file=sys.stderr)
            current_price = previous_close

        # 5. Handle LSE stocks - yfinance returns prices in pence for .L stocks.
        # This conversion should apply to both current_price and previous_close.
        if symbol.upper().endswith('.L'):
            current_price /= 100.0
            previous_close /= 100.0
            
        print(f"yfinance data for {symbol}: current_price={current_price}, previous_close={previous_close}", file=sys.stderr)
            
        return {
            'symbol': symbol,
            'price': current_price,
            'previousClose': previous_close,
            'timestamp': int(time.time())
        }
        
    except Exception as e:
        print(f"yfinance fetch failed for {symbol}: {e}", file=sys.stderr)
        return None


def fetch_real_time_quote_fmp(symbol):
    """Fetch real-time quote from FMP API (fallback)"""
    api_symbol = handle_lse_symbol(symbol)
    url = f"{FMP_BASE_URL}/quote/{api_symbol}"
    data = make_fmp_request(url)
    
    if not data or len(data) == 0:
        return None
        
    quote = data[0]
    
    # Extract required fields
    current_price = quote.get('price', 0)
    previous_close = quote.get('previousClose', 0)
    timestamp = quote.get('timestamp', int(time.time()))
    
    if current_price <= 0 or previous_close <= 0:
        return None
    
    # Handle LSE stocks - prices are typically in pence, convert to pounds
    if api_symbol.endswith('.L'):
        # FMP returns LSE prices in pence, convert to pounds for consistency
        current_price = current_price / 100.0
        previous_close = previous_close / 100.0
        
    return {
        'symbol': symbol,  # Return original symbol format
        'price': current_price,
        'previousClose': previous_close,
        'timestamp': timestamp
    }

def fetch_real_time_quote(symbol):
    """Fetch real-time quote using yfinance first, FMP as fallback"""
    # Try yfinance first for real-time data
    if YFINANCE_AVAILABLE:
        result = fetch_real_time_quote_yfinance(symbol)
        if result:
            print(f"Using yfinance for real-time data: {symbol}", file=sys.stderr)
            return result
        else:
            print(f"yfinance failed for {symbol}, falling back to FMP", file=sys.stderr)
    
    # Fallback to FMP if yfinance fails or unavailable
    print(f"Using FMP for real-time data: {symbol}", file=sys.stderr)
    return fetch_real_time_quote_fmp(symbol)

def fetch_historical_data_yfinance(symbol, start_date, end_date):
    """Fetch historical data using yfinance"""
    if not YFINANCE_AVAILABLE:
        return None
        
    try:
        ticker = yf.Ticker(symbol)
        # Convert date strings to datetime objects for yfinance
        start_dt = datetime.strptime(start_date, '%Y-%m-%d')
        end_dt = datetime.strptime(end_date, '%Y-%m-%d')
        
        # Fetch historical data
        hist = ticker.history(start=start_dt, end=end_dt + timedelta(days=1), prepost=True, auto_adjust=False)
        
        if hist.empty:
            return None
            
        historical_data = []
        prev_close_raw = None
        
        for date, row in hist.iterrows():
            close_price_raw = float(row['Close'])
            
            # Use previous day's close as previous close, or open price for first day
            if prev_close_raw is not None:
                previous_close_raw = prev_close_raw
            else:
                previous_close_raw = float(row['Open'])
            
            # Handle LSE stocks - yfinance returns prices in pence for .L stocks
            # Convert once and only once
            if symbol.upper().endswith('.L'):
                close_price = close_price_raw / 100.0
                previous_close = previous_close_raw / 100.0
            else:
                close_price = close_price_raw
                previous_close = previous_close_raw
            
            historical_data.append({
                'timestamp': int(date.timestamp()),
                'symbol': symbol,
                'price': close_price,
                'previousClose': previous_close
            })
            
            # Store raw value for next iteration (no conversion here)
            prev_close_raw = close_price_raw
        
        print(f"yfinance retrieved {len(historical_data)} historical data points for {symbol}", file=sys.stderr)
        return historical_data
        
    except Exception as e:
        print(f"yfinance historical fetch failed for {symbol}: {e}", file=sys.stderr)
        return None

def fetch_historical_data_fmp(symbol, start_date, end_date):
    """Fetch historical daily data from FMP API for the specified date range"""
    api_symbol = handle_lse_symbol(symbol)
    url = f"{FMP_BASE_URL}/historical-price-full/{api_symbol}"
    params = {
        'from': start_date,
        'to': end_date
    }
    
    print(f"Fetching historical data for {api_symbol} from {start_date} to {end_date} using FMP", file=sys.stderr)
    data = make_fmp_request(url, params)
    
    if not data or 'historical' not in data:
        print(f"No historical data received for {api_symbol}", file=sys.stderr)
        return []
    
    historical_data = []
    for entry in data['historical']:
        try:
            # Parse the date string to timestamp
            date_obj = datetime.strptime(entry['date'], '%Y-%m-%d')
            timestamp = int(date_obj.timestamp())
            
            close_price = entry['close']
            # For historical data, previous close is the previous day's close
            # We'll use the current day's open as an approximation, or fall back to close
            previous_close = entry.get('open', close_price)
            
            # Handle LSE stocks - convert pence to pounds
            if api_symbol.endswith('.L'):
                close_price = close_price / 100.0
                previous_close = previous_close / 100.0
            
            historical_data.append({
                'timestamp': timestamp,
                'symbol': symbol,  # Return original symbol format
                'price': close_price,
                'previousClose': previous_close
            })
            
            # Debug: Print first few entries
            if len(historical_data) <= 3:
                print(f"Debug: Added entry {len(historical_data)}: {entry['date']} -> price: {close_price}, prevClose: {previous_close}", file=sys.stderr)
        except Exception as e:
            print(f"Error processing historical entry for {api_symbol}: {e}", file=sys.stderr)
            continue
    
    # Sort by timestamp (oldest first)
    historical_data.sort(key=lambda x: x['timestamp'])
    print(f"FMP retrieved {len(historical_data)} historical data points for {api_symbol}", file=sys.stderr)
    return historical_data

def fetch_historical_data(symbol, start_date, end_date):
    """Fetch historical data using yfinance first, FMP as fallback"""
    # Try yfinance first (free, no API limits)
    if YFINANCE_AVAILABLE:
        result = fetch_historical_data_yfinance(symbol, start_date, end_date)
        if result:
            print(f"Using yfinance for historical data: {symbol}", file=sys.stderr)
            return result
        else:
            print(f"yfinance historical failed for {symbol}, falling back to FMP", file=sys.stderr)
    
    # Fallback to FMP
    print(f"Using FMP for historical data: {symbol}", file=sys.stderr)
    return fetch_historical_data_fmp(symbol, start_date, end_date)

def fetch_batch(symbols):
    """Fetch multiple symbols using FMP API"""
    results = {}
    
    for symbol in symbols:
        try:
            # Check cache first
            cached = get_cached(symbol)
            if cached:
                results[symbol] = cached
                continue
                
            # Fetch from API
            quote_data = fetch_real_time_quote(symbol)
            if quote_data:
                # Convert to expected format for backward compatibility
                timestamp_str = datetime.fromtimestamp(quote_data['timestamp']).strftime('%Y-%m-%d %H:%M:%S%z')
                
                # For FMP API, we don't have high/low in real-time quotes
                # Using close price as approximation for high/low
                close_price = quote_data['price']
                prev_close = quote_data['previousClose']
                
                result = (timestamp_str, close_price, close_price, close_price, prev_close)
                set_cache(symbol, result)
                results[symbol] = result
            else:
                print(f"Failed to fetch data for {symbol}", file=sys.stderr)
                results[symbol] = None
                
            # Add delay to respect rate limits (FMP allows 250 requests/day on free tier)
            time.sleep(0.5)  # 500ms delay between requests
            
        except Exception as e:
            print(f"Error fetching {symbol}: {e}", file=sys.stderr)
            results[symbol] = None
    
    return results

def fetch_single(symbol):
    """Fallback to single fetch logic"""
    try:
        quote_data = fetch_real_time_quote(symbol)
        if quote_data:
            timestamp_str = datetime.fromtimestamp(quote_data['timestamp']).strftime('%Y-%m-%d %H:%M:%S%z')
            close_price = quote_data['price']
            prev_close = quote_data['previousClose']
            
            return (timestamp_str, close_price, close_price, close_price, prev_close)
    except Exception as e:
        print(f"Single fetch failed for {symbol}: {e}", file=sys.stderr)
    return None

def main():
    parser = argparse.ArgumentParser(description='Fetch stock data using Financial Modeling Prep API')
    parser.add_argument('--historical', action='store_true', help='Fetch historical data')
    parser.add_argument('symbols', nargs='*', help='Stock symbols to fetch')
    parser.add_argument('--start-date', help='Start date for historical data (YYYY-MM-DD)')
    parser.add_argument('--end-date', help='End date for historical data (YYYY-MM-DD)')
    
    args = parser.parse_args()
    
    if args.historical:
        # Historical data mode
        if not args.symbols or not args.start_date or not args.end_date:
            print("Error: Historical mode requires symbol, start-date, and end-date", file=sys.stderr)
            print("FETCH_FAILED")
            sys.exit(1)
        
        symbol = args.symbols[0]  # Take first symbol for historical fetch
        
        try:
            historical_data = fetch_historical_data(symbol, args.start_date, args.end_date)
            if historical_data:
                # Output as JSON array for Swift to parse
                print(json.dumps(historical_data))
            else:
                print("[]")  # Empty array if no data
        except Exception as e:
            print(f"Historical fetch failed: {e}", file=sys.stderr)
            print("FETCH_FAILED")
            sys.exit(1)
    else:
        # Real-time data mode (backward compatible)
        if len(args.symbols) < 1:
            print("Usage: python get_stock_data.py <TICKER_SYMBOL> [<TICKER_SYMBOL> ...]", file=sys.stderr)
            print("Error: No ticker symbol provided.")
            print("FETCH_FAILED")
            sys.exit(1)
        
        symbols = [s.upper() for s in args.symbols]
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