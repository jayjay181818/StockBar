#!/usr/bin/env python3
"""
get_instrument_events.py - Instrument type, dividend and earnings dates from Yahoo

For each symbol, asks Yahoo Finance (through yfinance) for the instrument type,
the ex-dividend date, the dividend pay date, the earnings date (or range), and
the dividends of the last twelve months. Nothing is estimated: a field Yahoo
does not give is null, and a date already past is returned as it is.

With --earnings-history it asks instead for each symbol's earnings dates of the
last twelve months, each with the reported EPS, the estimated EPS and the
surprise where Yahoo gives them, exactly as given.

Usage:
    python3 get_instrument_events.py [--json] [--earnings-history] [--deadline-seconds N] SYMBOL [SYMBOL ...]

Output (stdout, one JSON array, one entry per symbol in the order asked):
    {"symbol": "ALPHA", "success": true, "events": {
        "symbol": "ALPHA", "instrumentType": "EQUITY",
        "exDividendDate": "YYYY-MM-DD" | null, "dividendPayDate": ... | null,
        "earningsDate": ... | null, "earningsDateEnd": ... | null,
        "dividends": [{"date": "YYYY-MM-DD", "amount": 0.25}, ...] | null (mixed currencies),
        "dividendCurrency": "USD" | null, "fetchedAt": <epoch seconds>}}
    {"symbol": "BETA.L", "success": false,
     "error": {"error_code": "RATE_LIMIT", "message": "..."}}

With --earnings-history a success is instead:
    {"symbol": "ALPHA", "success": true, "earningsHistory": {
        "symbol": "ALPHA",
        "earnings": [{"date": "YYYY-MM-DD", "reportedEPS": 1.52 | null,
                      "estimatedEPS": 1.48 | null, "surprisePercent": 2.7 | null}, ...],
        "epsCurrency": "USD" | null (figures dropped), "fetchedAt": <epoch seconds>}}
A symbol Yahoo has no earnings page for is NO_DATA; one whose page lists no
date in the twelve months is a success with an empty list.

A usage problem or a missing yfinance is one JSON error object instead:
    {"error": true, "error_code": "...", "message": "...", "timestamp": ...}

Diagnostics go to stderr only.
"""

import argparse
import collections.abc
import contextlib
import datetime
import json
import logging
import math
import os
import re
import sys
import threading
import time

try:
    import yfinance as yf
    YFINANCE_AVAILABLE = True
except ImportError:
    yf = None
    YFINANCE_AVAILABLE = False

# The pence rule lives in get_ohlc_data.py (it mirrors normalize_currency() in
# get_stock_data.py, which cannot be imported without side effects). Load it
# from this script's own folder, then take the folder off the path again so a
# long-lived worker's import path is left as it was.
_SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
_ADDED_SCRIPT_DIRECTORY = _SCRIPT_DIRECTORY not in sys.path
if _ADDED_SCRIPT_DIRECTORY:
    sys.path.insert(0, _SCRIPT_DIRECTORY)
try:
    from get_ohlc_data import finite_float, uses_pence_quotes
finally:
    if _ADDED_SCRIPT_DIRECTORY:
        try:
            sys.path.remove(_SCRIPT_DIRECTORY)
        except ValueError:
            pass


# Same spacing and per-symbol deadline as quote batches in get_stock_data.py.
REQUEST_SPACING_SECONDS = 1.0
SYMBOL_DEADLINE_SECONDS = 20.0
# Daily bars over two years; the twelve-month cut is made here, by date, so the
# boundary does not depend on how Yahoo trims a range.
DIVIDEND_HISTORY_PERIOD = "2y"
# Rows asked of Yahoo's earnings page. yfinance asks the page for 25 rows for
# any limit up to 25 (upcoming estimates first, then the most recent reports),
# which covers well over a year of quarterly reports.
EARNINGS_HISTORY_LIMIT = 12
# The short chart asked for the quote currency of the EPS figures.
CURRENCY_CHART_PERIOD = "5d"
# yfinance's names for the earnings page's columns (base.py, the scrape).
EARNINGS_COLUMNS = {
    "reportedEPS": ("Reported EPS",),
    "estimatedEPS": ("EPS Estimate",),
    "surprisePercent": ("Surprise(%)", "Surprise (%)"),
}
PENCE_CURRENCIES = ("GBp", "GBX")

FAILURE_PATTERNS = (
    ("RATE_LIMIT", re.compile(r"(?i)\b429\b|too many requests|rate.?limit")),
    ("TIMEOUT", re.compile(r"(?i)timed? ?out")),
    ("NETWORK_ERROR", re.compile(
        r"(?i)connection|name resolution|nodename nor servname|network is unreachable|"
        r"max retries|ssl|\b50[0234]\b|could not resolve"
    )),
)

FAILURE_MESSAGES = {
    "RATE_LIMIT": "Yahoo is rate limiting requests ({symbol})",
    "TIMEOUT": "The request for {symbol} timed out",
    "NETWORK_ERROR": "Yahoo could not be reached ({symbol})",
    "NO_DATA": "No data received for {symbol}",
    "PROVIDER_ERROR": "yfinance failed while reading {symbol}",
}

_ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def classify_failure(message, error=None):
    """RATE_LIMIT, TIMEOUT or NETWORK_ERROR for a provider-wide cause, else None."""
    if error is not None and type(error).__name__ == "YFRateLimitError":
        return "RATE_LIMIT"
    text = str(message)
    for code, pattern in FAILURE_PATTERNS:
        if pattern.search(text):
            return code
    return None


def iso_date(value):
    """`YYYY-MM-DD` for a date-like value, or None.

    Accepts dates, datetimes and pandas Timestamps (with or without a time
    zone: the date is taken in the value's own zone, never shifted), strings
    that start with an ISO date, and epoch seconds (read in UTC). NaT, NaN,
    None, empty lists and anything else become None. Lists are not unpacked
    here; callers decide which element they mean.
    """
    if value is None or isinstance(value, bool):
        return None
    try:
        # NaN and NaT are the only values not equal to themselves. Checked
        # before the datetime branch: pandas.NaT is a datetime subclass.
        if value != value:
            return None
    except Exception:
        return None
    result = None
    try:
        if isinstance(value, datetime.datetime):
            result = value.date().isoformat()
        elif isinstance(value, datetime.date):
            result = value.isoformat()
        elif isinstance(value, (int, float)):
            if not math.isfinite(value):
                return None
            result = datetime.datetime.fromtimestamp(value, tz=datetime.timezone.utc).date().isoformat()
        elif isinstance(value, str):
            text = value.strip()[:10]
            result = datetime.date.fromisoformat(text).isoformat()
        elif hasattr(value, "date") and callable(value.date):
            result = value.date().isoformat()
    except Exception:
        return None
    if not isinstance(result, str) or not _ISO_DATE.match(result):
        return None
    return result


def first_date(value):
    """The first usable date of a value that may be a list."""
    if isinstance(value, (list, tuple)):
        for item in value:
            day = iso_date(item)
            if day is not None:
                return day
        return None
    return iso_date(value)


def earnings_range(value):
    """(start, end) of Yahoo's earnings date. `end` is set only for a real range."""
    if isinstance(value, (list, tuple)):
        days = [day for day in (iso_date(item) for item in value) if day is not None]
        if not days:
            return None, None
        start, end = min(days), max(days)
        return start, (end if end != start else None)
    return iso_date(value), None


def one_year_before(day):
    try:
        return day.replace(year=day.year - 1)
    except ValueError:
        # 29 February
        return day.replace(year=day.year - 1, day=28)


def dividend_rows(dividends):
    """[(date, amount, currency or None)] from what get_dividends() returned.

    yfinance gives a Series of amounts, or, when Yahoo tags dividends with a
    currency of their own, a DataFrame with `Dividends` and `currency`.
    """
    if dividends is None:
        return None
    rows = []
    try:
        if getattr(dividends, "empty", False):
            return []
        columns = getattr(dividends, "columns", None)
        if columns is not None:
            amounts = dividends["Dividends"] if "Dividends" in columns else None
            currencies = dividends["currency"] if "currency" in columns else None
            if amounts is None:
                return None
            for position, (index, amount) in enumerate(amounts.items()):
                currency = None
                if currencies is not None:
                    raw = currencies.iloc[position]
                    currency = str(raw).strip() if isinstance(raw, str) and raw.strip() else None
                rows.append((index, amount, currency))
        else:
            for index, amount in dividends.items():
                rows.append((index, amount, None))
    except Exception:
        return None
    return rows


def recent_dividends(symbol, dividends, reported_currency, today):
    """Dividends dated within the twelve months up to `today`, in the major unit.

    Returns (list or None, currency or None). The pence rule is the one prices
    use (`uses_pence_quotes` in get_ohlc_data.py), applied to the dividends' own
    currency when Yahoo gives one. Dividends in more than one currency are not
    combined: the list is None rather than a guess.
    """
    rows = dividend_rows(dividends)
    if rows is None:
        return None, None
    earliest = one_year_before(today)
    kept = []
    for index, amount, row_currency in rows:
        day = iso_date(index)
        value = finite_float(amount)
        if day is None or value is None or value <= 0:
            continue
        date_value = datetime.date.fromisoformat(day)
        if date_value < earliest or date_value > today:
            continue
        kept.append((day, value, row_currency))
    if not kept:
        return [], None

    row_currencies = {currency for _, _, currency in kept if currency is not None}
    if len(row_currencies) > 1:
        print(f"{symbol}: dividends in more than one currency {sorted(row_currencies)}; left out", file=sys.stderr)
        return None, None
    currency = next(iter(row_currencies)) if row_currencies else reported_currency
    if isinstance(currency, str) and not currency.strip():
        currency = None

    pence = uses_pence_quotes(symbol, currency)
    divisor = 100.0 if pence else 1.0
    if pence:
        normalized_currency = "GBP"
    elif currency is not None:
        normalized_currency = str(currency).strip().upper()
    else:
        normalized_currency = None

    kept.sort(key=lambda row: row[0])
    return [{"date": day, "amount": value / divisor} for day, value, _ in kept], normalized_currency


def metadata_value(metadata, key):
    # yfinance 1.8 gives the chart metadata as its own read-only mapping
    # (HistoryMetadata), not a dict; an older one gave a dict. Both are read.
    if not isinstance(metadata, collections.abc.Mapping):
        return None
    value = metadata.get(key)
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def earnings_rows(frame):
    """[(date-like, {field: value})] from what get_earnings_dates() returned, or None.

    yfinance gives a DataFrame indexed by the earnings date (a zoned Timestamp)
    with `EPS Estimate`, `Reported EPS` and `Surprise(%)` columns, Yahoo's `-`
    already read as NaN; or None when Yahoo has no earnings page for the symbol.
    """
    if frame is None:
        return None
    try:
        if getattr(frame, "empty", False):
            return []
        columns = list(getattr(frame, "columns", []))
        values = {}
        for field, names in EARNINGS_COLUMNS.items():
            name = next((name for name in names if name in columns), None)
            values[field] = list(frame[name].tolist()) if name is not None else None
        index = list(frame.index)
    except Exception:
        return None
    rows = []
    for position, when in enumerate(index):
        figures = {}
        for field, column in values.items():
            figures[field] = column[position] if column is not None and position < len(column) else None
        rows.append((when, figures))
    return rows


def recent_earnings(symbol, rows, today, currency_for_figures):
    """Earnings dated within the twelve months up to `today`, oldest first.

    Returns (list, currency or None). Figures are kept exactly as Yahoo gives
    them. `currency_for_figures` is called only when some row has an EPS
    figure, and gives the quote currency or None. The earnings page names no
    currency, so the figures are taken to be in the quote currency, and are
    dropped (the dates kept) when that currency is not known or is pence:
    whether Yahoo gives a pence-quoted share's EPS in pence or pounds cannot
    be told, and it is not guessed.
    """
    earliest = one_year_before(today)
    by_day = {}
    for when, figures in rows:
        day = iso_date(when)
        if day is None:
            continue
        date_value = datetime.date.fromisoformat(day)
        if date_value < earliest or date_value > today:
            continue
        entry = {
            "date": day,
            "reportedEPS": finite_float(figures.get("reportedEPS")),
            "estimatedEPS": finite_float(figures.get("estimatedEPS")),
            "surprisePercent": finite_float(figures.get("surprisePercent")),
        }
        known = sum(value is not None for key, value in entry.items() if key != "date")
        # One row per day; when Yahoo lists a day twice, the row with more figures.
        previous = by_day.get(day)
        if previous is None or known > previous[0]:
            by_day[day] = (known, entry)
    kept = [entry for _, entry in sorted(by_day.values(), key=lambda item: item[1]["date"])]
    if not any(entry["reportedEPS"] is not None or entry["estimatedEPS"] is not None for entry in kept):
        return kept, None

    currency = currency_for_figures()
    if isinstance(currency, str):
        currency = currency.strip() or None
    if currency is None or currency in PENCE_CURRENCIES:
        reason = "no currency" if currency is None else f"quoted in {currency}"
        print(f"{symbol}: EPS figures left out ({reason}); dates kept", file=sys.stderr)
        for entry in kept:
            entry["reportedEPS"] = None
            entry["estimatedEPS"] = None
        return kept, None
    return kept, str(currency).upper()


def forget_cached_pages():
    """Clears yfinance's in-memory cache of fetched pages.

    yfinance keeps the earnings page it fetched (YfData.cache_get is an
    lru_cache) for as long as the interpreter lives. Stockbar's worker runs
    this script many times in one interpreter, so without this a later run,
    a forced refresh included, would be answered from an earlier one.
    """
    try:
        import importlib
        cache_get = getattr(getattr(importlib.import_module("yfinance.data"), "YfData", None), "cache_get", None)
        clear = getattr(cache_get, "cache_clear", None)
        if callable(clear):
            clear()
    except Exception as error:
        print(f"Could not clear yfinance's page cache: {error}", file=sys.stderr)


class _FailureCapture(logging.Handler):
    """Records yfinance's logged errors for one thread.

    With its default settings yfinance logs most request failures instead of
    raising them, so a timeout or a refused connection would otherwise look
    like a symbol with no data.
    """

    def __init__(self, thread_ident):
        super().__init__(level=logging.WARNING)
        self.thread_ident = thread_ident
        self.messages = []

    def emit(self, record):
        if record.thread != self.thread_ident:
            return
        try:
            self.messages.append(record.getMessage())
        except Exception:
            pass


@contextlib.contextmanager
def raising_logged_failures(symbol):
    """Runs the block with yfinance's logged errors recorded, then raises a
    provider-wide failure that yfinance only logged as RuntimeError, so the
    caller reports it instead of an empty answer."""
    logger = logging.getLogger("yfinance")
    capture = _FailureCapture(threading.get_ident())
    logger.addHandler(capture)
    try:
        yield
    finally:
        logger.removeHandler(capture)

    for message in capture.messages:
        print(f"{symbol}: {message}", file=sys.stderr)
    for message in capture.messages:
        # The symbol itself is left out, so a ticker such as one containing
        # "SSL" is not mistaken for a connection failure.
        if classify_failure(message.replace(symbol, "")) is not None:
            raise RuntimeError(message)


def fetch_events(symbol, today, now_seconds):
    """One symbol's events, or raises. Provider-wide failures that yfinance
    only logged are raised as RuntimeError so the caller reports them."""
    with raising_logged_failures(symbol):
        ticker = yf.Ticker(symbol)
        dividends = ticker.get_dividends(period=DIVIDEND_HISTORY_PERIOD)
        metadata = ticker.history_metadata
        calendar = ticker.calendar

    instrument_type = metadata_value(metadata, "instrumentType")
    reported_currency = metadata_value(metadata, "currency")
    # A dict in yfinance 1.8; history_metadata has already become a read-only mapping once.
    calendar = calendar if isinstance(calendar, collections.abc.Mapping) else {}
    # yfinance swallows a failed chart request and leaves its metadata empty.
    # Without the chart there is no instrument type and no trustworthy
    # dividend list, so the symbol is not answered rather than saved as nulls.
    if instrument_type is None or dividends is None:
        return None

    dividend_list, dividend_currency = recent_dividends(symbol, dividends, reported_currency, today)
    earnings_start, earnings_end = earnings_range(calendar.get("Earnings Date"))
    events = {
        "symbol": symbol,
        "instrumentType": instrument_type,
        "exDividendDate": first_date(calendar.get("Ex-Dividend Date")),
        "dividendPayDate": first_date(calendar.get("Dividend Date")),
        "earningsDate": earnings_start,
        "earningsDateEnd": earnings_end,
        "dividends": dividend_list,
        "dividendCurrency": dividend_currency,
        "fetchedAt": now_seconds,
    }
    return events


def fetch_earnings_history(symbol, today, now_seconds):
    """One symbol's earnings of the last twelve months, None for no data, or raises.

    One request for Yahoo's earnings page (`Ticker.get_earnings_dates`); a
    second, a short chart for the quote currency, only when the page gives an
    EPS figure in the twelve months. A chart that does not answer fails the
    symbol.
    """
    with raising_logged_failures(symbol):
        ticker = yf.Ticker(symbol)
        frame = ticker.get_earnings_dates(limit=EARNINGS_HISTORY_LIMIT)
        rows = earnings_rows(frame)
        if rows is None:
            # yfinance found no earnings table (it logs "No earnings dates
            # found"): a fund, or a symbol Yahoo has no earnings page for.
            return None

        def quote_currency():
            # history() lets a rate limit through, where history_metadata
            # alone would swallow it. Any other failure leaves the chart's
            # metadata empty: then nothing is answered, rather than an answer
            # saved for a day with its figures dropped.
            ticker.history(period=CURRENCY_CHART_PERIOD, interval="1d")
            metadata = ticker.history_metadata
            if metadata_value(metadata, "instrumentType") is None:
                raise RuntimeError("the chart gave no metadata, so the EPS figures' currency is unknown")
            return metadata_value(metadata, "currency")

        earnings, currency = recent_earnings(symbol, rows, today, quote_currency)

    return {
        "symbol": symbol,
        "earnings": earnings,
        "epsCurrency": currency,
        "fetchedAt": now_seconds,
    }


def failure_envelope(symbol, code, detail=None):
    message = FAILURE_MESSAGES[code].format(symbol=symbol)
    if detail:
        message = f"{message}: {detail}"
    return {"symbol": symbol, "success": False, "error": {"error_code": code, "message": message}}


MODES = {
    # mode: (fetch function, the success envelope's key)
    "events": (lambda *args: fetch_events(*args), "events"),
    "earningsHistory": (lambda *args: fetch_earnings_history(*args), "earningsHistory"),
}


def fetch_with_deadline(symbol, today, now_seconds, deadline_seconds, mode="events"):
    """Envelope for one symbol, giving up waiting after `deadline_seconds`."""
    fetch, key = MODES[mode]
    outcome = {}

    def work():
        try:
            outcome["events"] = fetch(symbol, today, now_seconds)
        except Exception as error:
            outcome["error"] = error

    thread = threading.Thread(target=work, name=f"events-{symbol}", daemon=True)
    thread.start()
    thread.join(max(0.0, deadline_seconds))
    if thread.is_alive():
        print(f"Events for {symbol} exceeded {deadline_seconds:.0f}s; skipping it", file=sys.stderr)
        return failure_envelope(symbol, "TIMEOUT")
    if "error" in outcome:
        error = outcome["error"]
        print(f"Error fetching events for {symbol}: {error}", file=sys.stderr)
        code = classify_failure(error, error) or "PROVIDER_ERROR"
        return failure_envelope(symbol, code, None if code != "PROVIDER_ERROR" else type(error).__name__)
    events = outcome.get("events")
    if events is None:
        return failure_envelope(symbol, "NO_DATA")
    return {"symbol": symbol, "success": True, key: events}


@contextlib.contextmanager
def utc_process_clock():
    """Reads the process's clock in UTC for as long as the block runs.

    yfinance turns Yahoo's calendar timestamps into dates with the process's
    local time zone (`datetime.fromtimestamp`). Yahoo stamps an ex-dividend or
    pay date at midnight UTC, so on a Mac west of UTC it would come out a day
    early. The zone is put back afterwards, for the other scripts a long-lived
    worker runs.
    """
    if not hasattr(time, "tzset"):
        yield
        return
    previous = os.environ.get("TZ")
    os.environ["TZ"] = "UTC"
    time.tzset()
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = previous
        time.tzset()


def fetch_all(symbols, now=None, time_budget_seconds=None, sleep=time.sleep, clock=time.monotonic, mode="events"):
    """Envelopes for every symbol, in order, each symbol fetched once.

    `mode` is "events" or "earningsHistory". After a rate-limit answer the
    remaining symbols are not asked for: they are reported as rate limited
    too, so the app backs off.
    """
    if mode not in MODES:
        raise ValueError(f"unknown mode {mode!r}")
    with utc_process_clock():
        if mode == "earningsHistory":
            forget_cached_pages()
        return _fetch_all(symbols, now, time_budget_seconds, sleep, clock, mode)


def _fetch_all(symbols, now, time_budget_seconds, sleep, clock, mode):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    today = now.date()
    now_seconds = now.timestamp()
    batch_deadline = (clock() + time_budget_seconds) if time_budget_seconds else None
    by_symbol = {}
    rate_limited = False
    fetched_any = False

    for symbol in dict.fromkeys(symbols):
        if rate_limited:
            by_symbol[symbol] = failure_envelope(symbol, "RATE_LIMIT", "not asked after a rate-limit answer")
            continue
        remaining = None if batch_deadline is None else batch_deadline - clock()
        if remaining is not None and remaining <= 1.0:
            by_symbol[symbol] = failure_envelope(symbol, "TIMEOUT")
            continue
        if fetched_any:
            sleep(REQUEST_SPACING_SECONDS)
        fetched_any = True
        deadline = SYMBOL_DEADLINE_SECONDS if remaining is None else min(SYMBOL_DEADLINE_SECONDS, remaining)
        envelope = fetch_with_deadline(symbol, today, now_seconds, deadline, mode)
        by_symbol[symbol] = envelope
        if not envelope["success"] and envelope["error"]["error_code"] == "RATE_LIMIT":
            rate_limited = True

    return [by_symbol[symbol] for symbol in symbols]


def print_json(value):
    print(json.dumps(value, allow_nan=False))


def output_error(error_code, message):
    print_json({"error": True, "error_code": error_code, "message": message, "timestamp": int(time.time())})


def main():
    parser = argparse.ArgumentParser(description="Instrument type, dividend and earnings dates from Yahoo")
    parser.add_argument("--json", action="store_true", help="Accepted for symmetry with get_stock_data.py; output is always JSON")
    parser.add_argument("--earnings-history", action="store_true",
                        help="Earnings dates of the last twelve months, with EPS where Yahoo gives it")
    parser.add_argument("--deadline-seconds", type=float, default=None,
                        help="Time budget for the batch; symbols not reached in time report TIMEOUT")
    parser.add_argument("symbols", nargs="*", help="Symbols to look up")
    args = parser.parse_args()

    symbols = [symbol.strip().upper() for symbol in args.symbols if symbol.strip()]
    if not symbols:
        print("Usage: get_instrument_events.py [--json] [--earnings-history] [--deadline-seconds N] SYMBOL [SYMBOL ...]",
              file=sys.stderr)
        output_error("INVALID_REQUEST", "No ticker symbol provided")
        sys.exit(1)

    if not YFINANCE_AVAILABLE:
        output_error("PROVIDER_UNAVAILABLE", "yfinance is not installed")
        sys.exit(1)

    mode = "earningsHistory" if args.earnings_history else "events"
    print_json(fetch_all(symbols, time_budget_seconds=args.deadline_seconds, mode=mode))


if __name__ == "__main__":
    main()
