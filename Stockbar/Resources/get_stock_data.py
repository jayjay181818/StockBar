import time
from datetime import datetime, timedelta, timezone
import sys
import os
import json
import argparse
import urllib.request
import urllib.parse
import urllib.error
import csv
import io
import math
import re
import fcntl
import tempfile
import threading
from contextlib import contextmanager

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

# Keep the cache injectable so tests and acceptance runs never touch production.
# The app passes STOCKBAR_CACHE_FILE; the default matches the app's cache folder.
DEFAULT_CACHE_FILE = os.path.expanduser("~/Library/Caches/stockbar-cache/quote_cache.json")
LEGACY_CACHE_FILE = os.path.expanduser("~/.stockbar_cache.json")
CACHE_FILE = os.path.expanduser(os.getenv("STOCKBAR_CACHE_FILE") or DEFAULT_CACHE_FILE)


def migrate_legacy_cache(cache_file, default_file=DEFAULT_CACHE_FILE, legacy_file=LEGACY_CACHE_FILE):
    """Move the pre-2.4.5 home-folder cache into the Caches folder once.

    Only applies to the default location, so injected test/acceptance paths
    never read or move the user's real cache. Best effort: a failure simply
    leaves the legacy file in place and the cache starts empty.
    """
    try:
        if os.path.realpath(cache_file) != os.path.realpath(default_file):
            return False
        if os.path.exists(cache_file) or not os.path.isfile(legacy_file):
            return False
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        os.replace(legacy_file, cache_file)
        try:
            os.unlink(legacy_file + ".lock")
        except OSError:
            pass
        return True
    except OSError:
        return False


migrate_legacy_cache(CACHE_FILE)
def quote_cache_seconds(raw_value, default=300):
    """Quote cache lifetime; the app lowers it to match short refresh intervals."""
    try:
        value = int(raw_value)
    except (TypeError, ValueError):
        return default
    return min(default, max(15, value))

CACHE_DURATION_SECONDS = quote_cache_seconds(os.getenv("STOCKBAR_QUOTE_CACHE_SECONDS"))
PREV_CLOSE_CACHE_KEY = "_prev_close_cache"
PREV_CLOSE_CACHE_MAX_AGE_SECONDS = 18 * 60 * 60

# API Base URLs
FMP_BASE_URL = "https://financialmodelingprep.com/api/v3"
TWELVE_DATA_BASE_URL = "https://api.twelvedata.com"

SECRET_REDACTION_PATTERNS = [
    (re.compile(r"(?i)([?&](?:apikey|api_key|access_token|token|key)=)(?!\[REDACTED\])[^&\s\"'<>)\]]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\b((?:FMP_API_KEY|TWELVE_DATA_API_KEY|API_KEY|TOKEN|ACCESS_TOKEN)\s*[:=]\s*)(?!\[REDACTED\])[^\s,;\"')\]]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\b(Authorization\s*[:=]\s*Bearer\s+)(?!\[REDACTED\])[A-Za-z0-9._~+/\-=]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\b(Bearer\s+)(?!\[REDACTED\])[A-Za-z0-9._~+/\-=]+"), r"\1[REDACTED]"),
]

def sanitize_log_message(message):
    """Remove credential values before emitting stderr/stdout diagnostics."""
    sanitized = str(message)
    for pattern, replacement in SECRET_REDACTION_PATTERNS:
        sanitized = pattern.sub(replacement, sanitized)
    return re.sub(r"\[REDACTED\]\]+", "[REDACTED]", sanitized)

# Why a quote failed, per symbol, so the app can tell a throttled provider or a dead
# connection from a ticker that has no data. Only provider-wide causes are recorded;
# anything else is reported as NO_DATA.
FAILURE_CAUSES = {}
FAILURE_CONTEXT = threading.local()
FAILURE_PATTERNS = (
    ("RATE_LIMIT", re.compile(r"(?i)\b429\b|too many requests|rate.?limit")),
    ("TIMEOUT", re.compile(r"(?i)timed? ?out")),
    ("NETWORK_ERROR", re.compile(
        r"(?i)connection|name resolution|nodename nor servname|network is unreachable|"
        r"max retries|ssl|\b50[0234]\b|could not resolve"
    )),
)

FAILURE_MESSAGES = {
    "RATE_LIMIT": "The data provider is rate limiting requests ({symbol})",
    "TIMEOUT": "The quote request for {symbol} timed out",
    "NETWORK_ERROR": "The data provider could not be reached ({symbol})",
    "NO_DATA": "No data received for {symbol}",
}

def classify_failure(message):
    text = str(message)
    for code, pattern in FAILURE_PATTERNS:
        if pattern.search(text):
            return code
    return None

def note_failure(message):
    """Remember the first provider-wide cause logged while fetching the current symbol."""
    symbol = getattr(FAILURE_CONTEXT, "symbol", None)
    if symbol is None or symbol in FAILURE_CAUSES:
        return
    code = classify_failure(message)
    if code is not None:
        FAILURE_CAUSES[symbol] = code

def log_error(message):
    sanitized = sanitize_log_message(message)
    note_failure(sanitized)
    print(sanitized, file=sys.stderr)

def get_config():
    """Read the entire configuration file"""
    candidate_paths = []
    configured_path = os.getenv("STOCKBAR_CONFIG_FILE")
    if configured_path:
        candidate_paths.append(configured_path)

    home_dir = os.path.expanduser("~")
    candidate_paths.extend([
        os.path.join(home_dir, "Library", "Application Support", "com.stockbar", ".stockbar_config.json"),
        os.path.join(home_dir, ".stockbar_config.json"),
    ])

    for config_file in candidate_paths:
        if not config_file:
            continue
        try:
            config_file = os.path.expanduser(config_file)
            if not os.path.isfile(config_file):
                continue
            with open(config_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            log_error(f"Error reading config file: {e}")
            return {}

    return {}

CONFIG = get_config()
RAW_SYMBOL_ALIASES = CONFIG.get("SYMBOL_ALIASES", {}) if isinstance(CONFIG, dict) else {}
SYMBOL_ALIASES = {str(k).upper(): str(v).upper() for k, v in RAW_SYMBOL_ALIASES.items()}

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

cache = {}

def finite_positive_number(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) and number > 0 else None

def is_valid_quote(quote):
    if not isinstance(quote, dict):
        return False

    display_price = finite_positive_number(quote.get('price'))
    regular_price = finite_positive_number(
        quote.get('regularMarketPrice', quote.get('price'))
    )
    previous_close = finite_positive_number(quote.get('previousClose'))
    timestamp = finite_positive_number(quote.get('timestamp'))
    return all(
        value is not None
        for value in (display_price, regular_price, previous_close, timestamp)
    )

@contextmanager
def cache_lock():
    cache_directory = os.path.dirname(CACHE_FILE) or "."
    os.makedirs(cache_directory, exist_ok=True)
    lock_path = CACHE_FILE + ".lock"
    with open(lock_path, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

def load_cache_unlocked():
    if not os.path.isfile(CACHE_FILE):
        return {}
    try:
        with open(CACHE_FILE, "r") as cache_file:
            loaded = json.load(cache_file)
            return loaded if isinstance(loaded, dict) else {}
    except Exception:
        return {}

def save_cache_unlocked(value):
    cache_directory = os.path.dirname(CACHE_FILE) or "."
    file_descriptor, temporary_path = tempfile.mkstemp(
        prefix=".stockbar-cache-",
        suffix=".tmp",
        dir=cache_directory,
    )
    try:
        with os.fdopen(file_descriptor, "w") as temporary_file:
            json.dump(make_json_safe(value), temporary_file, allow_nan=False)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_path, CACHE_FILE)
        directory_descriptor = os.open(cache_directory, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except Exception:
        try:
            os.unlink(temporary_path)
        except OSError:
            pass
        raise

def get_cached(symbol):
    with cache_lock():
        current_cache = load_cache_unlocked()
        entry = current_cache.get(symbol)
    if entry:
        ts = entry.get('timestamp')
        if ts and (time.time() - ts < CACHE_DURATION_SECONDS):
            cached_result = entry.get('result')
            cached_result = apply_previous_close_backfill(symbol, cached_result)
            if is_valid_quote(cached_result):
                return cached_result
            with cache_lock():
                current_cache = load_cache_unlocked()
                current_cache.pop(symbol, None)
                save_cache_unlocked(current_cache)
    return None

def set_cache(symbol, result):
    if not is_valid_quote(result):
        return False
    with cache_lock():
        current_cache = load_cache_unlocked()
        current_cache[symbol] = {
            'timestamp': time.time(),
            'result': make_json_safe(result)
        }
        save_cache_unlocked(current_cache)
    return True

def exchange_today(index, symbol):
    """Current calendar date in the exchange's timezone.

    Bar dates in yfinance history are in the exchange timezone, so comparing
    them with the Mac's local date can treat today's partial bar as complete.
    Prefer the history index timezone; fall back to the symbol's market date.
    """
    tz = getattr(index, 'tz', None)
    if tz is not None:
        try:
            return datetime.now(tz).date()
        except Exception:
            pass
    return datetime.strptime(market_date_for_symbol(symbol), "%Y-%m-%d").date()

def market_date_for_symbol(symbol):
    tz = None
    try:
        from zoneinfo import ZoneInfo
        tz_name = "Europe/London" if is_uk_symbol(symbol) else "America/New_York"
        tz = ZoneInfo(tz_name)
    except Exception:
        try:
            import pytz
            tz_name = "Europe/London" if is_uk_symbol(symbol) else "America/New_York"
            tz = pytz.timezone(tz_name)
        except Exception:
            tz = None
    now = datetime.now(tz) if tz is not None else datetime.now(timezone.utc)
    return now.date().isoformat()

def get_cached_prev_close(symbol):
    with cache_lock():
        current_cache = load_cache_unlocked()
        prev_cache = current_cache.get(PREV_CLOSE_CACHE_KEY, {})
    entry = prev_cache.get(symbol)
    if not isinstance(entry, dict):
        return None
    if entry.get('date') != market_date_for_symbol(symbol):
        return None
    ts = entry.get('timestamp')
    if ts and (time.time() - ts > PREV_CLOSE_CACHE_MAX_AGE_SECONDS):
        return None
    value = entry.get('value')
    try:
        value = float(value)
    except Exception:
        return None
    if not math.isfinite(value) or value <= 0:
        return None
    return value

def set_cached_prev_close(symbol, value):
    with cache_lock():
        current_cache = load_cache_unlocked()
        prev_cache = current_cache.get(PREV_CLOSE_CACHE_KEY)
        if not isinstance(prev_cache, dict):
            prev_cache = {}
            current_cache[PREV_CLOSE_CACHE_KEY] = prev_cache
        prev_cache[symbol] = {
            'date': market_date_for_symbol(symbol),
            'timestamp': time.time(),
            'value': value
        }
        save_cache_unlocked(current_cache)

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
            log_error(f"Request failed via requests: {e}")
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
            log_error(f"Request failed via urllib: {e}")
            return None
        except Exception as e:
            log_error(f"Unexpected error during urllib request: {e}")
            return None

def make_fmp_request(url, params=None):
    if not FMP_API_KEY:
        # Don't raise exception here, let the fetcher handle missing key
        return None
    if params is None:
        params = {}
    params['apikey'] = FMP_API_KEY
    return make_request(url, params)

UK_SUFFIXES = ('.L', '.LON', '.XC')

def is_uk_symbol(symbol):
    return symbol.upper().endswith(UK_SUFFIXES)

def resolve_symbol_alias(symbol):
    upper = symbol.upper()
    alias = SYMBOL_ALIASES.get(upper)
    if alias:
        return alias
    if upper.endswith('.XC'):
        return upper.replace('.XC', '.L')
    return upper

def history_symbol_for_prev_close(symbol):
    """Map alt-venue UK symbols to a primary history symbol."""
    upper = resolve_symbol_alias(symbol)
    if upper.endswith('.XC'):
        return upper.replace('.XC', '.L')
    return upper

# Only a trailing London suffix is a suffix; a plain replace() would also rewrite
# ".L" inside tickers such as "ABC.LON" or "A.LSE.L".
LSE_SUFFIX_PATTERN = re.compile(r'\.(?:LON|L)$')

def handle_lse_symbol(symbol):
    """Convert London Stock Exchange symbols for FMP API (alias-resolved)."""
    upper = resolve_symbol_alias(symbol)
    return LSE_SUFFIX_PATTERN.sub('.L', upper)

def resolve_market_state(reported_state, clock_state, now_market):
    """Pick the market state: Yahoo's own marketState when present (it knows
    holidays and early closes), otherwise the clock-derived state, forced to
    CLOSED on weekends. Public holidays are not modelled here."""
    if isinstance(reported_state, str):
        normalized = reported_state.strip().upper()
        if normalized in ("REGULAR", "PRE", "POST"):
            return normalized
        if normalized in ("CLOSED", "PREPRE", "POSTPOST"):
            return "CLOSED"
    if now_market.weekday() >= 5:
        return "CLOSED"
    return clock_state

def normalize_currency(raw_currency, symbol):
    """Normalize currency codes and detect pence-based quotes."""
    if raw_currency is None:
        if is_uk_symbol(symbol):
            uses_pence = symbol.upper().endswith(('.L', '.LON'))
            return "GBP", uses_pence
        return None, False

    raw = str(raw_currency).strip()
    if raw in ("GBp", "GBX"):
        return "GBP", True

    return raw.upper(), False

# --- Twelve Data Fetcher ---

def handle_twelvedata_symbol(symbol):
    """Convert symbols for Twelve Data (e.g. AV.L -> AV, exchange=LSE)"""
    # Twelve Data usually takes symbol and exchange separately or handles suffix
    # For LSE, it often uses just the ticker if exchange is specified, or ticker.L
    # We'll try to map common suffixes to exchanges if needed, or just pass through
    upper = resolve_symbol_alias(symbol)
    if upper == '^FTSE':
        return 'FTSE', None
    if upper.endswith('.XC'):
        upper = upper[:-len('.XC')] + '.L'
    if LSE_SUFFIX_PATTERN.search(upper):
        # Strip suffix, specify exchange in params
        return LSE_SUFFIX_PATTERN.sub('', upper), "LSE"
    return upper, None

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
                log_error(f"Error parsing Twelve Data entry: {e}")
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
        log_error(f"Twelve Data fetch failed for {symbol}: {e}")
        return None


def previous_close_for_quote(completed_closes, session_started_today, showing_pre_market, fallback=None):
    """Pick the close a quote's day change is measured against.

    `completed_closes` are the closes of finished sessions, oldest first.
    """
    if not completed_closes:
        return fallback
    if not session_started_today and not showing_pre_market and len(completed_closes) > 1:
        return completed_closes[-2]
    return completed_closes[-1]

def fetch_real_time_quote_yfinance(symbol):
    """Fetch real-time quote using yfinance with pre-market data and fallbacks."""
    if not YFINANCE_AVAILABLE:
        return None
        
    try:
        resolved_symbol = resolve_symbol_alias(symbol)
        ticker = yf.Ticker(resolved_symbol)
        history_symbol = history_symbol_for_prev_close(resolved_symbol)
        history_ticker = yf.Ticker(history_symbol) if history_symbol != resolved_symbol else ticker
        
        # 1. Get daily history to find a reliable previous day's close.
        # Fetch more days to ensure we get complete trading day data
        daily_hist = history_ticker.history(period="5d", interval="1d", auto_adjust=False)
        if daily_hist.empty:
            return None
        
        # Sort by date to ensure we get the most recent complete day
        daily_hist = daily_hist.sort_index()
        
        # Remove today's data if it's incomplete (during market hours)
        today = exchange_today(daily_hist.index, symbol)
        complete_days = daily_hist[daily_hist.index.to_series().dt.date < today]
        
        completed_closes = [
            close for close in (finite_positive_number(raw) for raw in complete_days['Close'].tolist())
            if close is not None
        ]
        session_started_today = len(complete_days) < len(daily_hist)
        if completed_closes:
            previous_close = completed_closes[-1]
        else:
            previous_close = finite_positive_number(daily_hist.iloc[-1]['Close'])
            if previous_close is None:
                return None

        current_price = None
        regular_market_price = None  # Keep track of actual regular market price
        regular_market_time = None  # Timestamp from exchange
        pre_market_price = None
        post_market_price = None
        market_state = "REGULAR"
        reported_market_state = None
        
        currency = None

        # 2. Get comprehensive ticker info for pre/post market data
        try:
            info = ticker.info
            currency = info.get('currency') or info.get('financialCurrency')
            reported_market_state = info.get('marketState')
            
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
            log_error(f"yfinance info fetch failed for {symbol}: {e}. Falling back to other methods.")

        # 3. Try to get the latest price using fast_info if we don't have it yet
        if regular_market_price is None:
            try:
                regular_market_price = float(ticker.fast_info['last_price'])
                current_price = regular_market_price
                if currency is None:
                    currency = ticker.fast_info.get('currency')
            except Exception as e:
                log_error(f"yfinance fast_info failed for {symbol}: {e}. Falling back to intraday history.")

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
        if is_uk_symbol(symbol):
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
                market_state = "PRE"
            elif (current_hour_market == 8) or (current_hour_market >= 9 and current_hour_market < 16) or (current_hour_market == 16 and current_minute_market < 30):
                market_state = "REGULAR"
            elif (current_hour_market == 16 and current_minute_market >= 30) or (current_hour_market == 17 and current_minute_market < 30):
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
                market_state = "PRE"
            elif (current_hour_market == 9 and current_minute_market >= 30) or (current_hour_market >= 10 and current_hour_market < 16):
                market_state = "REGULAR"
            elif current_hour_market >= 16 and current_hour_market < 20:
                market_state = "POST"
            else:
                market_state = "CLOSED"

        market_state = resolve_market_state(reported_market_state, market_state, now_market)
        if market_state == "PRE" and pre_market_price is not None:
            current_price = pre_market_price
        elif market_state == "POST" and post_market_price is not None:
            current_price = post_market_price

        # With no bar for today (weekend, holiday, before the open) the regular price
        # is the last completed close, so the close to compare it with is the one
        # before. A pre-market price is still compared with the last completed close.
        previous_close = previous_close_for_quote(
            completed_closes,
            session_started_today,
            showing_pre_market=market_state == "PRE" and pre_market_price is not None,
            fallback=previous_close
        )

        normalized_currency, uses_pence = normalize_currency(currency, symbol)
        if uses_pence:
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
            'timestamp': timestamp,
            'currency': normalized_currency
        }
        
    except Exception as e:
        log_error(f"yfinance fetch failed for {symbol}: {e}")
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
        raw_currency = quote.get('currency')
        
        if current_price <= 0 or previous_close <= 0:
            return None
        
        normalized_currency, uses_pence = normalize_currency(raw_currency, symbol)
        if uses_pence:
            current_price = current_price / 100.0
            previous_close = previous_close / 100.0
            
        return {
            'symbol': symbol,
            'price': current_price,
            'previousClose': previous_close,
            'timestamp': timestamp,
            'currency': normalized_currency
        }
    except Exception as e:
        # Re-raise HTTP errors
        if "HTTP Error" in str(e) or hasattr(e, 'code') or (hasattr(e, 'response') and hasattr(e.response, 'status_code')):
            raise e
        log_error(f"FMP fetch failed for {symbol}: {e}")
        return None

def fetch_real_time_quote_twelvedata(symbol):
    """Fetch real-time quote from Twelve Data (fallback)."""
    if not TWELVE_DATA_API_KEY:
        return None

    base_symbol, exchange = handle_twelvedata_symbol(symbol)
    url = f"{TWELVE_DATA_BASE_URL}/quote"
    params = {
        'symbol': base_symbol,
        'apikey': TWELVE_DATA_API_KEY
    }
    if exchange:
        params['exchange'] = exchange

    try:
        data = make_request(url, params)
        if not data:
            return None

        if data.get('status') == 'error' or data.get('code') not in (None, 200):
            print(f"Twelve Data error for {symbol}: {data.get('message')}", file=sys.stderr)
            return None

        close_raw = data.get('close')
        previous_close_raw = data.get('previous_close')
        timestamp = data.get('timestamp')

        if close_raw is None or previous_close_raw is None:
            return None

        close_price = float(close_raw)
        previous_close = float(previous_close_raw)

        normalized_currency, uses_pence = normalize_currency(data.get('currency'), symbol)
        if uses_pence:
            close_price /= 100.0
            previous_close /= 100.0

        return {
            'symbol': symbol,
            'price': close_price,
            'regularMarketPrice': close_price,
            'previousClose': previous_close,
            'timestamp': int(timestamp) if timestamp is not None else int(time.time()),
            'currency': normalized_currency
        }
    except Exception as e:
        log_error(f"Twelve Data fetch failed for {symbol}: {e}")
        return None

def needs_prev_close_backfill(symbol, current_price, previous_close, currency):
    try:
        if previous_close is None or not math.isfinite(float(previous_close)) or float(previous_close) <= 0:
            return True
    except Exception:
        return True

    return False

def fetch_previous_close_twelvedata(symbol):
    if not TWELVE_DATA_API_KEY:
        return None

    history_symbol = history_symbol_for_prev_close(symbol)
    if history_symbol != symbol:
        print(f"Prev close: mapping {symbol} -> {history_symbol} for Twelve Data history", file=sys.stderr)
    ticker, exchange = handle_twelvedata_symbol(history_symbol)
    url = f"{TWELVE_DATA_BASE_URL}/time_series"
    params = {
        'symbol': ticker,
        'interval': '1day',
        'outputsize': 2,
        'order': 'ASC',
        'apikey': TWELVE_DATA_API_KEY
    }
    if exchange:
        params['exchange'] = exchange

    try:
        data = make_request(url, params)
        if not data or 'values' not in data:
            return None

        values = data.get('values') or []
        if not values:
            return None

        try:
            values = sorted(values, key=lambda v: v.get('datetime', ''))
        except Exception:
            pass

        target = values[-2] if len(values) > 1 else values[-1]
        prev_close_raw = target.get('close')
        if prev_close_raw is None:
            return None

        prev_close = float(prev_close_raw)
        currency = None
        meta = data.get('meta')
        if isinstance(meta, dict):
            currency = meta.get('currency')

        normalized_currency, uses_pence = normalize_currency(currency, symbol)
        if uses_pence:
            prev_close /= 100.0

        if not math.isfinite(prev_close) or prev_close <= 0:
            return None

        return prev_close
    except Exception as e:
        log_error(f"Twelve Data previous close fetch failed for {symbol}: {e}")
        return None

def fetch_previous_close_yfinance(symbol):
    if not YFINANCE_AVAILABLE:
        return None

    try:
        history_symbol = history_symbol_for_prev_close(symbol)
        if history_symbol != symbol:
            print(f"Prev close: mapping {symbol} -> {history_symbol} for yfinance history", file=sys.stderr)
        ticker = yf.Ticker(history_symbol)
        daily_hist = ticker.history(period="5d", interval="1d", auto_adjust=False)
        market_date = datetime.strptime(market_date_for_symbol(symbol), "%Y-%m-%d").date()
        previous_close = None

        if not daily_hist.empty:
            daily_hist = daily_hist.sort_index()
            complete_days = daily_hist[daily_hist.index.to_series().dt.date < market_date]
            for raw_close in reversed(complete_days['Close'].tolist()):
                previous_close = finite_positive_number(raw_close)
                if previous_close is not None:
                    break

        # Some index tickers intermittently expose a NaN/null daily close while
        # their intraday history remains intact. Use the last finite close from
        # the latest completed market session before giving up on the provider.
        if previous_close is None:
            hourly_hist = ticker.history(
                period="5d",
                interval="1h",
                prepost=False,
                auto_adjust=False
            )
            if not hourly_hist.empty:
                hourly_hist = hourly_hist.sort_index()
                completed_hours = hourly_hist[
                    hourly_hist.index.to_series().dt.date < market_date
                ]
                for raw_close in reversed(completed_hours['Close'].tolist()):
                    previous_close = finite_positive_number(raw_close)
                    if previous_close is not None:
                        print(
                            f"Prev close: using completed-session hourly fallback for {symbol}",
                            file=sys.stderr
                        )
                        break

        if previous_close is None:
            return None

        currency = None
        try:
            info = ticker.info
            currency = info.get('currency') or info.get('financialCurrency')
        except Exception:
            currency = None

        normalized_currency, uses_pence = normalize_currency(currency, symbol)
        if uses_pence:
            previous_close /= 100.0

        return previous_close
    except Exception as e:
        log_error(f"yfinance previous close fetch failed for {symbol}: {e}")
        return None

def fetch_previous_close_from_history(symbol):
    prev_close = fetch_previous_close_twelvedata(symbol)
    if prev_close is not None:
        return prev_close

    prev_close = fetch_previous_close_yfinance(symbol)
    return prev_close

def apply_previous_close_backfill(symbol, quote):
    if not isinstance(quote, dict):
        return quote

    current_price = quote.get('regularMarketPrice') or quote.get('price')
    previous_close = quote.get('previousClose')
    currency = quote.get('currency')

    if not needs_prev_close_backfill(symbol, current_price, previous_close, currency):
        return quote

    price_value = None
    try:
        price_value = float(current_price)
    except Exception:
        price_value = None

    epsilon = max(0.0001, (price_value or 0) * 0.0001)

    print(f"Prev close backfill needed for {symbol}. current={current_price} prev={previous_close} currency={currency}", file=sys.stderr)

    cached_prev = get_cached_prev_close(symbol)
    if cached_prev is not None:
        if symbol.upper().endswith('.XC'):
            print(f"Prev close cache bypassed for {symbol} to refetch history", file=sys.stderr)
            cached_prev = None
        elif price_value is not None and abs(cached_prev - price_value) <= epsilon and is_uk_symbol(symbol):
            print(f"Prev close cache matches current price for {symbol}; refetching history", file=sys.stderr)
            cached_prev = None
        else:
            print(f"Prev close backfill using cached value for {symbol}: {cached_prev}", file=sys.stderr)
            quote['previousClose'] = cached_prev
            return quote

    fetched_prev = fetch_previous_close_from_history(symbol)
    if fetched_prev is None:
        print(f"Prev close backfill failed for {symbol}: no history result", file=sys.stderr)
        return quote

    if symbol.upper().endswith('.XC') and price_value is not None:
        try:
            ratio = float(price_value) / float(fetched_prev)
        except Exception:
            ratio = None
        if ratio is not None:
            if ratio > 50 and ratio < 200:
                fetched_prev = float(fetched_prev) * 100.0
                print(f"Prev close scale adjust for {symbol}: matched current price scale (x100)", file=sys.stderr)
            elif ratio > 0 and ratio < 0.02:
                fetched_prev = float(fetched_prev) / 100.0
                print(f"Prev close scale adjust for {symbol}: matched current price scale (/100)", file=sys.stderr)

    try:
        prev_close_value = float(previous_close) if previous_close is not None else None
    except Exception:
        prev_close_value = None

    if prev_close_value is None or not math.isfinite(prev_close_value) or prev_close_value <= 0 or (price_value is not None and abs(fetched_prev - prev_close_value) > epsilon):
        quote['previousClose'] = fetched_prev
        print(f"Prev close backfill applied for {symbol}: {fetched_prev}", file=sys.stderr)
    else:
        print(f"Prev close backfill skipped for {symbol}: history close ~= current prev close", file=sys.stderr)

    if price_value is None or abs(fetched_prev - price_value) > epsilon or not is_uk_symbol(symbol):
        set_cached_prev_close(symbol, fetched_prev)
    return quote

def validated_provider_quote(symbol, provider, quote):
    quote = apply_previous_close_backfill(symbol, quote)
    if is_valid_quote(quote):
        print(f"Using {provider} for real-time data: {symbol}", file=sys.stderr)
        return quote
    if quote is not None:
        print(
            f"{provider} returned an incomplete quote for {symbol}; trying the next provider",
            file=sys.stderr
        )
    return None

def fetch_real_time_quote(symbol):
    """Fetch real-time quote using yfinance first, FMP as fallback"""
    # TODO: Make real-time priority configurable too? 
    # For now sticking to yfinance -> FMP as requested, only historical has deep problems
    if YFINANCE_AVAILABLE:
        result = fetch_real_time_quote_yfinance(symbol)
        result = validated_provider_quote(symbol, "yfinance", result)
        if result is not None:
            return result

    twelvedata_result = fetch_real_time_quote_twelvedata(symbol)
    twelvedata_result = validated_provider_quote(symbol, "Twelve Data", twelvedata_result)
    if twelvedata_result is not None:
        return twelvedata_result

    fmp_result = fetch_real_time_quote_fmp(symbol)
    return validated_provider_quote(symbol, "FMP", fmp_result)

def yfinance_reported_currency(ticker):
    """Currency reported by yfinance for a ticker (history metadata, then fast_info, then info)."""
    for getter in (
        lambda: ticker.history_metadata.get('currency'),
        lambda: ticker.fast_info['currency'],
        lambda: ticker.info.get('currency'),
    ):
        try:
            value = getter()
            if value:
                return value
        except Exception:
            continue
    return None

HOURLY_HISTORY_MAX_DAYS = 700

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
            
            # Yahoo serves hourly bars for roughly the last two years only; an older
            # start date makes the whole request fail, so those ranges use daily bars.
            hourly_available = (datetime.now() - start_dt).days <= HOURLY_HISTORY_MAX_DAYS
            hist = ticker.history(
                start=start_dt,
                end=end_dt + timedelta(days=1),
                prepost=hourly_available,
                auto_adjust=False,
                interval="1h" if hourly_available else "1d"
            )
            
            if hist.empty:
                if attempt < max_retries - 1:
                    print(f"yfinance historical returned empty for {symbol}, retrying...", file=sys.stderr)
                    time.sleep(1)
                    continue
                return None
                
            historical_data = []
            prev_close_raw = None
            _, uses_pence = normalize_currency(yfinance_reported_currency(ticker), symbol)
            
            for date, row in hist.iterrows():
                close_price_raw = finite_positive_number(row['Close'])
                if close_price_raw is None:
                    continue

                if prev_close_raw is not None:
                    previous_close_raw = prev_close_raw
                else:
                    previous_close_raw = finite_positive_number(row['Open']) or close_price_raw

                if uses_pence:
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
            log_error(f"yfinance historical fetch failed for {symbol} (attempt {attempt+1}): {e}")
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
    reported_currency = data.get('currency')
    for entry in data['historical']:
        try:
            date_obj = datetime.strptime(entry['date'], '%Y-%m-%d')
            timestamp = int(date_obj.timestamp())
            
            close_price = entry['close']
            previous_close = entry.get('open', close_price)
            
            _, uses_pence = normalize_currency(entry.get('currency') or reported_currency, api_symbol)
            if uses_pence:
                close_price = close_price / 100.0
                previous_close = previous_close / 100.0
            
            historical_data.append({
                'timestamp': timestamp,
                'symbol': symbol,
                'price': close_price,
                'previousClose': previous_close
            })
        except Exception as e:
            log_error(f"Error processing historical entry for {api_symbol}: {e}")
            continue
    
    historical_data.sort(key=lambda x: x['timestamp'])
    print(f"FMP retrieved {len(historical_data)} historical data points for {api_symbol}", file=sys.stderr)
    return historical_data

def get_fetch_priority(symbol):
    """Return the configured provider order for historical data.

    DATA_SOURCE_PRIORITY may be a list or a JSON-encoded list; a plain string is
    treated as a single provider. The user's order is respected for all symbols
    (including LSE listings, where a paid FMP plan may be available).
    """
    default_priority = ["yfinance", "fmp"]
    config_priority = CONFIG.get("DATA_SOURCE_PRIORITY")

    if isinstance(config_priority, str):
        try:
            config_priority = json.loads(config_priority)
        except (TypeError, ValueError):
            config_priority = [config_priority]

    return config_priority if isinstance(config_priority, list) else default_priority

def fetch_historical_data(symbol, start_date, end_date):
    """Fetch historical data using configured priority sources"""
    fetch_symbol = resolve_symbol_alias(symbol)
    if fetch_symbol != symbol:
        print(f"Historical alias: {symbol} -> {fetch_symbol}", file=sys.stderr)

    priority = get_fetch_priority(fetch_symbol)
    
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
    for source in ["yfinance", "fmp", "twelvedata"]:
        if source not in seen:
            valid_sources.append(source)
            seen.add(source)
            
    if fetch_symbol == symbol:
        print(f"Fetch priority for {symbol}: {valid_sources}", file=sys.stderr)
    else:
        print(f"Fetch priority for {fetch_symbol} (requested {symbol}): {valid_sources}", file=sys.stderr)
    
    last_error = None
    
    for source in valid_sources:
        try:
            result = None
            if source == "yfinance":
                if YFINANCE_AVAILABLE:
                    result = fetch_historical_data_yfinance(fetch_symbol, start_date, end_date)
                else:
                    print("Skipping yfinance (not available)", file=sys.stderr)
            elif source == "fmp":
                # For LSE, only try FMP if it's high priority or others failed
                result = fetch_historical_data_fmp(fetch_symbol, start_date, end_date)
            elif source == "twelvedata":
                result = fetch_historical_data_twelvedata(fetch_symbol, start_date, end_date)
            else:
                # Unknown or retired provider names (for example "stooq") are skipped.
                continue


            if result:
                if fetch_symbol != symbol:
                    for entry in result:
                        entry['symbol'] = symbol
                print(f"Successfully fetched historical data from {source} for {symbol}", file=sys.stderr)
                return result
                
        except Exception as e:
            log_error(f"Source {source} failed for {symbol}: {e}")
            
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

SYMBOL_DEADLINE_SECONDS = 20.0
REQUEST_SPACING_SECONDS = 1.0

def fetch_quote_with_deadline(symbol, deadline_seconds):
    """Fetch one quote on a worker thread and give up waiting after `deadline_seconds`.

    A provider call that hangs must cost only its own symbol, not the whole batch.
    The abandoned thread is a daemon: it ends with its own request timeout, and its
    late result is discarded.
    """
    outcome = {}

    def work():
        FAILURE_CONTEXT.symbol = symbol
        try:
            outcome['quote'] = fetch_real_time_quote(symbol)
        except Exception as e:
            log_error(f"Error fetching {symbol}: {e}")
        finally:
            FAILURE_CONTEXT.symbol = None

    thread = threading.Thread(target=work, name=f"quote-{symbol}", daemon=True)
    thread.start()
    thread.join(max(0.0, deadline_seconds))
    if thread.is_alive():
        FAILURE_CAUSES[symbol] = "TIMEOUT"
        print(f"Quote for {symbol} exceeded {deadline_seconds:.0f}s; skipping it", file=sys.stderr)
        return None
    return outcome.get('quote')

def fetch_batch(symbols, time_budget_seconds=None):
    """Fetch quotes one symbol at a time, each with its own deadline.

    `time_budget_seconds` bounds the whole batch: symbols that cannot start within
    it are reported as timed out, so the caller still receives every other result.
    """
    results = {}
    batch_deadline = (time.monotonic() + time_budget_seconds) if time_budget_seconds else None
    fetched_any = False

    for symbol in symbols:
        cached = get_cached(symbol)
        if cached:
            results[symbol] = cached
            continue

        remaining = None if batch_deadline is None else batch_deadline - time.monotonic()
        if remaining is not None and remaining <= 1.0:
            FAILURE_CAUSES[symbol] = "TIMEOUT"
            results[symbol] = None
            continue

        # Space out provider requests, but never wait after the last one.
        if fetched_any:
            time.sleep(REQUEST_SPACING_SECONDS)
        fetched_any = True

        deadline = SYMBOL_DEADLINE_SECONDS if remaining is None else min(SYMBOL_DEADLINE_SECONDS, remaining)
        quote_data = fetch_quote_with_deadline(symbol, deadline)
        if is_valid_quote(quote_data):
            set_cache(symbol, quote_data)
            results[symbol] = quote_data
        else:
            print(f"Failed to fetch data for {symbol}", file=sys.stderr)
            results[symbol] = None

    return results

def make_json_safe(value):
    """Recursively replace non-finite floats so emitted JSON is standards compliant."""
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {key: make_json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [make_json_safe(item) for item in value]
    return value

def print_json(value):
    print(json.dumps(make_json_safe(value), allow_nan=False))

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
        log_error(f"Single fetch failed for {symbol}: {e}")
    return None

def output_error(error_code, message, symbol=None, retry_after=None):
    """Output a structured JSON error"""
    error_obj = {
        'error': True,
        'error_code': error_code,
        'message': sanitize_log_message(message),
        'timestamp': int(time.time())
    }
    if symbol:
        error_obj['symbol'] = symbol
    if retry_after:
        error_obj['retry_after'] = retry_after

    print_json(error_obj)

def finite_ohlc_value(value):
    """A price as a finite float, or None when missing or non-finite."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None

def ohlc_volume(value):
    """Share count as an int; a missing or non-finite volume becomes 0."""
    number = finite_ohlc_value(value)
    return int(number) if number is not None else 0

def fetch_ohlc_data_yfinance(symbol, period='1mo', interval='1d'):
    """Fetch OHLC data using yfinance"""
    if not YFINANCE_AVAILABLE:
        return None

    try:
        ticker = yf.Ticker(symbol)
        hist = ticker.history(period=period, interval=interval, auto_adjust=False)

        if hist.empty:
            return None

        # Scale by the currency yfinance reports, as the history path does, so
        # a .L listing quoted in GBP or USD is not divided by 100.
        _, uses_pence = normalize_currency(yfinance_reported_currency(ticker), symbol)
        divisor = 100.0 if uses_pence else 1.0

        ohlc_data = []
        for date, row in hist.iterrows():
            prices = [finite_ohlc_value(row[column]) for column in ('Open', 'High', 'Low', 'Close')]
            # A row with a missing price (often today's partial bar) would become
            # null in the JSON and fail decoding of the whole response, so skip it.
            if any(price is None for price in prices):
                continue
            open_price, high_price, low_price, close_price = (price / divisor for price in prices)

            ohlc_data.append({
                'timestamp': int(date.timestamp()),
                'symbol': symbol,
                'open': open_price,
                'high': high_price,
                'low': low_price,
                'close': close_price,
                # Indices and FX often have no volume; that must not fail the fetch.
                'volume': ohlc_volume(row['Volume'])
            })

        if not ohlc_data:
            return None

        print(f"yfinance retrieved {len(ohlc_data)} OHLC data points for {symbol} (period={period}, interval={interval})", file=sys.stderr)
        return ohlc_data

    except Exception as e:
        log_error(f"yfinance OHLC fetch failed for {symbol}: {e}")
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
            log_error(f"Error fetching OHLC for {symbol}: {e}")
            results[symbol] = None

    return results

def main():
    parser = argparse.ArgumentParser(description='Fetch stock data using multiple providers')
    parser.add_argument('--historical', action='store_true', help='Fetch historical price data')
    parser.add_argument('--ohlc', action='store_true', help='Fetch OHLC (candlestick) data')
    parser.add_argument('--batch-ohlc', action='store_true', help='Fetch OHLC data for multiple symbols')
    parser.add_argument('--json', action='store_true', help='Emit the unified per-symbol JSON response')
    parser.add_argument('symbols', nargs='*', help='Stock symbols to fetch')
    parser.add_argument('--start-date', help='Start date for historical data (YYYY-MM-DD)')
    parser.add_argument('--end-date', help='End date for historical data (YYYY-MM-DD)')
    parser.add_argument('--period', default='1mo', help='Period for OHLC data')
    parser.add_argument('--interval', default='1d', help='Interval for OHLC data')
    parser.add_argument('--test-key', help='Test API key for a specific service (fmp, twelvedata)')
    parser.add_argument('--deadline-seconds', type=float, default=None,
                        help='Time budget for a quote batch; symbols not reached in time report TIMEOUT')

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
                
            print_json({
                'success': result,
                'message': message
            })
            
        except Exception as e:
            print_json({
                'success': False,
                'message': f"Exception during verification: {str(e)}"
            })
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
                print_json(output_data)
            else:
                symbol = symbols[0]
                ohlc_data = fetch_ohlc_data(symbol, period=args.period, interval=args.interval)
                if ohlc_data:
                    print_json(ohlc_data)
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
                print_json(historical_data)
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
                batch_results = fetch_batch(symbols_to_fetch, time_budget_seconds=args.deadline_seconds)
                for symbol, res in batch_results.items():
                    if res:
                        results[symbol] = res
                    elif args.json:
                        results[symbol] = None
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

        if args.json:
            envelopes = []
            for symbol in symbols:
                result = results.get(symbol)
                if is_valid_quote(result):
                    envelopes.append({
                        'symbol': symbol,
                        'success': True,
                        'quote': result,
                    })
                else:
                    error_code = FAILURE_CAUSES.get(symbol, 'NO_DATA')
                    envelopes.append({
                        'symbol': symbol,
                        'success': False,
                        'error': {
                            'error_code': error_code,
                            'message': FAILURE_MESSAGES[error_code].format(symbol=symbol),
                        },
                    })
            print_json(envelopes)
        elif len(symbols) == 1:
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
                print_json(json_results)
            else:
                output_error('NO_DATA', 'No data received for any symbols')

if __name__ == "__main__":
    main()
