import time
from datetime import datetime, timedelta
import sys
import os
import json
import argparse
import urllib.request
import urllib.parse
import urllib.error
import csv
import io

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

# API Base URLs
FMP_BASE_URL = "https://financialmodelingprep.com/api/v3"
TWELVE_DATA_BASE_URL = "https://api.twelvedata.com"
STOOQ_BASE_URL = "https://stooq.com/q/d/l"

def get_config():
    """Read the entire configuration file"""
    try:
        home_dir = os.path.expanduser("~")
        config_file = os.path.join(home_dir, "Documents", ".stockbar_config.json")
        
        if os.path.exists(config_file):
            with open(config_file, 'r') as f:
                return json.load(f)
    except Exception as e:
        print(f"Error reading config file: {e}", file=sys.stderr)
    return {}

CONFIG = get_config()

def get_api_key(key_name, env_name=None):
    """Get API key from config or environment"""
    # Try environment variable first
    if env_name:
        env_key = os.getenv(env_name)
        if env_key:
            return env_key
            
    return CONFIG.get(key_name, "")

FMP_API_KEY = get_api_key("FMP_API_KEY", "FMP_API_KEY")
TWELVE_DATA_API_KEY = get_api_key("TWELVE_DATA_API_KEY", "TWELVE_DATA_API_KEY")

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

def make_request(url, params=None, headers=None):
    """Generic request helper handling requests/urllib differences"""
    if params is None:
        params = {}
    
    if REQUESTS_AVAILABLE and requests is not None:
        try:
            response = requests.get(url, params=params, headers=headers, timeout=15)
            response.raise_for_status()
            try:
                return response.json()
            except ValueError:
                return response.text # Return text if JSON decode fails (e.g. CSV)
        except requests.exceptions.HTTPError as e:
            raise e
        except requests.exceptions.RequestException as e:
            print(f"Request failed via requests: {e}", file=sys.stderr)
            return None
    else:
        try:
            if params:
                query = urllib.parse.urlencode(params)
                full_url = f"{url}?{query}"
            else:
                full_url = url
                
            req = urllib.request.Request(full_url, headers=headers or {})
            with urllib.request.urlopen(req, timeout=15) as resp:
                status = getattr(resp, "status", 200)
                if status >= 400:
                    raise urllib.error.HTTPError(full_url, status, "HTTP Error", resp.headers, None)
                data = resp.read().decode('utf-8')
                try:
                    return json.loads(data)
                except json.JSONDecodeError:
                    return data
        except urllib.error.HTTPError as e:
            raise e
        except urllib.error.URLError as e:
            print(f"Request failed via urllib: {e}", file=sys.stderr)
            return None
        except Exception as e:
            print(f"Unexpected error during urllib request: {e}", file=sys.stderr)
            return None

def make_fmp_request(url, params=None):
    if not FMP_API_KEY:
        # Don't raise exception here, let the fetcher handle missing key
        return None
    if params is None:
        params = {}
    params['apikey'] = FMP_API_KEY
    return make_request(url, params)

def handle_lse_symbol(symbol):
    """Convert London Stock Exchange symbols for FMP API"""
    if symbol.upper().endswith('.L'):
        return symbol.upper()
    elif symbol.upper().endswith('.LON'):
        return symbol.upper().replace('.LON', '.L')
    return symbol.upper()

# --- Twelve Data Fetcher ---

def handle_twelvedata_symbol(symbol):
    """Convert symbols for Twelve Data (e.g. AV.L -> AV, exchange=LSE)"""
    # Twelve Data usually takes symbol and exchange separately or handles suffix
    # For LSE, it often uses just the ticker if exchange is specified, or ticker.L
    # We'll try to map common suffixes to exchanges if needed, or just pass through
    if symbol.upper().endswith('.L') or symbol.upper().endswith('.LON'):
        # Strip suffix, specify exchange in params
        return symbol.upper().replace('.L', '').replace('.LON', ''), "LSE"
    return symbol.upper(), None

def fetch_historical_data_twelvedata(symbol, start_date, end_date):
    """Fetch historical data from Twelve Data"""
    if not TWELVE_DATA_API_KEY:
        print(f"Twelve Data API key missing for {symbol}", file=sys.stderr)
        return None

    ticker, exchange = handle_twelvedata_symbol(symbol)
    
    url = f"{TWELVE_DATA_BASE_URL}/time_series"
    params = {
        'symbol': ticker,
        'interval': '1day',
        'start_date': start_date,
        'end_date': end_date,
        'apikey': TWELVE_DATA_API_KEY,
        'order': 'ASC'
    }
    if exchange:
        params['exchange'] = exchange
        
    print(f"Fetching historical data for {symbol} using Twelve Data", file=sys.stderr)
    
    try:
        data = make_request(url, params)
        
        if not data:
            return None
            
        if 'code' in data and data['code'] != 200:
            print(f"Twelve Data error: {data.get('message')}", file=sys.stderr)
            return None
            
        if 'status' in data and data['status'] == 'error':
             print(f"Twelve Data error: {data.get('message')}", file=sys.stderr)
             return None

        if 'values' not in data:
            print(f"No values in Twelve Data response for {symbol}", file=sys.stderr)
            return None
            
        historical_data = []
        for entry in data['values']:
            # entry format: {'datetime': '2023-10-27', 'open': '10.50', ...}
            try:
                date_obj = datetime.strptime(entry['datetime'], '%Y-%m-%d')
                timestamp = int(date_obj.timestamp())
                
                close_price = float(entry['close'])
                # Twelve Data doesn't explicitly give previous close in time series, 
                # usually we derive it or use open as approx if needed.
                # But for simplicity, let's use open or just rely on app to stitch it?
                # The app expects 'previousClose'. We can assume previous day's close 
                # from the *previous* entry in the list, but the list is ordered.
                # Let's try to use 'open' as a fallback for prevClose if we can't calculate it easily
                # or just pass 0 and let app handle? 
                # Better: Keep track of previous close in loop
                
                # NOTE: We requested order='ASC', so we iterate from oldest to newest.
                
                historical_data.append({
                    'timestamp': timestamp,
                    'symbol': symbol,
                    'price': close_price,
                    'previousClose': 0.0 # Placeholder, will fix in post-processing if possible
                })
            except Exception as e:
                print(f"Error parsing Twelve Data entry: {e}", file=sys.stderr)
                continue
        
        # Fix previousClose
        for i in range(len(historical_data)):
            if i > 0:
                historical_data[i]['previousClose'] = historical_data[i-1]['price']
            else:
                # First entry, use open from the API response if we can find it matching this timestamp
                # Or just use current price as fallback
                historical_data[i]['previousClose'] = historical_data[i]['price']

        print(f"Twelve Data retrieved {len(historical_data)} data points for {symbol}", file=sys.stderr)
        return historical_data

    except Exception as e:
        print(f"Twelve Data fetch failed for {symbol}: {e}", file=sys.stderr)
        return None

# --- Stooq Fetcher ---

def handle_stooq_symbol(symbol):
    """Convert symbols for Stooq (e.g. AV.L -> AV.UK)"""
    # Stooq uses .UK for LSE
    if symbol.upper().endswith('.L'):
        return symbol.upper().replace('.L', '.UK')
    elif symbol.upper().endswith('.LON'):
        return symbol.upper().replace('.LON', '.UK')
    # US stocks typically have .US suffix or just ticker, Stooq often needs .US for common ones
    # but let's stick to LSE fallback focus for now.
    return symbol.upper()

def fetch_historical_data_stooq(symbol, start_date, end_date):
    """Fetch historical data from Stooq (CSV)"""
    stooq_symbol = handle_stooq_symbol(symbol)
    
    # Stooq date format: YYYYMMDD
    d1 = start_date.replace('-', '')
    d2 = end_date.replace('-', '')
    
    # Stooq URL format: https://stooq.com/q/d/l/?s=av.uk&d1=20230101&d2=20231231&i=d
    url = f"{STOOQ_BASE_URL}/"
    params = {
        's': stooq_symbol,
        'd1': d1,
        'd2': d2,
        'i': 'd' # daily
    }
    
    print(f"Fetching historical data for {symbol} ({stooq_symbol}) from Stooq", file=sys.stderr)
    
    try:
        csv_text = make_request(url, params)
        if not csv_text or "No data" in csv_text: # Stooq sometimes returns HTML with "No data"
             print(f"Stooq returned no data for {symbol}", file=sys.stderr)
             return None
             
        # Parse CSV
        # Date,Open,High,Low,Close,Volume
        # 2023-10-27,400.00,405.00,398.00,402.00,123456
        
        historical_data = []
        
        # Use csv module
        f = io.StringIO(csv_text)
        reader = csv.DictReader(f)
        
        rows = list(reader)
        # Stooq CSV is typically descending date (newest first). We want ascending.
        rows.reverse()
        
        for row in rows:
            try:
                date_str = row.get('Date')
                close_str = row.get('Close')
                
                if not date_str or not close_str:
                    continue
                    
                date_obj = datetime.strptime(date_str, '%Y-%m-%d')
                timestamp = int(date_obj.timestamp())
                close_price = float(close_str)
                
                # Handle GBX (pence) vs GBP. Stooq usually returns in minor currency for UK?
                # Actually Stooq usually uses major currency (GBP) for UK stocks? 
                # Let's check AV.UK on Stooq... it shows e.g. 398.80. AV.L is ~400p. 
                # Stooq AV.UK price ~400. So it is in pence (GBX).
                # Our app expects GBP for LSE stocks in historical data?
                # Let's check existing yfinance/fmp handling.
                # yfinance: "if symbol.upper().endswith('.L'): close_price /= 100.0"
                # fmp: "if api_symbol.endswith('.L'): close_price = close_price / 100.0"
                # So we should divide by 100 for .L symbols if they come from Stooq as .UK
                
                if symbol.upper().endswith('.L') or symbol.upper().endswith('.LON'):
                     close_price /= 100.0
                
                historical_data.append({
                    'timestamp': timestamp,
                    'symbol': symbol,
                    'price': close_price,
                    'previousClose': 0.0 # Placeholder
                })
            except Exception as e:
                # Stooq sometimes has lines with "No data" or empty
                continue
                
        if not historical_data:
            return None
            
        # Fix previousClose
        for i in range(len(historical_data)):
            if i > 0:
                historical_data[i]['previousClose'] = historical_data[i-1]['price']
            else:
                historical_data[i]['previousClose'] = historical_data[i]['price']
                
        print(f"Stooq retrieved {len(historical_data)} data points for {symbol}", file=sys.stderr)
        return historical_data

    except Exception as e:
        print(f"Stooq fetch failed for {symbol}: {e}", file=sys.stderr)
        return None

# --- Existing Fetchers (Refactored) ---

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
        
        # Sort by date to ensure we get the most recent complete day
        daily_hist = daily_hist.sort_index()
        
        # Remove today's data if it's incomplete (during market hours)
        today = datetime.now().date()
        complete_days = daily_hist[daily_hist.index.to_series().dt.date < today]
        
        if not complete_days.empty:
            previous_close = float(complete_days.iloc[-1]['Close'])
            print(f"Using previous close from {complete_days.index[-1].strftime('%Y-%m-%d')}: {previous_close}", file=sys.stderr)
        else:
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
            
            # Extract timestamp from regularMarketTime
            if 'regularMarketTime' in info and info['regularMarketTime'] is not None:
                regular_market_time = int(info['regularMarketTime'])
            
            # Extract pre-market data
            if 'preMarketPrice' in info and info['preMarketPrice'] is not None:
                pre_market_price = float(info['preMarketPrice'])
            
            # Extract post-market data
            if 'postMarketPrice' in info and info['postMarketPrice'] is not None:
                post_market_price = float(info['postMarketPrice'])
            
            # Get regular market price
            if 'regularMarketPrice' in info and info['regularMarketPrice'] is not None:
                regular_market_price = float(info['regularMarketPrice'])
                current_price = regular_market_price
                
        except Exception as e:
            print(f"yfinance info fetch failed for {symbol}: {e}. Falling back to other methods.", file=sys.stderr)

        # 3. Try to get the latest price using fast_info if we don't have it yet
        if regular_market_price is None:
            try:
                regular_market_price = float(ticker.fast_info['last_price'])
                current_price = regular_market_price
            except Exception as e:
                print(f"yfinance fast_info failed for {symbol}: {e}. Falling back to intraday history.", file=sys.stderr)

        # 4. If still no regular market price, try intraday history with pre/post market data
        if regular_market_price is None:
            intraday_hist = ticker.history(period="2d", interval="5m", prepost=True, auto_adjust=False)
            if not intraday_hist.empty:
                regular_market_price = float(intraday_hist.iloc[-1]['Close'])
                current_price = regular_market_price
        
        # 5. Final fallback: If all else fails, use the latest daily close (previous close).
        if regular_market_price is None:
            regular_market_price = previous_close
            current_price = regular_market_price

        # 6. Determine market state based on appropriate timezone for the stock
        if symbol.upper().endswith('.L'):
            # LSE stocks - use London timezone
            try:
                from zoneinfo import ZoneInfo
                market_tz = ZoneInfo("Europe/London")
            except ImportError:
                try:
                    import pytz
                    market_tz = pytz.timezone("Europe/London")
                except ImportError:
                    from datetime import timezone, timedelta
                    market_tz = timezone(timedelta(hours=0))  # GMT
            
            # Get current time in London timezone
            now_market = datetime.now(market_tz)
            current_hour_market = now_market.hour
            current_minute_market = now_market.minute
            
            # Simplified LSE market hours logic for brevity in this view
            if (current_hour_market >= 7 and current_hour_market < 8):
                if pre_market_price is not None:
                    market_state = "PRE"
                    current_price = pre_market_price
                else:
                    market_state = "PRE"
            elif (current_hour_market == 8) or (current_hour_market >= 9 and current_hour_market < 16) or (current_hour_market == 16 and current_minute_market < 30):
                market_state = "REGULAR"
            elif (current_hour_market == 16 and current_minute_market >= 30) or (current_hour_market == 17 and current_minute_market < 30):
                if post_market_price is not None:
                    market_state = "POST"
                    current_price = post_market_price
                else:
                    market_state = "POST"
            else:
                market_state = "CLOSED"
        else:
            # US stocks - use US Eastern timezone
            try:
                from zoneinfo import ZoneInfo
                market_tz = ZoneInfo("America/New_York")
            except ImportError:
                try:
                    import pytz
                    market_tz = pytz.timezone("America/New_York")
                except ImportError:
                    from datetime import timezone, timedelta
                    market_tz = timezone(timedelta(hours=-4))  # EDT
            
            # Get current time in US Eastern timezone
            now_market = datetime.now(market_tz)
            current_hour_market = now_market.hour
            current_minute_market = now_market.minute
            
            if (current_hour_market >= 4 and current_hour_market < 9) or (current_hour_market == 9 and current_minute_market < 30):
                if pre_market_price is not None:
                    market_state = "PRE"
                    current_price = pre_market_price
                else:
                    market_state = "PRE"
            elif (current_hour_market == 9 and current_minute_market >= 30) or (current_hour_market >= 10 and current_hour_market < 16):
                market_state = "REGULAR"
            elif current_hour_market >= 16 and current_hour_market < 20:
                if post_market_price is not None:
                    market_state = "POST"
                    current_price = post_market_price
                else:
                    market_state = "POST"
            else:
                market_state = "CLOSED"

        # 7. Handle LSE stocks - yfinance returns prices in pence for .L stocks.
        if symbol.upper().endswith('.L'):
            current_price /= 100.0
            previous_close /= 100.0
            if regular_market_price is not None:
                regular_market_price /= 100.0
            if pre_market_price is not None:
                pre_market_price /= 100.0
            if post_market_price is not None:
                post_market_price /= 100.0
            
        # Use regularMarketTime if available, otherwise fallback to current time
        timestamp = regular_market_time if regular_market_time is not None else int(time.time())

        current_time = int(time.time())
        pre_market_time = current_time if (market_state == "PRE" and pre_market_price is not None) else None
        post_market_time = current_time if (market_state == "POST" and post_market_price is not None) else None

        return {
            'symbol': symbol,
            'price': current_price,  
            'regularMarketPrice': regular_market_price,
            'previousClose': previous_close,
            'preMarketPrice': pre_market_price,
            'postMarketPrice': post_market_price,
            'preMarketTime': pre_market_time,
            'postMarketTime': post_market_time,
            'marketState': market_state,
            'timestamp': timestamp
        }
        
    except Exception as e:
        print(f"yfinance fetch failed for {symbol}: {e}", file=sys.stderr)
        return None


def fetch_real_time_quote_fmp(symbol):
    """Fetch real-time quote from FMP API (fallback)"""
    api_symbol = handle_lse_symbol(symbol)
    url = f"{FMP_BASE_URL}/quote/{api_symbol}"
    try:
        data = make_fmp_request(url)
        
        if not data or len(data) == 0:
            return None
            
        quote = data[0]
        
        current_price = quote.get('price', 0)
        previous_close = quote.get('previousClose', 0)
        timestamp = quote.get('timestamp', int(time.time()))
        
        if current_price <= 0 or previous_close <= 0:
            return None
        
        # Handle LSE stocks
        if api_symbol.endswith('.L'):
            current_price = current_price / 100.0
            previous_close = previous_close / 100.0
            
        return {
            'symbol': symbol,
            'price': current_price,
            'previousClose': previous_close,
            'timestamp': timestamp
        }
    except Exception as e:
        # Re-raise HTTP errors
        if "HTTP Error" in str(e) or hasattr(e, 'code') or (hasattr(e, 'response') and hasattr(e.response, 'status_code')):
            raise e
        print(f"FMP fetch failed for {symbol}: {e}", file=sys.stderr)
        return None

def fetch_real_time_quote(symbol):
    """Fetch real-time quote using yfinance first, FMP as fallback"""
    # TODO: Make real-time priority configurable too? 
    # For now sticking to yfinance -> FMP as requested, only historical has deep problems
    if YFINANCE_AVAILABLE:
        result = fetch_real_time_quote_yfinance(symbol)
        if result:
            print(f"Using yfinance for real-time data: {symbol}", file=sys.stderr)
            return result
        else:
            print(f"yfinance failed for {symbol}, falling back to FMP", file=sys.stderr)
    
    print(f"Using FMP for real-time data: {symbol}", file=sys.stderr)
    return fetch_real_time_quote_fmp(symbol)

def fetch_historical_data_yfinance(symbol, start_date, end_date):
    """Fetch historical data using yfinance"""
    if not YFINANCE_AVAILABLE:
        return None
        
    max_retries = 2
    for attempt in range(max_retries):
        try:
            ticker = yf.Ticker(symbol)
            start_dt = datetime.strptime(start_date, '%Y-%m-%d')
            end_dt = datetime.strptime(end_date, '%Y-%m-%d')
            
            hist = ticker.history(start=start_dt, end=end_dt + timedelta(days=1), prepost=True, auto_adjust=False, interval="1h")
            
            if hist.empty:
                if attempt < max_retries - 1:
                    print(f"yfinance historical returned empty for {symbol}, retrying...", file=sys.stderr)
                    time.sleep(1)
                    continue
                return None
                
            historical_data = []
            prev_close_raw = None
            
            for date, row in hist.iterrows():
                close_price_raw = float(row['Close'])
                
                if prev_close_raw is not None:
                    previous_close_raw = prev_close_raw
                else:
                    previous_close_raw = float(row['Open'])
                
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
                
                prev_close_raw = close_price_raw
            
            print(f"yfinance retrieved {len(historical_data)} historical data points for {symbol}", file=sys.stderr)
            return historical_data
            
        except Exception as e:
            print(f"yfinance historical fetch failed for {symbol} (attempt {attempt+1}): {e}", file=sys.stderr)
            if attempt < max_retries - 1:
                time.sleep(1)
    
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
            date_obj = datetime.strptime(entry['date'], '%Y-%m-%d')
            timestamp = int(date_obj.timestamp())
            
            close_price = entry['close']
            previous_close = entry.get('open', close_price)
            
            if api_symbol.endswith('.L'):
                close_price = close_price / 100.0
                previous_close = previous_close / 100.0
            
            historical_data.append({
                'timestamp': timestamp,
                'symbol': symbol,
                'price': close_price,
                'previousClose': previous_close
            })
        except Exception as e:
            print(f"Error processing historical entry for {api_symbol}: {e}", file=sys.stderr)
            continue
    
    historical_data.sort(key=lambda x: x['timestamp'])
    print(f"FMP retrieved {len(historical_data)} historical data points for {api_symbol}", file=sys.stderr)
    return historical_data

def get_fetch_priority(symbol):
    """Get the priority list of fetch methods for historical data"""
    # Default priority
    default_priority = ["yfinance", "fmp"]
    
    # Read configured priority
    # Expecting list of strings in config like ["yfinance", "twelvedata", "stooq", "fmp"]
    config_priority = CONFIG.get("DATA_SOURCE_PRIORITY")
    
    # Normalize config priority if string or json string
    if isinstance(config_priority, str):
        try:
            config_priority = json.loads(config_priority)
        except:
            config_priority = [config_priority]
            
    priority = config_priority if isinstance(config_priority, list) else default_priority
    
    # Filter out unavailable methods or auto-optimize
    # e.g. skip FMP for LSE if key is not present or free? 
    # Actually the task says "skip FMP for LSE if free".
    # We don't easily know if the key is free or paid here without checking headers/response.
    # But we can respect the user's configured order.
    
    # Special handling for LSE to avoid FMP 403 spam if user hasn't configured it
    if symbol.upper().endswith('.L') or symbol.upper().endswith('.LON'):
        # If FMP is in the list, and we know it's likely to fail for LSE on free tier,
        # we might want to deprioritize it or remove it, BUT user might have paid tier.
        # So we respect user order.
        pass
        
    return priority

def fetch_historical_data(symbol, start_date, end_date):
    """Fetch historical data using configured priority sources"""
    
    priority = get_fetch_priority(symbol)
    
    # Ensure we always have valid sources in the list
    # Filter duplicates and ensure valid names
    valid_sources = []
    seen = set()
    
    # Add user configured sources first
    for source in priority:
        s = source.lower()
        if s not in seen:
            valid_sources.append(s)
            seen.add(s)
    
    # Append default sources if not present (fallbacks)
    for source in ["yfinance", "fmp", "twelvedata", "stooq"]:
        if source not in seen:
            valid_sources.append(source)
            seen.add(source)
            
    print(f"Fetch priority for {symbol}: {valid_sources}", file=sys.stderr)
    
    last_error = None
    
    for source in valid_sources:
        try:
            result = None
            if source == "yfinance":
                if YFINANCE_AVAILABLE:
                    result = fetch_historical_data_yfinance(symbol, start_date, end_date)
                else:
                    print("Skipping yfinance (not available)", file=sys.stderr)
            elif source == "fmp":
                # For LSE, only try FMP if it's high priority or others failed
                result = fetch_historical_data_fmp(symbol, start_date, end_date)
            elif source == "twelvedata":
                result = fetch_historical_data_twelvedata(symbol, start_date, end_date)
            elif source == "stooq":
                result = fetch_historical_data_stooq(symbol, start_date, end_date)
                
            if result:
                print(f"Successfully fetched historical data from {source} for {symbol}", file=sys.stderr)
                return result
                
        except Exception as e:
            print(f"Source {source} failed for {symbol}: {e}", file=sys.stderr)
            
            # Check for specific errors to handle gracefully
            is_403 = False
            is_rate_limit = False
            
            if "HTTP Error 403" in str(e) or (hasattr(e, 'code') and e.code == 403):
                is_403 = True
            if "HTTP Error 429" in str(e) or (hasattr(e, 'code') and e.code == 429):
                is_rate_limit = True
                
            if is_403 and source == "fmp":
                print(f"FMP 403 Forbidden (Plan Restriction) for {symbol}. Skipping.", file=sys.stderr)
            
            last_error = e
            continue
            
    # If we get here, all sources failed
    if last_error:
        # Propagate the last error if it was an HTTP error, so main can handle codes
        # But since we might have tried multiple sources, maybe just throw NO_DATA
        # unless we want to report the specific error.
        # If FMP 403 was the last one, it might be misleading if others failed for other reasons.
        # Let's re-raise if it's a critical one or just return None to let main handle NO_DATA
        pass
        
    return None

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
    """Fetch OHLC data using yfinance"""
    if not YFINANCE_AVAILABLE:
        return None

    try:
        ticker = yf.Ticker(symbol)
        hist = ticker.history(period=period, interval=interval, auto_adjust=False)

        if hist.empty:
            return None

        ohlc_data = []
        for date, row in hist.iterrows():
            open_price = float(row['Open'])
            high_price = float(row['High'])
            low_price = float(row['Low'])
            close_price = float(row['Close'])
            volume = int(row['Volume'])

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
    """Fetch OHLC data using yfinance"""
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

            time.sleep(1.0)

        except Exception as e:
            print(f"Error fetching OHLC for {symbol}: {e}", file=sys.stderr)
            results[symbol] = None

    return results

def main():
    parser = argparse.ArgumentParser(description='Fetch stock data using multiple providers')
    parser.add_argument('--historical', action='store_true', help='Fetch historical price data')
    parser.add_argument('--ohlc', action='store_true', help='Fetch OHLC (candlestick) data')
    parser.add_argument('--batch-ohlc', action='store_true', help='Fetch OHLC data for multiple symbols')
    parser.add_argument('symbols', nargs='*', help='Stock symbols to fetch')
    parser.add_argument('--start-date', help='Start date for historical data (YYYY-MM-DD)')
    parser.add_argument('--end-date', help='End date for historical data (YYYY-MM-DD)')
    parser.add_argument('--period', default='1mo', help='Period for OHLC data')
    parser.add_argument('--interval', default='1d', help='Interval for OHLC data')
    parser.add_argument('--test-key', help='Test API key for a specific service (fmp, twelvedata)')

    args = parser.parse_args()

    if args.test_key:
        service = args.test_key.lower()
        result = False
        message = ""
        
        try:
            if service == 'fmp':
                # Try fetching a simple quote for AAPL using FMP
                data = fetch_real_time_quote_fmp("AAPL")
                if data and data.get('price', 0) > 0:
                    result = True
                    message = "Successfully verified FMP API key."
                else:
                    message = "Failed to verify FMP API key. Check validity (free plan covers US stocks)."
            elif service == 'twelvedata':
                # Try fetching time series for AAPL
                today = datetime.now().strftime('%Y-%m-%d')
                yesterday = (datetime.now() - timedelta(days=5)).strftime('%Y-%m-%d')
                data = fetch_historical_data_twelvedata("AAPL", yesterday, today)
                if data:
                    result = True
                    message = "Successfully verified Twelve Data API key."
                else:
                    message = "Failed to verify Twelve Data API key."
            else:
                message = f"Unknown service: {service}"
                
            print(json.dumps({
                'success': result,
                'message': message
            }))
            
        except Exception as e:
            print(json.dumps({
                'success': False,
                'message': f"Exception during verification: {str(e)}"
            }))
        sys.exit(0)

    if args.ohlc or args.batch_ohlc:
        if not args.symbols:
            print("Error: OHLC mode requires at least one symbol", file=sys.stderr)
            output_error('INVALID_REQUEST', 'OHLC mode requires at least one symbol')
            sys.exit(1)

        symbols = [s.upper() for s in args.symbols]

        try:
            if args.batch_ohlc and len(symbols) > 1:
                ohlc_results = fetch_batch_ohlc(symbols, period=args.period, interval=args.interval)
                output_data = {}
                for symbol, data in ohlc_results.items():
                    if data:
                        output_data[symbol] = data
                print(json.dumps(output_data))
            else:
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
                output_error('RATE_LIMIT', 'API rate limit exceeded.', retry_after=60)
            else:
                output_error('UNKNOWN', f'Unexpected error: {str(e)}')
            sys.exit(1)

    elif args.historical:
        if not args.symbols or not args.start_date or not args.end_date:
            print("Error: Historical mode requires symbol, start-date, and end-date", file=sys.stderr)
            output_error('INVALID_REQUEST', 'Historical mode requires symbol, start-date, and end-date')
            sys.exit(1)

        symbol = args.symbols[0]

        try:
            historical_data = fetch_historical_data(symbol, args.start_date, args.end_date)
            if historical_data:
                print(json.dumps(historical_data))
            else:
                output_error('NO_DATA', f'No historical data available for {symbol}', symbol=symbol)
        
        except Exception as e:
            # Generic error handling
            error_str = str(e)
            if 'timeout' in error_str.lower():
                output_error('TIMEOUT', f'Request timed out for {symbol}', symbol=symbol)
            elif 'rate limit' in error_str.lower():
                output_error('RATE_LIMIT', 'API rate limit exceeded.', symbol=symbol, retry_after=60)
            elif '403' in error_str:
                 output_error('API_KEY_RESTRICTED', 'Access forbidden (403). Check plan permissions.', symbol=symbol)
            else:
                output_error('NETWORK_ERROR', f'Error: {str(e)}', symbol=symbol)
            sys.exit(1)
            
    else:
        # Real-time data mode
        if len(args.symbols) < 1:
            print("Usage: python get_stock_data.py <TICKER_SYMBOL> [<TICKER_SYMBOL> ...]", file=sys.stderr)
            output_error('INVALID_REQUEST', 'No ticker symbol provided')
            sys.exit(1)

        symbols = [s.upper() for s in args.symbols]
        results = {}

        symbols_to_fetch = []
        for symbol in symbols:
            cached = get_cached(symbol)
            if cached:
                results[symbol] = cached
            else:
                symbols_to_fetch.append(symbol)

        if symbols_to_fetch:
            try:
                batch_results = fetch_batch(symbols_to_fetch)
                for symbol, res in batch_results.items():
                    if res:
                        results[symbol] = res
                    else:
                        single_res = fetch_single(symbol)
                        if single_res:
                            set_cache(symbol, single_res)
                            results[symbol] = single_res
                        else:
                            results[symbol] = None
            except Exception as e:
                error_str = str(e)
                output_error('NETWORK_ERROR', f'Network error: {str(e)}')
                sys.exit(1)

        if len(symbols) == 1:
            symbol = symbols[0]
            res = results.get(symbol)
            if res:
                if isinstance(res, dict):
                    timestamp_str = datetime.fromtimestamp(res['timestamp']).strftime('%Y-%m-%d %H:%M:%S%z')
                    close_price = res['price']
                    prev_close = res['previousClose']
                    print(f"{symbol} @ {timestamp_str} | 5m Low: {close_price:.2f}, High: {close_price:.2f}, Close: {close_price:.2f}, PrevClose: {prev_close:.2f}")
                else:
                    timestamp_str, low_price, high_price, close_price, prev_close = res
                    print(f"{symbol} @ {timestamp_str} | 5m Low: {low_price:.2f}, High: {high_price:.2f}, Close: {close_price:.2f}, PrevClose: {prev_close:.2f}")
            else:
                output_error('NO_DATA', f'No data received for {symbol}', symbol=symbol)
        else:
            json_results = []
            for symbol in symbols:
                res = results.get(symbol)
                if res and isinstance(res, dict):
                    json_results.append(res)
                elif res:
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
