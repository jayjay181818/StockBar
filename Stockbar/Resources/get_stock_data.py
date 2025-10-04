import time
from datetime import datetime, timedelta
import sys
import os
import json
import argparse
import urllib.request
import urllib.parse
import urllib.error

try:
    import requests
    REQUESTS_AVAILABLE = True
except ImportError:
    requests = None
    REQUESTS_AVAILABLE = False
    print(
        "Warning: python module 'requests' not available; falling back to urllib. Install via `pip3 install requests` for optimal performance.",
        file=sys.stderr,
    )

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
    
    if REQUESTS_AVAILABLE and requests is not None:
        try:
            response = requests.get(url, params=params, timeout=15)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"API request failed via requests: {e}", file=sys.stderr)
            return None
    else:
        try:
            query = urllib.parse.urlencode(params)
            full_url = f"{url}?{query}"
            with urllib.request.urlopen(full_url, timeout=15) as resp:
                status = getattr(resp, "status", 200)
                if status >= 400:
                    print(f"API request failed via urllib with status {status}", file=sys.stderr)
                    return None
                data = resp.read()
                return json.loads(data.decode('utf-8'))
        except urllib.error.URLError as e:
            print(f"API request failed via urllib: {e}", file=sys.stderr)
            return None
        except Exception as e:
            print(f"Unexpected error during urllib request: {e}", file=sys.stderr)
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
        # Fetch more days to ensure we get complete trading day data
        daily_hist = ticker.history(period="5d", interval="1d", auto_adjust=False)
        if daily_hist.empty:
            return None
        
        # Get the most recent COMPLETE trading day's close as previous close
        # During pre-market: the last complete day is yesterday (what we want for day P&L)
        # During market hours: we still want yesterday's close for day P&L calculation
        # The key insight: we always want the most recent complete trading day's close
        
        # Sort by date to ensure we get the most recent complete day
        daily_hist = daily_hist.sort_index()
        
        # Remove today's data if it's incomplete (during market hours)
        # We want the last complete trading day's close
        today = datetime.now().date()
        
        # Filter to only include dates before today, ensuring we get complete trading days
        complete_days = daily_hist[daily_hist.index.to_series().dt.date < today]
        
        if not complete_days.empty:
            # Use the most recent complete trading day's close
            previous_close = float(complete_days.iloc[-1]['Close'])
            print(f"Using previous close from {complete_days.index[-1].strftime('%Y-%m-%d')}: {previous_close}", file=sys.stderr)
        else:
            # Fallback: use the most recent available close (this handles edge cases)
            previous_close = float(daily_hist.iloc[-1]['Close'])
            print(f"Fallback: using most recent close from {daily_hist.index[-1].strftime('%Y-%m-%d')}: {previous_close}", file=sys.stderr)

        current_price = None
        regular_market_price = None  # Keep track of actual regular market price
        regular_market_time = None  # Timestamp from exchange
        pre_market_price = None
        post_market_price = None
        market_state = "REGULAR"
        
        # 2. Get comprehensive ticker info for pre/post market data
        try:
            info = ticker.info
            print(f"yfinance info keys for {symbol}: {list(info.keys())[:10]}...", file=sys.stderr)
            
            # Extract timestamp from regularMarketTime
            if 'regularMarketTime' in info and info['regularMarketTime'] is not None:
                regular_market_time = int(info['regularMarketTime'])
                print(f"yfinance regularMarketTime for {symbol}: {regular_market_time}", file=sys.stderr)
            
            # Extract pre-market data
            if 'preMarketPrice' in info and info['preMarketPrice'] is not None:
                pre_market_price = float(info['preMarketPrice'])
                print(f"yfinance preMarketPrice for {symbol}: {pre_market_price}", file=sys.stderr)
            
            # Extract post-market data
            if 'postMarketPrice' in info and info['postMarketPrice'] is not None:
                post_market_price = float(info['postMarketPrice'])
                print(f"yfinance postMarketPrice for {symbol}: {post_market_price}", file=sys.stderr)
            
            # Get regular market price
            if 'regularMarketPrice' in info and info['regularMarketPrice'] is not None:
                regular_market_price = float(info['regularMarketPrice'])
                current_price = regular_market_price  # Start with regular market price
                print(f"yfinance regularMarketPrice for {symbol}: {regular_market_price}", file=sys.stderr)
                
        except Exception as e:
            print(f"yfinance info fetch failed for {symbol}: {e}. Falling back to other methods.", file=sys.stderr)

        # 3. Try to get the latest price using fast_info if we don't have it yet
        if regular_market_price is None:
            try:
                regular_market_price = float(ticker.fast_info['last_price'])
                current_price = regular_market_price
                print(f"yfinance fast_info for {symbol}: {regular_market_price}", file=sys.stderr)
            except Exception as e:
                print(f"yfinance fast_info failed for {symbol}: {e}. Falling back to intraday history.", file=sys.stderr)

        # 4. If still no regular market price, try intraday history with pre/post market data
        if regular_market_price is None:
            print(f"Trying intraday history with prepost=True for {symbol}", file=sys.stderr)
            intraday_hist = ticker.history(period="2d", interval="5m", prepost=True, auto_adjust=False)
            if not intraday_hist.empty:
                regular_market_price = float(intraday_hist.iloc[-1]['Close'])
                current_price = regular_market_price
                print(f"yfinance intraday latest price for {symbol}: {regular_market_price}", file=sys.stderr)
        
        # 5. Final fallback: If all else fails, use the latest daily close (previous close).
        if regular_market_price is None:
            print(f"All yfinance real-time methods failed for {symbol}. Using previous close as regular market price.", file=sys.stderr)
            regular_market_price = previous_close
            current_price = regular_market_price

        # 6. Determine market state based on appropriate timezone for the stock
        if symbol.upper().endswith('.L'):
            # LSE stocks - use London timezone
            try:
                from zoneinfo import ZoneInfo
                market_tz = ZoneInfo("Europe/London")
                print(f"Using zoneinfo for LSE timezone detection", file=sys.stderr)
            except ImportError:
                try:
                    import pytz
                    market_tz = pytz.timezone("Europe/London")
                    print(f"Using pytz for LSE timezone detection", file=sys.stderr)
                except ImportError:
                    # Final fallback - assume UTC (GMT) for LSE
                    from datetime import timezone, timedelta
                    market_tz = timezone(timedelta(hours=0))  # GMT
                    print(f"Using manual timezone offset for GMT", file=sys.stderr)
            
            # Get current time in London timezone
            now_market = datetime.now(market_tz)
            current_hour_market = now_market.hour
            current_minute_market = now_market.minute
            
            print(f"Current time London: {now_market.strftime('%H:%M:%S %Z')} (local time: {datetime.now().strftime('%H:%M:%S')})", file=sys.stderr)
            
            # LSE market hours (London time):
            # Pre-market: 7:00 AM - 8:00 AM GMT/BST
            # Regular: 8:00 AM - 4:30 PM GMT/BST  
            # Post-market: 4:30 PM - 5:30 PM GMT/BST
            # Closed: 5:30 PM - 7:00 AM GMT/BST
            
            if (current_hour_market >= 7 and current_hour_market < 8):
                if pre_market_price is not None:
                    market_state = "PRE"
                    current_price = pre_market_price
                    print(f"Market state: PRE-MARKET LSE (using pre-market price: {pre_market_price})", file=sys.stderr)
                else:
                    market_state = "PRE"
                    print(f"Market state: PRE-MARKET LSE (no pre-market price available)", file=sys.stderr)
            elif (current_hour_market == 8) or (current_hour_market >= 9 and current_hour_market < 16) or (current_hour_market == 16 and current_minute_market < 30):
                market_state = "REGULAR"
                print(f"Market state: REGULAR HOURS LSE", file=sys.stderr)
            elif (current_hour_market == 16 and current_minute_market >= 30) or (current_hour_market == 17 and current_minute_market < 30):
                if post_market_price is not None:
                    market_state = "POST"
                    current_price = post_market_price
                    print(f"Market state: POST-MARKET LSE (using post-market price: {post_market_price})", file=sys.stderr)
                else:
                    market_state = "POST"
                    print(f"Market state: POST-MARKET LSE (no post-market price available)", file=sys.stderr)
            else:
                market_state = "CLOSED"
                print(f"Market state: CLOSED LSE", file=sys.stderr)
        else:
            # US stocks - use US Eastern timezone
            try:
                from zoneinfo import ZoneInfo
                market_tz = ZoneInfo("America/New_York")
                print(f"Using zoneinfo for US timezone detection", file=sys.stderr)
            except ImportError:
                try:
                    import pytz
                    market_tz = pytz.timezone("America/New_York")
                    print(f"Using pytz for US timezone detection", file=sys.stderr)
                except ImportError:
                    # Final fallback - assume UTC-5 (EST) / UTC-4 (EDT)
                    from datetime import timezone, timedelta
                    market_tz = timezone(timedelta(hours=-4))  # EDT (summer time)
                    print(f"Using manual timezone offset for EDT", file=sys.stderr)
            
            # Get current time in US Eastern timezone
            now_market = datetime.now(market_tz)
            current_hour_market = now_market.hour
            current_minute_market = now_market.minute
            
            print(f"Current time ET: {now_market.strftime('%H:%M:%S %Z')} (local time: {datetime.now().strftime('%H:%M:%S')})", file=sys.stderr)
            
            # US market hours (Eastern time):
            # Pre-market: 4:00 AM - 9:30 AM ET
            # Regular: 9:30 AM - 4:00 PM ET  
            # Post-market: 4:00 PM - 8:00 PM ET
            # Closed: 8:00 PM - 4:00 AM ET
            
            if (current_hour_market >= 4 and current_hour_market < 9) or (current_hour_market == 9 and current_minute_market < 30):
                if pre_market_price is not None:
                    market_state = "PRE"
                    current_price = pre_market_price  # Use pre-market price as current
                    print(f"Market state: PRE-MARKET (using pre-market price: {pre_market_price})", file=sys.stderr)
                else:
                    market_state = "PRE"
                    print(f"Market state: PRE-MARKET (no pre-market price available)", file=sys.stderr)
            elif (current_hour_market == 9 and current_minute_market >= 30) or (current_hour_market >= 10 and current_hour_market < 16):
                market_state = "REGULAR"
                print(f"Market state: REGULAR HOURS", file=sys.stderr)
            elif current_hour_market >= 16 and current_hour_market < 20:
                if post_market_price is not None:
                    market_state = "POST"
                    current_price = post_market_price  # Use post-market price as current
                    print(f"Market state: POST-MARKET (using post-market price: {post_market_price})", file=sys.stderr)
                else:
                    market_state = "POST"
                    print(f"Market state: POST-MARKET (no post-market price available)", file=sys.stderr)
            else:
                market_state = "CLOSED"
                print(f"Market state: CLOSED", file=sys.stderr)

        # 7. Handle LSE stocks - yfinance returns prices in pence for .L stocks.
        # This conversion should apply to all prices.
        if symbol.upper().endswith('.L'):
            current_price /= 100.0
            previous_close /= 100.0
            if regular_market_price is not None:
                regular_market_price /= 100.0
            if pre_market_price is not None:
                pre_market_price /= 100.0
            if post_market_price is not None:
                post_market_price /= 100.0
            
        print(f"yfinance data for {symbol}: current_price={current_price}, previous_close={previous_close}, pre_market={pre_market_price}, post_market={post_market_price}, state={market_state}", file=sys.stderr)

        # Use regularMarketTime if available, otherwise fallback to current time
        timestamp = regular_market_time if regular_market_time is not None else int(time.time())

        # For pre/post market, use current time as the timestamp for those quotes
        # since yfinance doesn't provide specific pre/post market timestamps
        current_time = int(time.time())
        pre_market_time = current_time if (market_state == "PRE" and pre_market_price is not None) else None
        post_market_time = current_time if (market_state == "POST" and post_market_price is not None) else None

        return {
            'symbol': symbol,
            'price': current_price,  # Display price (includes pre/post market adjustments)
            'regularMarketPrice': regular_market_price,  # Always the regular market price for day calculations
            'previousClose': previous_close,
            'preMarketPrice': pre_market_price,
            'postMarketPrice': post_market_price,
            'preMarketTime': pre_market_time,  # Current time when pre-market data is available
            'postMarketTime': post_market_time,  # Current time when post-market data is available
            'marketState': market_state,
            'timestamp': timestamp  # Regular market time
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
        
        # Fetch historical data with intraday interval to capture pre/post market data
        # Using 1h interval to get extended hours data while keeping data manageable
        hist = ticker.history(start=start_dt, end=end_dt + timedelta(days=1), prepost=True, auto_adjust=False, interval="1h")
        
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
    """Fetch multiple symbols using enhanced real-time API with pre/post market support"""
    results = {}
    
    for symbol in symbols:
        try:
            # Check cache first
            cached = get_cached(symbol)
            if cached:
                results[symbol] = cached
                continue
                
            # Fetch from API using enhanced method
            quote_data = fetch_real_time_quote(symbol)
            if quote_data:
                # Return the enhanced quote data directly (JSON format)
                set_cache(symbol, quote_data)
                results[symbol] = quote_data
            else:
                print(f"Failed to fetch data for {symbol}", file=sys.stderr)
                results[symbol] = None
                
            # Add delay to respect rate limits and reduce yfinance rate limiting
            time.sleep(1.0)  # 1 second delay between requests to be more conservative
            
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

def output_error(error_code, message, symbol=None, retry_after=None):
    """Output a structured JSON error"""
    error_obj = {
        'error': True,
        'error_code': error_code,
        'message': message,
        'timestamp': int(time.time())
    }
    if symbol:
        error_obj['symbol'] = symbol
    if retry_after:
        error_obj['retry_after'] = retry_after

    print(json.dumps(error_obj))

def fetch_ohlc_data_yfinance(symbol, period='1mo', interval='1d'):
    """
    Fetch OHLC (Open, High, Low, Close, Volume) data using yfinance

    Args:
        symbol: Stock symbol
        period: Valid periods: 1d, 5d, 1mo, 3mo, 6mo, 1y, 2y, 5y, 10y, ytd, max
        interval: Valid intervals: 1m, 2m, 5m, 15m, 30m, 60m, 90m, 1h, 1d, 5d, 1wk, 1mo, 3mo

    Returns:
        List of OHLC data points with timestamps
    """
    if not YFINANCE_AVAILABLE:
        return None

    try:
        ticker = yf.Ticker(symbol)
        hist = ticker.history(period=period, interval=interval, auto_adjust=False)

        if hist.empty:
            return None

        ohlc_data = []
        for date, row in hist.iterrows():
            # Extract OHLCV data
            open_price = float(row['Open'])
            high_price = float(row['High'])
            low_price = float(row['Low'])
            close_price = float(row['Close'])
            volume = int(row['Volume'])

            # Handle LSE stocks - convert pence to pounds
            if symbol.upper().endswith('.L'):
                open_price /= 100.0
                high_price /= 100.0
                low_price /= 100.0
                close_price /= 100.0

            ohlc_data.append({
                'timestamp': int(date.timestamp()),
                'symbol': symbol,
                'open': open_price,
                'high': high_price,
                'low': low_price,
                'close': close_price,
                'volume': volume
            })

        print(f"yfinance retrieved {len(ohlc_data)} OHLC data points for {symbol} (period={period}, interval={interval})", file=sys.stderr)
        return ohlc_data

    except Exception as e:
        print(f"yfinance OHLC fetch failed for {symbol}: {e}", file=sys.stderr)
        return None

def fetch_ohlc_data(symbol, period='1mo', interval='1d'):
    """Fetch OHLC data using yfinance (FMP doesn't provide intraday OHLC easily)"""
    if YFINANCE_AVAILABLE:
        result = fetch_ohlc_data_yfinance(symbol, period, interval)
        if result:
            print(f"Using yfinance for OHLC data: {symbol}", file=sys.stderr)
            return result
        else:
            print(f"yfinance OHLC failed for {symbol}", file=sys.stderr)

    return None

def fetch_batch_ohlc(symbols, period='1mo', interval='1d'):
    """Fetch OHLC data for multiple symbols"""
    results = {}

    for symbol in symbols:
        try:
            ohlc_data = fetch_ohlc_data(symbol, period, interval)
            if ohlc_data:
                results[symbol] = ohlc_data
            else:
                print(f"Failed to fetch OHLC data for {symbol}", file=sys.stderr)
                results[symbol] = None

            # Add delay to respect rate limits
            time.sleep(1.0)

        except Exception as e:
            print(f"Error fetching OHLC for {symbol}: {e}", file=sys.stderr)
            results[symbol] = None

    return results

def main():
    parser = argparse.ArgumentParser(description='Fetch stock data using Financial Modeling Prep API and yfinance')
    parser.add_argument('--historical', action='store_true', help='Fetch historical price data')
    parser.add_argument('--ohlc', action='store_true', help='Fetch OHLC (candlestick) data')
    parser.add_argument('--batch-ohlc', action='store_true', help='Fetch OHLC data for multiple symbols')
    parser.add_argument('symbols', nargs='*', help='Stock symbols to fetch')
    parser.add_argument('--start-date', help='Start date for historical data (YYYY-MM-DD)')
    parser.add_argument('--end-date', help='End date for historical data (YYYY-MM-DD)')
    parser.add_argument('--period', default='1mo', help='Period for OHLC data (1d, 5d, 1mo, 3mo, 6mo, 1y, 2y, 5y, 10y, ytd, max)')
    parser.add_argument('--interval', default='1d', help='Interval for OHLC data (1m, 2m, 5m, 15m, 30m, 60m, 90m, 1h, 1d, 5d, 1wk, 1mo, 3mo)')

    args = parser.parse_args()

    if args.ohlc or args.batch_ohlc:
        # OHLC data mode
        if not args.symbols:
            print("Error: OHLC mode requires at least one symbol", file=sys.stderr)
            output_error('INVALID_REQUEST', 'OHLC mode requires at least one symbol')
            sys.exit(1)

        symbols = [s.upper() for s in args.symbols]

        try:
            if args.batch_ohlc and len(symbols) > 1:
                # Batch OHLC fetch
                ohlc_results = fetch_batch_ohlc(symbols, period=args.period, interval=args.interval)
                # Output as JSON object with symbol keys
                output_data = {}
                for symbol, data in ohlc_results.items():
                    if data:
                        output_data[symbol] = data
                print(json.dumps(output_data))
            else:
                # Single symbol OHLC fetch
                symbol = symbols[0]
                ohlc_data = fetch_ohlc_data(symbol, period=args.period, interval=args.interval)
                if ohlc_data:
                    print(json.dumps(ohlc_data))
                else:
                    output_error('NO_DATA', f'No OHLC data available for {symbol}', symbol=symbol)
        except Exception as e:
            error_str = str(e)
            if 'timeout' in error_str.lower():
                output_error('TIMEOUT', f'Request timed out')
            elif 'rate limit' in error_str.lower():
                output_error('RATE_LIMIT', 'API rate limit exceeded. Please try again later.', retry_after=60)
            else:
                output_error('UNKNOWN', f'Unexpected error: {str(e)}')
            sys.exit(1)

    elif args.historical:
        # Historical data mode
        if not args.symbols or not args.start_date or not args.end_date:
            print("Error: Historical mode requires symbol, start-date, and end-date", file=sys.stderr)
            output_error('INVALID_REQUEST', 'Historical mode requires symbol, start-date, and end-date')
            sys.exit(1)

        symbol = args.symbols[0]  # Take first symbol for historical fetch

        try:
            historical_data = fetch_historical_data(symbol, args.start_date, args.end_date)
            if historical_data:
                # Output as JSON array for Swift to parse
                print(json.dumps(historical_data))
            else:
                output_error('NO_DATA', f'No historical data available for {symbol}', symbol=symbol)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                output_error('RATE_LIMIT', 'API rate limit exceeded. Please try again later.', symbol=symbol, retry_after=60)
            elif e.code == 401 or e.code == 403:
                output_error('API_KEY_INVALID', 'API key is invalid or unauthorized.', symbol=symbol)
            else:
                output_error('NETWORK_ERROR', f'HTTP error {e.code}: {str(e)}', symbol=symbol)
            sys.exit(1)
        except (urllib.error.URLError, OSError) as e:
            output_error('NETWORK_ERROR', f'Network connection failed: {str(e)}', symbol=symbol)
            sys.exit(1)
        except Exception as e:
            error_str = str(e)
            if 'timeout' in error_str.lower():
                output_error('TIMEOUT', f'Request timed out for {symbol}', symbol=symbol)
            elif 'rate limit' in error_str.lower():
                output_error('RATE_LIMIT', 'API rate limit exceeded. Please try again later.', symbol=symbol, retry_after=60)
            elif 'invalid symbol' in error_str.lower() or 'not found' in error_str.lower():
                output_error('INVALID_SYMBOL', f'Symbol {symbol} not found or invalid', symbol=symbol)
            else:
                output_error('UNKNOWN', f'Unexpected error: {str(e)}', symbol=symbol)
            sys.exit(1)
    else:
        # Real-time data mode (backward compatible)
        if len(args.symbols) < 1:
            print("Usage: python get_stock_data.py <TICKER_SYMBOL> [<TICKER_SYMBOL> ...]", file=sys.stderr)
            output_error('INVALID_REQUEST', 'No ticker symbol provided')
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
            try:
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
            except Exception as e:
                # If batch fetch fails completely, output error
                error_str = str(e)
                if 'timeout' in error_str.lower():
                    output_error('TIMEOUT', 'Request timed out')
                    sys.exit(1)
                elif 'rate limit' in error_str.lower():
                    output_error('RATE_LIMIT', 'API rate limit exceeded. Please try again later.', retry_after=60)
                    sys.exit(1)
                elif '401' in error_str or '403' in error_str or 'api key' in error_str.lower():
                    output_error('API_KEY_INVALID', 'API key is invalid or unauthorized.')
                    sys.exit(1)
                else:
                    output_error('NETWORK_ERROR', f'Network error: {str(e)}')
                    sys.exit(1)

        # Output results as JSON for new format or legacy text format
        if len(symbols) == 1:
            # Single symbol - use legacy text format for backwards compatibility
            symbol = symbols[0]
            res = results.get(symbol)
            if res:
                if isinstance(res, dict):
                    # New JSON format from enhanced fetch
                    timestamp_str = datetime.fromtimestamp(res['timestamp']).strftime('%Y-%m-%d %H:%M:%S%z')
                    close_price = res['price']
                    prev_close = res['previousClose']
                    print(f"{symbol} @ {timestamp_str} | 5m Low: {close_price:.2f}, High: {close_price:.2f}, Close: {close_price:.2f}, PrevClose: {prev_close:.2f}")
                else:
                    # Legacy tuple format
                    timestamp_str, low_price, high_price, close_price, prev_close = res
                    print(f"{symbol} @ {timestamp_str} | 5m Low: {low_price:.2f}, High: {high_price:.2f}, Close: {close_price:.2f}, PrevClose: {prev_close:.2f}")
            else:
                output_error('NO_DATA', f'No data received for {symbol}', symbol=symbol)
        else:
            # Multiple symbols - output as JSON array
            json_results = []
            for symbol in symbols:
                res = results.get(symbol)
                if res and isinstance(res, dict):
                    json_results.append(res)
                elif res:
                    # Convert legacy tuple format to dict
                    timestamp_str, low_price, high_price, close_price, prev_close = res
                    json_results.append({
                        'symbol': symbol,
                        'price': close_price,
                        'previousClose': prev_close,
                        'timestamp': int(time.time())
                    })

            if json_results:
                print(json.dumps(json_results))
            else:
                output_error('NO_DATA', 'No data received for any symbols')

if __name__ == "__main__":
    main()
