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
            yahoo_fetch = stack.enter_context(mock.patch.object(
                self.module,
                "fetch_real_time_quote_yahoo_api",
            ))
            fmp_fetch = stack.enter_context(mock.patch.object(
                self.module,
                "fetch_real_time_quote_fmp",
            ))
            result = self.module.fetch_real_time_quote("^GSPC")

        self.assertEqual(result, valid_twelve_data)
        yahoo_fetch.assert_not_called()
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
