import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack
from unittest import mock


SCRIPT_PATH = os.path.abspath(
    os.path.join(
        os.path.dirname(__file__),
        "..",
        "Stockbar",
        "Resources",
        "get_stock_data.py",
    )
)


def load_module(cache_path):
    os.environ["STOCKBAR_CACHE_FILE"] = cache_path
    spec = importlib.util.spec_from_file_location("stockbar_data_test", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StockDataContractTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.cache_path = os.path.join(self.temp_directory.name, "cache.json")
        self.module = load_module(self.cache_path)

    def tearDown(self):
        self.temp_directory.cleanup()

    def test_twelve_data_ftse_alias_is_provider_specific(self):
        self.assertEqual(self.module.handle_twelvedata_symbol("^FTSE"), ("FTSE", None))
        self.assertEqual(self.module.resolve_symbol_alias("^FTSE"), "^FTSE")

    def test_lon_suffix_is_stripped_only_at_the_end(self):
        self.assertEqual(self.module.handle_twelvedata_symbol("ABC.LON"), ("ABC", "LSE"))
        self.assertEqual(self.module.handle_twelvedata_symbol("LLOY.L"), ("LLOY", "LSE"))
        self.assertEqual(self.module.handle_lse_symbol("ABC.LON"), "ABC.L")
        self.assertEqual(self.module.handle_lse_symbol("A.LSE.L"), "A.LSE.L")

    def test_configured_alias_is_resolved_by_provider_symbol_helpers(self):
        self.module.SYMBOL_ALIASES["MYUK"] = "REAL.L"
        self.assertEqual(self.module.handle_lse_symbol("myuk"), "REAL.L")
        self.assertEqual(self.module.handle_twelvedata_symbol("MYUK"), ("REAL", "LSE"))

    def test_market_state_prefers_reported_state(self):
        from datetime import datetime
        saturday = datetime(2026, 7, 25, 11, 0)
        self.assertEqual(self.module.resolve_market_state("REGULAR", "CLOSED", saturday), "REGULAR")
        self.assertEqual(self.module.resolve_market_state("postpost", "REGULAR", saturday), "CLOSED")
        self.assertEqual(self.module.resolve_market_state("PRE", "CLOSED", saturday), "PRE")

    def test_market_state_is_closed_at_weekends_without_a_reported_state(self):
        from datetime import datetime
        saturday = datetime(2026, 7, 25, 11, 0)
        friday = datetime(2026, 7, 24, 11, 0)
        self.assertEqual(self.module.resolve_market_state(None, "REGULAR", saturday), "CLOSED")
        self.assertEqual(self.module.resolve_market_state("UNKNOWN", "REGULAR", saturday), "CLOSED")
        self.assertEqual(self.module.resolve_market_state(None, "REGULAR", friday), "REGULAR")

    def test_legacy_cache_moves_once_to_default_location_only(self):
        root = self.temp_directory.name
        default_file = os.path.join(root, "Caches", "stockbar-cache", "quote_cache.json")
        legacy_file = os.path.join(root, ".stockbar_cache.json")
        with open(legacy_file, "w") as handle:
            handle.write("{}")
        with open(legacy_file + ".lock", "w"):
            pass

        injected = os.path.join(root, "other.json")
        self.assertFalse(self.module.migrate_legacy_cache(injected, default_file, legacy_file))
        self.assertTrue(os.path.exists(legacy_file))

        self.assertTrue(self.module.migrate_legacy_cache(default_file, default_file, legacy_file))
        self.assertTrue(os.path.exists(default_file))
        self.assertFalse(os.path.exists(legacy_file))
        self.assertFalse(os.path.exists(legacy_file + ".lock"))

        with open(legacy_file, "w") as handle:
            handle.write("newer")
        self.assertFalse(self.module.migrate_legacy_cache(default_file, default_file, legacy_file))
        with open(default_file) as handle:
            self.assertEqual(handle.read(), "{}")

    def test_quote_cache_seconds_is_bounded_by_app_refresh_interval(self):
        self.assertEqual(self.module.quote_cache_seconds(None), 300)
        self.assertEqual(self.module.quote_cache_seconds("54"), 54)
        self.assertEqual(self.module.quote_cache_seconds("5"), 15)
        self.assertEqual(self.module.quote_cache_seconds("9000"), 300)
        self.assertEqual(self.module.quote_cache_seconds("abc"), 300)

    def test_redaction_and_json_sanitization_are_idempotent(self):
        once = self.module.sanitize_log_message("TOKEN=secret [REDACTED]]]")
        self.assertEqual(once, "TOKEN=[REDACTED] [REDACTED]")
        self.assertEqual(self.module.sanitize_log_message(once), once)
        self.assertIsNone(self.module.make_json_safe(float("nan")))
        self.assertIsNone(self.module.make_json_safe(float("inf")))

    def test_quote_validation_rejects_missing_or_non_finite_financial_values(self):
        valid = {
            "symbol": "^GSPC",
            "price": 7428.78,
            "regularMarketPrice": 7428.78,
            "previousClose": 7415.32,
            "timestamp": 1785300000,
        }
        self.assertTrue(self.module.is_valid_quote(valid))

        for field, invalid_value in (
            ("price", float("nan")),
            ("regularMarketPrice", None),
            ("previousClose", None),
            ("previousClose", 0),
            ("timestamp", 0),
        ):
            candidate = dict(valid)
            candidate[field] = invalid_value
            self.assertFalse(self.module.is_valid_quote(candidate), field)

        self.assertFalse(self.module.set_cache("^GSPC", {**valid, "previousClose": None}))
        self.assertIsNone(self.module.get_cached("^GSPC"))

    def test_invalid_provider_quote_falls_through_to_next_provider(self):
        invalid_yfinance = {
            "symbol": "^GSPC",
            "price": 7428.78,
            "regularMarketPrice": 7428.78,
            "previousClose": None,
            "timestamp": 1785300000,
        }
        valid_twelve_data = {
            **invalid_yfinance,
            "previousClose": 7415.32,
        }

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(
                self.module,
                "apply_previous_close_backfill",
                side_effect=lambda _, quote: quote,
            ))
            stack.enter_context(mock.patch.object(
                self.module,
                "fetch_real_time_quote_yfinance",
                return_value=invalid_yfinance,
            ))
            stack.enter_context(mock.patch.object(
                self.module,
                "fetch_real_time_quote_twelvedata",
                return_value=valid_twelve_data,
            ))
            fmp_fetch = stack.enter_context(mock.patch.object(
                self.module,
                "fetch_real_time_quote_fmp",
            ))
            result = self.module.fetch_real_time_quote("^GSPC")

        self.assertEqual(result, valid_twelve_data)
        fmp_fetch.assert_not_called()

    def test_cache_updates_survive_concurrent_processes(self):
        processes = []
        for index in range(8):
            code = (
                "import importlib.util;"
                f"s=importlib.util.spec_from_file_location('m',{SCRIPT_PATH!r});"
                "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
                f"m.set_cache('SYM{index}',{{'symbol':'SYM{index}',"
                f"'price':{index + 1}.0,'regularMarketPrice':{index + 1}.0,"
                f"'previousClose':{index + 0.5},'timestamp':1785300000}})"
            )
            environment = os.environ.copy()
            environment["STOCKBAR_CACHE_FILE"] = self.cache_path
            processes.append(subprocess.Popen([sys.executable, "-c", code], env=environment))

        for process in processes:
            self.assertEqual(process.wait(timeout=30), 0)

        with open(self.cache_path, "r") as cache_file:
            cache = json.load(cache_file)
        self.assertEqual({f"SYM{index}" for index in range(8)}, set(cache))


if __name__ == "__main__":
    unittest.main()


class _FakeHistory:
    def __init__(self, rows):
        self.rows = rows
        self.empty = not rows

    def iterrows(self):
        return iter(self.rows)


class _FakeTicker:
    def __init__(self, rows, currency):
        self._rows = rows
        self.history_metadata = {"currency": currency} if currency else {}
        self.fast_info = {}
        self.info = {}

    def history(self, **_kwargs):
        return _FakeHistory(self._rows)


class HistoricalCurrencyTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.module = load_module(os.path.join(self.temp_directory.name, "cache.json"))

    def tearDown(self):
        self.temp_directory.cleanup()

    def yfinance_prices(self, symbol, currency):
        from datetime import datetime as real_datetime, timezone

        rows = [
            (real_datetime(2026, 11, 3, 10, tzinfo=timezone.utc), {"Open": 1000.0, "Close": 1010.0}),
            (real_datetime(2026, 11, 3, 11, tzinfo=timezone.utc), {"Open": 1010.0, "Close": 1020.0}),
        ]
        fake_yf = mock.Mock()
        fake_yf.Ticker.return_value = _FakeTicker(rows, currency)
        with mock.patch.object(self.module, "YFINANCE_AVAILABLE", True), \
                mock.patch.object(self.module, "yf", fake_yf, create=True):
            data = self.module.fetch_historical_data_yfinance(symbol, "2026-11-03", "2026-11-03")
        return [(point["price"], point["previousClose"]) for point in data]

    def fmp_prices(self, symbol, currency):
        response = {"historical": [{"date": "2026-11-03", "open": 1000.0, "close": 1010.0}]}
        if currency:
            response["currency"] = currency
        with mock.patch.object(self.module, "make_fmp_request", return_value=response):
            data = self.module.fetch_historical_data_fmp(symbol, "2026-11-03", "2026-11-03")
        return [(point["price"], point["previousClose"]) for point in data]

    def test_pence_quoted_london_history_is_divided_by_100(self):
        self.assertEqual(self.yfinance_prices("VOD.L", "GBp"), [(10.1, 10.0), (10.2, 10.1)])
        self.assertEqual(self.fmp_prices("VOD.L", "GBX"), [(10.1, 10.0)])

    def test_pound_and_dollar_quoted_london_history_keeps_its_scale(self):
        self.assertEqual(self.yfinance_prices("CSPX.L", "USD"), [(1010.0, 1000.0), (1020.0, 1010.0)])
        self.assertEqual(self.yfinance_prices("III.L", "GBP"), [(1010.0, 1000.0), (1020.0, 1010.0)])
        self.assertEqual(self.fmp_prices("CSPX.L", "USD"), [(1010.0, 1000.0)])

    def test_missing_currency_falls_back_to_the_london_suffix_rule(self):
        self.assertEqual(self.yfinance_prices("VOD.L", None), [(10.1, 10.0), (10.2, 10.1)])
        self.assertEqual(self.yfinance_prices("AAPL", None), [(1010.0, 1000.0), (1020.0, 1010.0)])
        self.assertEqual(self.fmp_prices("VOD.L", None), [(10.1, 10.0)])


class ExchangeDateTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.module = load_module(os.path.join(self.temp_directory.name, "cache.json"))

    def tearDown(self):
        self.temp_directory.cleanup()

    def test_uses_the_exchange_timezone_not_the_local_date(self):
        from datetime import datetime as real_datetime, timezone
        from zoneinfo import ZoneInfo

        # 01:30 UTC on 15 Nov is still 14 Nov in New York.
        instant = real_datetime(2026, 11, 15, 1, 30, tzinfo=timezone.utc)

        class FixedDatetime(real_datetime):
            @classmethod
            def now(cls, tz=None):
                return instant.astimezone(tz) if tz else instant.replace(tzinfo=None)

        index = mock.Mock(tz=ZoneInfo("America/New_York"))
        with mock.patch.object(self.module, "datetime", FixedDatetime):
            self.assertEqual(self.module.exchange_today(index, "AAPL").isoformat(), "2026-11-14")

    def test_index_without_timezone_falls_back_to_market_date(self):
        index = mock.Mock(tz=None)
        with mock.patch.object(self.module, "market_date_for_symbol", return_value="2026-11-14"):
            self.assertEqual(self.module.exchange_today(index, "VOD.L").isoformat(), "2026-11-14")


class PreviousCloseTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.module = load_module(os.path.join(self.temp_directory.name, "cache.json"))

    def tearDown(self):
        self.temp_directory.cleanup()

    def test_open_session_compares_with_the_last_completed_close(self):
        pick = self.module.previous_close_for_quote
        self.assertEqual(pick([98.0, 100.0], True, False), 100.0)

    def test_weekend_and_before_the_open_compare_with_the_close_before(self):
        # The regular price is then the last completed close itself.
        pick = self.module.previous_close_for_quote
        self.assertEqual(pick([98.0, 100.0], False, False), 98.0)

    def test_pre_market_price_compares_with_the_last_completed_close(self):
        pick = self.module.previous_close_for_quote
        self.assertEqual(pick([98.0, 100.0], False, True), 100.0)

    def test_short_history_falls_back(self):
        pick = self.module.previous_close_for_quote
        self.assertEqual(pick([100.0], False, False), 100.0)
        self.assertEqual(pick([], False, False, fallback=7.0), 7.0)

    def test_only_a_missing_previous_close_needs_a_history_lookup(self):
        needs = self.module.needs_prev_close_backfill
        self.assertFalse(needs("VOD.L", 1.0, 1.0, "GBP"))
        self.assertTrue(needs("VOD.L", 1.0, None, "GBP"))
        self.assertTrue(needs("AAPL", 1.0, float("nan"), "USD"))


class QuoteBatchTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.module = load_module(os.path.join(self.temp_directory.name, "cache.json"))
        self.module.REQUEST_SPACING_SECONDS = 0

    def tearDown(self):
        self.temp_directory.cleanup()

    @staticmethod
    def quote(symbol):
        return {"symbol": symbol, "price": 10.0, "previousClose": 9.0, "timestamp": 1_800_000_000}

    def test_a_hung_symbol_costs_only_itself(self):
        import threading

        release = threading.Event()
        self.addCleanup(release.set)

        def fetch(symbol):
            if symbol == "SLOW":
                release.wait(5)
                return None
            return self.quote(symbol)

        self.module.SYMBOL_DEADLINE_SECONDS = 0.05
        with mock.patch.object(self.module, "fetch_real_time_quote", side_effect=fetch):
            results = self.module.fetch_batch(["AAA", "SLOW", "BBB"])

        self.assertEqual(results["AAA"]["price"], 10.0)
        self.assertEqual(results["BBB"]["price"], 10.0)
        self.assertIsNone(results["SLOW"])
        self.assertEqual(self.module.FAILURE_CAUSES, {"SLOW": "TIMEOUT"})

    def test_an_exhausted_budget_reports_the_rest_as_timed_out(self):
        with mock.patch.object(self.module, "fetch_real_time_quote", side_effect=self.quote) as fetch:
            results = self.module.fetch_batch(["AAA", "BBB"], time_budget_seconds=0.5)

        fetch.assert_not_called()
        self.assertEqual(results, {"AAA": None, "BBB": None})
        self.assertEqual(self.module.FAILURE_CAUSES, {"AAA": "TIMEOUT", "BBB": "TIMEOUT"})

    def test_a_logged_provider_failure_becomes_the_symbol_error_code(self):
        def fetch(symbol):
            if symbol == "LIMITED":
                self.module.log_error("yfinance fetch failed for LIMITED: Too Many Requests. Rate limited.")
            elif symbol == "OFFLINE":
                self.module.log_error("Request failed via requests: Max retries exceeded")
            return None

        with mock.patch.object(self.module, "fetch_real_time_quote", side_effect=fetch):
            self.module.fetch_batch(["LIMITED", "OFFLINE", "UNKNOWN"])

        self.assertEqual(self.module.FAILURE_CAUSES, {"LIMITED": "RATE_LIMIT", "OFFLINE": "NETWORK_ERROR"})

    def test_failures_logged_outside_a_fetch_are_not_attributed(self):
        self.module.log_error("HTTP Error 429")
        self.assertEqual(self.module.FAILURE_CAUSES, {})

    def test_retired_providers_in_the_priority_list_are_skipped(self):
        self.module.CONFIG["DATA_SOURCE_PRIORITY"] = ["stooq", "yfinance"]
        history = [{"symbol": "AAPL", "price": 1.0}]
        with mock.patch.object(self.module, "YFINANCE_AVAILABLE", True), \
                mock.patch.object(self.module, "fetch_historical_data_yfinance", return_value=history):
            self.assertEqual(self.module.fetch_historical_data("AAPL", "2026-01-01", "2026-01-31"), history)


class ProviderHousekeepingTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.cache_path = os.path.join(self.temp_directory.name, "cache.json")
        self.module = load_module(self.cache_path)

    def tearDown(self):
        self.temp_directory.cleanup()

    def test_exchange_time_zone_follows_the_suffix(self):
        zone = self.module.market_timezone_name
        self.assertEqual(zone("VOD.L"), "Europe/London")
        self.assertEqual(zone("SAP.DE"), "Europe/Berlin")
        self.assertEqual(zone("7203.T"), "Asia/Tokyo")
        self.assertEqual(zone("shop.to"), "America/Toronto")
        self.assertEqual(zone("AAPL"), "America/New_York")
        self.assertEqual(zone("BRK.B"), "America/New_York")
        self.assertEqual(zone("^GSPC"), "America/New_York")

    def test_clock_state_uses_each_exchange_s_hours(self):
        from datetime import datetime
        state = self.module.clock_market_state
        self.assertEqual(state("VOD.L", datetime(2026, 7, 22, 7, 30)), "PRE")
        self.assertEqual(state("VOD.L", datetime(2026, 7, 22, 16, 29)), "REGULAR")
        self.assertEqual(state("VOD.L", datetime(2026, 7, 22, 17, 30)), "CLOSED")
        self.assertEqual(state("AAPL", datetime(2026, 7, 22, 9, 29)), "PRE")
        self.assertEqual(state("AAPL", datetime(2026, 7, 22, 9, 30)), "REGULAR")
        self.assertEqual(state("AAPL", datetime(2026, 7, 22, 19, 59)), "POST")
        self.assertEqual(state("SAP.DE", datetime(2026, 7, 22, 8, 59)), "CLOSED")
        self.assertEqual(state("SAP.DE", datetime(2026, 7, 22, 12, 0)), "REGULAR")

    def test_trading_currency_never_uses_the_accounts_currency(self):
        class Ticker:
            history_metadata = {"currency": "GBp"}

        class NoMetadata:
            @property
            def history_metadata(self):
                raise RuntimeError("no chart")

        currency = self.module.trading_currency
        self.assertEqual(currency(Ticker(), {"currency": "EUR", "financialCurrency": "USD"}), "EUR")
        self.assertEqual(currency(Ticker(), {"financialCurrency": "USD"}), "GBp")
        self.assertIsNone(currency(NoMetadata(), {"financialCurrency": "USD"}))

    def test_old_cache_entries_are_pruned(self):
        now = 1_800_000_000
        week = self.module.CACHE_ENTRY_MAX_AGE_SECONDS
        day = self.module.PREV_CLOSE_CACHE_MAX_AGE_SECONDS
        cache = {
            "OLD": {"timestamp": now - week - 1, "result": {}},
            "NEW": {"timestamp": now - 60, "result": {}},
            "BROKEN": "not an entry",
            self.module.PREV_CLOSE_CACHE_KEY: {
                "OLD": {"timestamp": now - day - 1, "value": 1.0},
                "NEW": {"timestamp": now - 60, "value": 1.0},
            },
            self.module.PROVIDER_COOLDOWN_KEY: {"twelvedata": now + 30},
        }
        self.assertEqual(self.module.prune_cache(cache, now=now), 3)
        self.assertEqual(
            sorted(cache),
            sorted(["NEW", self.module.PREV_CLOSE_CACHE_KEY, self.module.PROVIDER_COOLDOWN_KEY]),
        )
        self.assertEqual(list(cache[self.module.PREV_CLOSE_CACHE_KEY]), ["NEW"])

    def test_twelve_data_pauses_after_its_allowance_is_used_up(self):
        calls = []

        def refused(url, params):
            calls.append(url)
            return {"code": 429, "status": "error", "message": "out of credits"}

        with mock.patch.object(self.module, "make_request", refused):
            self.assertIsNone(self.module.twelvedata_request("https://example.invalid/quote", {}))
            self.assertIsNone(self.module.twelvedata_request("https://example.invalid/quote", {}))
        self.assertEqual(len(calls), 1)
        self.assertGreater(self.module.provider_cooldown_remaining("twelvedata"), 0)

        later = self.module.time.time() + self.module.TWELVE_DATA_COOLDOWN_SECONDS + 1
        self.assertEqual(self.module.provider_cooldown_remaining("twelvedata", now=later), 0)

    def test_twelve_data_passes_other_answers_through(self):
        with mock.patch.object(self.module, "make_request", lambda url, params: {"close": "1.0"}):
            self.assertEqual(self.module.twelvedata_request("https://example.invalid/quote", {}), {"close": "1.0"})
        self.assertEqual(self.module.provider_cooldown_remaining("twelvedata"), 0)
