import contextlib
import datetime
import importlib.util
import io
import json
import logging
import math
import os
import sys
import time
import unittest
from unittest import mock
from collections.abc import Mapping


SCRIPT_PATH = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "Stockbar", "Resources", "get_instrument_events.py")
)

NOW = datetime.datetime(2026, 11, 20, 12, 0, tzinfo=datetime.timezone.utc)
UTC = datetime.timezone.utc


def load_module():
    spec = importlib.util.spec_from_file_location("stockbar_instrument_events_test", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def day(text):
    """A dividend index value the way yfinance gives it: a zoned timestamp."""
    return datetime.datetime.fromisoformat(text + "T00:00:00").replace(tzinfo=UTC)


class _FakeSeries:
    """Stand-in for the pandas Series get_dividends() returns."""

    def __init__(self, rows):
        self._rows = list(rows)

    @property
    def empty(self):
        return not self._rows

    def items(self):
        return iter(self._rows)

    @property
    def iloc(self):
        values = [value for _, value in self._rows]

        class _Positional:
            def __getitem__(self, position):
                return values[position]

        return _Positional()


class _FakeFrame:
    """Stand-in for the DataFrame yfinance returns when dividends carry a currency."""

    def __init__(self, rows):
        self._rows = list(rows)
        self.columns = ["Dividends", "currency"]

    @property
    def empty(self):
        return not self._rows

    def __getitem__(self, column):
        position = self.columns.index(column)
        return _FakeSeries([(index, values[position]) for index, values in self._rows])


class _FakeColumn:
    def __init__(self, values):
        self._values = list(values)

    def tolist(self):
        return list(self._values)


class _FakeEarningsFrame:
    """Stand-in for the DataFrame get_earnings_dates() returns: indexed by the
    earnings date (a zoned timestamp), with Yahoo's `-` already read as NaN."""

    def __init__(self, rows, columns=("EPS Estimate", "Reported EPS", "Surprise(%)")):
        self._rows = list(rows)
        self.columns = list(columns)
        self.index = [when for when, _ in self._rows]

    @property
    def empty(self):
        return not self._rows

    def __getitem__(self, column):
        position = self.columns.index(column)
        return _FakeColumn(values[position] for _, values in self._rows)


NAN = float("nan")
EASTERN_WINTER = datetime.timezone(datetime.timedelta(hours=-5))
EASTERN_SUMMER = datetime.timezone(datetime.timedelta(hours=-4))


def report(text, hour=16, zone=EASTERN_SUMMER):
    """An earnings date the way yfinance's scrape gives it: zoned to the exchange."""
    return datetime.datetime.fromisoformat(f"{text}T{hour:02d}:00:00").replace(tzinfo=zone)


class YFRateLimitError(Exception):
    """Same name as yfinance's own exception, which the script recognises."""

    def __init__(self):
        super().__init__("Too Many Requests. Rate limited. Try after a while.")


class _Metadata(Mapping):
    """The chart metadata the way yfinance 1.8 gives it: a read-only mapping
    (its HistoryMetadata), not a dict. Every fake ticker answers with one."""

    def __init__(self, values):
        self._values = dict(values)

    def __getitem__(self, key):
        return self._values[key]

    def __iter__(self):
        return iter(self._values)

    def __len__(self):
        return len(self._values)


class _FakeTicker:
    def __init__(self, symbol, spec, log):
        self.symbol = symbol
        self._spec = spec
        self._log = log

    def get_dividends(self, period="max"):
        self._log.append((self.symbol, "dividends", period))
        if "dividends_error" in self._spec:
            raise self._spec["dividends_error"]
        for message in self._spec.get("logged_errors", ()):
            logging.getLogger("yfinance").error(message)
        return self._spec.get("dividends", _FakeSeries([]))

    def history(self, period="1mo", interval="1d"):
        self._log.append((self.symbol, "history", period))
        if "chart_error" in self._spec:
            raise self._spec["chart_error"]
        return None

    @property
    def history_metadata(self):
        self._log.append((self.symbol, "metadata", None))
        metadata = self._spec.get("metadata", {})
        return _Metadata(metadata) if isinstance(metadata, dict) else metadata

    def get_earnings_dates(self, limit=12, offset=0):
        self._log.append((self.symbol, "earnings_dates", limit))
        if "earnings_error" in self._spec:
            raise self._spec["earnings_error"]
        for message in self._spec.get("earnings_logged_errors", ()):
            logging.getLogger("yfinance").error(message)
        if "earnings" not in self._spec:
            # What yfinance does when Yahoo's page has no earnings table.
            logging.getLogger("yfinance").error(f"{self.symbol}: No earnings dates found, symbol may be delisted")
            return None
        earnings = self._spec["earnings"]
        return earnings() if callable(earnings) else earnings

    @property
    def calendar(self):
        self._log.append((self.symbol, "calendar", None))
        if "calendar_error" in self._spec:
            raise self._spec["calendar_error"]
        calendar = self._spec.get("calendar", {})
        # A callable builds the calendar when it is read, as yfinance does.
        return calendar() if callable(calendar) else calendar


class _FakeYF:
    def __init__(self, specs):
        self.specs = specs
        self.log = []
        self.constructed = []

    def Ticker(self, symbol):  # noqa: N802 - mirrors yfinance
        self.constructed.append(symbol)
        return _FakeTicker(symbol, self.specs.get(symbol, {}), self.log)


US_SHARE = {
    "metadata": {"instrumentType": "EQUITY", "currency": "USD"},
    "calendar": {
        "Dividend Date": datetime.date(2026, 12, 10),
        "Ex-Dividend Date": datetime.date(2026, 11, 28),
        "Earnings Date": [datetime.date(2027, 1, 28)],
        "Earnings High": 1.5,
    },
    "dividends": _FakeSeries([
        (day("2025-08-01"), 0.24),
        (day("2026-02-05"), 0.25),
        (day("2026-05-07"), 0.25),
        (day("2026-08-06"), 0.26),
    ]),
}

LONDON_SHARE = {
    "metadata": {"instrumentType": "EQUITY", "currency": "GBp"},
    "calendar": {"Ex-Dividend Date": datetime.date(2026, 9, 18), "Earnings Date": [datetime.date(2026, 7, 30)]},
    "dividends": _FakeSeries([(day("2026-03-12"), 12.5), (day("2026-09-18"), 6.4)]),
}

LONDON_FUND = {
    "metadata": {"instrumentType": "ETF", "currency": "GBP"},
    "calendar": {},
    "dividends": _FakeSeries([(day("2026-01-15"), 0.31), (day("2026-07-16"), 0.29)]),
}


class InstrumentEventsTestCase(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.module.REQUEST_SPACING_SECONDS = 0
        self.sleeps = []

    def run_symbols(self, specs, symbols, **kwargs):
        fake = _FakeYF(specs)
        self.module.yf = fake
        self.module.YFINANCE_AVAILABLE = True
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            envelopes = self.module.fetch_all(symbols, now=NOW, sleep=self.sleeps.append, **kwargs)
        self.stderr = stderr.getvalue()
        # Everything the app receives must be strict JSON.
        json.dumps(envelopes, allow_nan=False)
        return envelopes, fake


class ShapeTests(InstrumentEventsTestCase):
    def test_share_with_everything(self):
        (envelope,), fake = self.run_symbols({"ALPHA": US_SHARE}, ["ALPHA"])

        self.assertTrue(envelope["success"])
        self.assertEqual(envelope["symbol"], "ALPHA")
        events = envelope["events"]
        self.assertEqual(events["instrumentType"], "EQUITY")
        self.assertEqual(events["exDividendDate"], "2026-11-28")
        self.assertEqual(events["dividendPayDate"], "2026-12-10")
        self.assertEqual(events["earningsDate"], "2027-01-28")
        self.assertIsNone(events["earningsDateEnd"])
        self.assertEqual(events["dividendCurrency"], "USD")
        self.assertEqual(
            events["dividends"],
            [
                {"date": "2026-02-05", "amount": 0.25},
                {"date": "2026-05-07", "amount": 0.25},
                {"date": "2026-08-06", "amount": 0.26},
            ],
        )
        self.assertEqual(events["fetchedAt"], NOW.timestamp())
        # A bounded history request, never the whole of it.
        self.assertIn(("ALPHA", "dividends", "2y"), fake.log)

    def test_metadata_is_read_from_yfinances_own_mapping_not_only_a_dict(self):
        # yfinance 1.8 returns HistoryMetadata, a Mapping that is not a dict.
        # Reading only dicts threw away every symbol as "no data" (found by the
        # live check of 2026-11-25).
        metadata = _Metadata({"instrumentType": "ETF", "currency": "USD"})
        self.assertNotIsInstance(metadata, dict)
        spec = dict(US_SHARE, metadata=metadata)
        (envelope,), _ = self.run_symbols({"ALPHA": spec}, ["ALPHA"])

        self.assertTrue(envelope["success"], envelope)
        self.assertEqual(envelope["events"]["instrumentType"], "ETF")
        self.assertEqual(envelope["events"]["dividendCurrency"], "USD")

    def test_london_share_keeps_past_date_leaves_pay_date_null_and_converts_pence(self):
        (envelope,), _ = self.run_symbols({"BETA.L": LONDON_SHARE}, ["BETA.L"])

        events = envelope["events"]
        self.assertEqual(events["exDividendDate"], "2026-09-18", "A past date is returned as it is")
        self.assertIsNone(events["dividendPayDate"])
        self.assertEqual(events["earningsDate"], "2026-07-30")
        self.assertEqual(events["dividendCurrency"], "GBP")
        amounts = [dividend["amount"] for dividend in events["dividends"]]
        self.assertEqual(len(amounts), 2)
        self.assertAlmostEqual(amounts[0], 0.125)
        self.assertAlmostEqual(amounts[1], 0.064)

    def test_pounds_are_not_divided_again(self):
        (envelope,), _ = self.run_symbols({"GAMMA.L": LONDON_FUND}, ["GAMMA.L"])

        events = envelope["events"]
        self.assertEqual(events["dividendCurrency"], "GBP")
        self.assertEqual([dividend["amount"] for dividend in events["dividends"]], [0.31, 0.29])

    def test_missing_currency_falls_back_to_the_suffix_rule(self):
        spec = dict(LONDON_SHARE, metadata={"instrumentType": "EQUITY"})
        (london,), _ = self.run_symbols({"BETA.L": spec}, ["BETA.L"])
        us_spec = dict(US_SHARE, metadata={"instrumentType": "EQUITY"})
        (us,), _ = self.run_symbols({"ALPHA": us_spec}, ["ALPHA"])

        self.assertEqual(london["events"]["dividendCurrency"], "GBP")
        self.assertAlmostEqual(london["events"]["dividends"][0]["amount"], 0.125)
        self.assertIsNone(us["events"]["dividendCurrency"], "No currency is invented")
        self.assertEqual(us["events"]["dividends"][0]["amount"], 0.25)

    def test_fund_with_no_calendar(self):
        (envelope,), _ = self.run_symbols({"GAMMA.L": LONDON_FUND}, ["GAMMA.L"])

        self.assertTrue(envelope["success"])
        events = envelope["events"]
        self.assertEqual(events["instrumentType"], "ETF")
        for key in ("exDividendDate", "dividendPayDate", "earningsDate", "earningsDateEnd"):
            self.assertIsNone(events[key], key)
        self.assertEqual(len(events["dividends"]), 2)

    def test_a_calendar_that_is_a_mapping_but_not_a_dict_is_still_read(self):
        # The chart metadata became a read-only mapping once; the calendar may too.
        spec = dict(US_SHARE, calendar=_Metadata(US_SHARE["calendar"]))
        (envelope,), _ = self.run_symbols({"ALPHA": spec}, ["ALPHA"])

        self.assertTrue(envelope["success"])
        events = envelope["events"]
        self.assertEqual(events["exDividendDate"], "2026-11-28")
        self.assertEqual(events["dividendPayDate"], "2026-12-10")
        self.assertEqual(events["earningsDate"], "2027-01-28")

    def test_share_without_dividends_has_an_empty_list_and_no_currency(self):
        spec = {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "calendar": {}}
        (envelope,), _ = self.run_symbols({"DELTA": spec}, ["DELTA"])

        self.assertEqual(envelope["events"]["dividends"], [])
        self.assertIsNone(envelope["events"]["dividendCurrency"])

    def test_failed_chart_is_an_error_not_a_saved_null(self):
        # yfinance swallows a failed chart request: empty metadata, logged
        # only as "possibly delisted". The calendar may still answer.
        no_chart = dict(US_SHARE, metadata={}, dividends=_FakeSeries([]),
                        logged_errors=["$ALPHA: possibly delisted; no price data found"])
        no_dividends = dict(US_SHARE, dividends=None)
        envelopes, _ = self.run_symbols({"ALPHA": no_chart, "BETA": no_dividends}, ["ALPHA", "BETA"])

        self.assertEqual([envelope["success"] for envelope in envelopes], [False, False])
        self.assertTrue(all(envelope["error"]["error_code"] == "NO_DATA" for envelope in envelopes))

    def test_symbol_text_is_not_read_as_a_failure(self):
        spec = dict(US_SHARE, logged_errors=["$SSLX: possibly delisted; no price data found"])
        (envelope,), _ = self.run_symbols({"SSLX": spec}, ["SSLX"])

        self.assertTrue(envelope["success"])

    def test_real_pandas_dividend_shapes_when_pandas_is_installed(self):
        try:
            import pandas
        except ImportError:
            self.skipTest("pandas is not installed here")
        index = pandas.DatetimeIndex(["2026-03-12", "2026-09-18"], tz="Europe/London", name="Date")
        series = pandas.Series([12.5, 6.4], index=index, name="Dividends")
        frame = pandas.DataFrame({"Dividends": [12.5, 6.4], "currency": ["GBp", "GBp"]}, index=index)
        for shape in (series, frame):
            dividends, currency = self.module.recent_dividends("BETA.L", shape, "GBp", NOW.date())
            self.assertEqual(currency, "GBP")
            self.assertEqual([dividend["date"] for dividend in dividends], ["2026-03-12", "2026-09-18"])
            self.assertAlmostEqual(dividends[0]["amount"], 0.125)
        empty, none_currency = self.module.recent_dividends("BETA.L", pandas.Series(dtype=float), "GBp", NOW.date())
        self.assertEqual((empty, none_currency), ([], None))

    def test_dividends_with_their_own_currency(self):
        pence = dict(US_SHARE, metadata={"instrumentType": "EQUITY", "currency": "USD"},
                     dividends=_FakeFrame([(day("2026-06-01"), (25.0, "GBp"))]))
        mixed = dict(US_SHARE, dividends=_FakeFrame([
            (day("2026-03-01"), (0.2, "USD")),
            (day("2026-06-01"), (0.3, "EUR")),
        ]))
        (converted,), _ = self.run_symbols({"ALPHA": pence}, ["ALPHA"])
        (left_out,), _ = self.run_symbols({"ALPHA": mixed}, ["ALPHA"])

        self.assertEqual(converted["events"]["dividendCurrency"], "GBP")
        self.assertAlmostEqual(converted["events"]["dividends"][0]["amount"], 0.25)
        self.assertIsNone(left_out["events"]["dividends"], "Amounts in two currencies are not combined")
        self.assertIsNone(left_out["events"]["dividendCurrency"])

    def test_unusable_amounts_are_left_out_not_zeroed(self):
        spec = dict(US_SHARE, dividends=_FakeSeries([
            (day("2026-02-05"), float("nan")),
            (day("2026-03-05"), None),
            (day("2026-04-05"), 0.0),
            (day("2026-05-05"), float("inf")),
            (day("2026-06-05"), 0.3),
            (float("nan"), 0.4),
        ]))
        (envelope,), _ = self.run_symbols({"ALPHA": spec}, ["ALPHA"])

        self.assertEqual(envelope["events"]["dividends"], [{"date": "2026-06-05", "amount": 0.3}])


class TwelveMonthTests(InstrumentEventsTestCase):
    def test_boundary_is_one_calendar_year_inclusive_and_nothing_after_today(self):
        spec = dict(US_SHARE, dividends=_FakeSeries([
            (day("2025-11-19"), 0.1),
            (day("2025-11-20"), 0.2),
            (day("2026-11-20"), 0.3),
            (day("2026-11-21"), 0.4),
        ]))
        (envelope,), _ = self.run_symbols({"ALPHA": spec}, ["ALPHA"])

        self.assertEqual(
            [dividend["date"] for dividend in envelope["events"]["dividends"]],
            ["2025-11-20", "2026-11-20"],
        )

    def test_one_year_before_a_leap_day(self):
        self.assertEqual(self.module.one_year_before(datetime.date(2028, 2, 29)), datetime.date(2027, 2, 28))


class EarningsTests(InstrumentEventsTestCase):
    def test_range_single_and_repeated_dates(self):
        cases = {
            "RANGE": ([datetime.date(2027, 2, 4), datetime.date(2027, 1, 28)], ("2027-01-28", "2027-02-04")),
            "ONE": ([datetime.date(2027, 1, 28)], ("2027-01-28", None)),
            "SAME": ([datetime.date(2027, 1, 28), datetime.date(2027, 1, 28)], ("2027-01-28", None)),
            "BARE": (datetime.date(2027, 1, 28), ("2027-01-28", None)),
            "EMPTY": ([], (None, None)),
        }
        specs = {
            symbol: {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "calendar": {"Earnings Date": value}}
            for symbol, (value, _) in cases.items()
        }
        envelopes, _ = self.run_symbols(specs, list(cases))

        for envelope in envelopes:
            expected = cases[envelope["symbol"]][1]
            events = envelope["events"]
            self.assertEqual((events["earningsDate"], events["earningsDateEnd"]), expected, envelope["symbol"])


class TimeZoneTests(InstrumentEventsTestCase):
    @unittest.skipUnless(hasattr(time, "tzset"), "needs time.tzset")
    def test_calendar_dates_are_read_in_utc_and_the_zone_is_put_back(self):
        # yfinance makes its calendar dates with datetime.fromtimestamp, in
        # the process's own zone. Midnight UTC on 28 November is still the
        # 27th in Los Angeles.
        midnight_utc = datetime.datetime(2026, 11, 28, tzinfo=UTC).timestamp()

        def calendar():
            return {"Ex-Dividend Date": datetime.datetime.fromtimestamp(midnight_utc).date()}

        spec = dict(US_SHARE, calendar=calendar)
        previous = os.environ.get("TZ")
        os.environ["TZ"] = "America/Los_Angeles"
        time.tzset()
        try:
            self.assertEqual(calendar()["Ex-Dividend Date"], datetime.date(2026, 11, 27))
            envelopes, _ = self.run_symbols({"ALPHA": spec}, ["ALPHA"])
            self.assertEqual(envelopes[0]["events"]["exDividendDate"], "2026-11-28")
            self.assertEqual(os.environ.get("TZ"), "America/Los_Angeles")
            self.assertEqual(calendar()["Ex-Dividend Date"], datetime.date(2026, 11, 27))
        finally:
            if previous is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = previous
            time.tzset()


class _NaTLike:
    """Behaves like pandas.NaT where it matters: unequal to itself, a datetime-ish."""

    def __ne__(self, other):
        return True

    def __eq__(self, other):
        return False

    def date(self):
        raise ValueError("NaT has no date")

    __hash__ = object.__hash__


class OddValueTests(InstrumentEventsTestCase):
    def test_iso_date_handles_every_shape_yahoo_uses(self):
        plus_five = datetime.timezone(datetime.timedelta(hours=5))
        cases = [
            (None, None),
            (float("nan"), None),
            (_NaTLike(), None),
            ([], None),
            ("", None),
            ("NaT", None),
            ("not a date", None),
            (True, None),
            (datetime.date(2026, 11, 2), "2026-11-02"),
            (datetime.datetime(2026, 11, 2, 9, 30), "2026-11-02"),
            (datetime.datetime(2026, 11, 2, 23, 30, tzinfo=plus_five), "2026-11-02"),
            (datetime.datetime(2026, 11, 2, 0, 30, tzinfo=UTC), "2026-11-02"),
            ("2026-11-02", "2026-11-02"),
            ("2026-11-02T08:00:00Z", "2026-11-02"),
            (1_793_577_600, "2026-11-02"),
            (float("inf"), None),
        ]
        for value, expected in cases:
            self.assertEqual(self.module.first_date(value), expected, repr(value))

    def test_lists_give_their_first_usable_date(self):
        self.assertEqual(self.module.first_date([None, float("nan"), datetime.date(2026, 11, 2)]), "2026-11-02")
        self.assertIsNone(self.module.first_date([None, _NaTLike()]))

    def test_real_pandas_values_when_pandas_is_installed(self):
        try:
            import pandas
        except ImportError:
            self.skipTest("pandas is not installed here")
        self.assertIsNone(self.module.first_date(pandas.NaT))
        self.assertIsNone(self.module.first_date(float("nan")))
        zoned = pandas.Timestamp("2026-11-02 23:30", tz="Asia/Karachi")
        self.assertEqual(self.module.first_date(zoned), "2026-11-02")
        self.assertEqual(self.module.first_date(pandas.Timestamp("2026-11-02")), "2026-11-02")

    def test_odd_calendar_values_become_null(self):
        spec = {
            "metadata": {"instrumentType": "EQUITY", "currency": "USD"},
            "calendar": {
                "Ex-Dividend Date": _NaTLike(),
                "Dividend Date": float("nan"),
                "Earnings Date": [None],
            },
            "dividends": _FakeSeries([(day("2026-06-05"), 0.3)]),
        }
        (envelope,), _ = self.run_symbols({"ALPHA": spec}, ["ALPHA"])

        events = envelope["events"]
        self.assertTrue(envelope["success"])
        for key in ("exDividendDate", "dividendPayDate", "earningsDate", "earningsDateEnd"):
            self.assertIsNone(events[key], key)


class FailureTests(InstrumentEventsTestCase):
    def test_unknown_symbol_is_an_error_and_others_still_answer(self):
        envelopes, _ = self.run_symbols({"ALPHA": US_SHARE, "NOSUCH": {}}, ["ALPHA", "NOSUCH"])

        self.assertTrue(envelopes[0]["success"])
        self.assertFalse(envelopes[1]["success"])
        self.assertEqual(envelopes[1]["symbol"], "NOSUCH")
        self.assertEqual(envelopes[1]["error"]["error_code"], "NO_DATA")

    def test_exception_for_one_symbol_does_not_fail_the_others(self):
        broken = dict(US_SHARE, calendar_error=KeyError("quoteSummary"))
        envelopes, _ = self.run_symbols(
            {"ALPHA": US_SHARE, "BROKEN": broken, "GAMMA.L": LONDON_FUND},
            ["ALPHA", "BROKEN", "GAMMA.L"],
        )

        self.assertEqual([envelope["success"] for envelope in envelopes], [True, False, True])
        self.assertEqual(envelopes[1]["error"]["error_code"], "PROVIDER_ERROR")

    def test_raised_network_failure_is_reported_as_such(self):
        broken = dict(US_SHARE, calendar_error=ConnectionError("Connection refused"))
        (envelope,), _ = self.run_symbols({"ALPHA": broken}, ["ALPHA"])

        self.assertEqual(envelope["error"]["error_code"], "NETWORK_ERROR")

    def test_failure_yfinance_only_logged_is_not_an_empty_success(self):
        swallowed = dict(US_SHARE, logged_errors=["Failed to get ticker 'ALPHA' reason: Connection timed out"])
        harmless = dict(US_SHARE, logged_errors=["$ALPHA: possibly delisted; no price data found"])
        (timed_out,), _ = self.run_symbols({"ALPHA": swallowed}, ["ALPHA"])
        (fine,), _ = self.run_symbols({"ALPHA": harmless}, ["ALPHA"])

        self.assertFalse(timed_out["success"])
        self.assertEqual(timed_out["error"]["error_code"], "TIMEOUT")
        self.assertTrue(fine["success"])
        self.assertIn("possibly delisted", self.stderr)
        self.assertEqual(logging.getLogger("yfinance").handlers, [], "The capture handler is removed again")

    def test_rate_limit_is_its_own_error_and_stops_further_requests(self):
        limited = dict(US_SHARE, dividends_error=YFRateLimitError())
        envelopes, fake = self.run_symbols(
            {"ALPHA": US_SHARE, "LIMITED": limited, "GAMMA.L": LONDON_FUND},
            ["ALPHA", "LIMITED", "GAMMA.L"],
        )

        self.assertTrue(envelopes[0]["success"])
        self.assertEqual(envelopes[1]["error"]["error_code"], "RATE_LIMIT")
        self.assertEqual(envelopes[2]["error"]["error_code"], "RATE_LIMIT")
        self.assertEqual(fake.constructed, ["ALPHA", "LIMITED"], "Nothing is asked after a rate-limit answer")

    def test_rate_limit_message_without_the_exception_type(self):
        limited = dict(US_SHARE, calendar_error=RuntimeError("HTTP Error 429: Too Many Requests"))
        (envelope,), _ = self.run_symbols({"ALPHA": limited}, ["ALPHA"])

        self.assertEqual(envelope["error"]["error_code"], "RATE_LIMIT")


class BatchTests(InstrumentEventsTestCase):
    def test_each_symbol_is_asked_for_once_with_spacing_between(self):
        envelopes, fake = self.run_symbols(
            {"ALPHA": US_SHARE, "GAMMA.L": LONDON_FUND}, ["ALPHA", "GAMMA.L", "ALPHA"]
        )

        self.assertEqual([envelope["symbol"] for envelope in envelopes], ["ALPHA", "GAMMA.L", "ALPHA"])
        self.assertEqual(fake.constructed, ["ALPHA", "GAMMA.L"])
        self.assertEqual(len(self.sleeps), 1, "Spacing between requests, none before the first")

    def test_symbols_past_the_time_budget_report_a_timeout(self):
        readings = iter([100.0, 100.0, 200.0])
        envelopes, fake = self.run_symbols(
            {"ALPHA": US_SHARE, "GAMMA.L": LONDON_FUND}, ["ALPHA", "GAMMA.L"],
            time_budget_seconds=30, clock=lambda: next(readings),
        )

        self.assertTrue(envelopes[0]["success"])
        self.assertEqual(envelopes[1]["error"]["error_code"], "TIMEOUT")
        self.assertEqual(fake.constructed, ["ALPHA"])


# Twelve months up to NOW (2026-11-20): 2025-11-20 to 2026-11-20 inclusive.
US_EARNINGS = _FakeEarningsFrame([
    (report("2027-01-28", zone=EASTERN_WINTER), (1.61, NAN, NAN)),   # upcoming: left out
    (report("2026-10-30"), (1.48, 1.52, 2.7)),                       # both figures and the surprise
    (report("2026-07-22"), (NAN, 1.54, NAN)),                        # only the reported figure
    (report("2026-05-06", hour=8), (NAN, NAN, NAN)),                  # no figures
    (report("2026-02-06", hour=20, zone=EASTERN_WINTER), (2.09, 2.42, -10.88)),  # evening: still 6 February
    (report("2025-11-20", zone=EASTERN_WINTER), (0.9, 0.95, 5.56)),   # exactly a year back: kept
    (report("2025-11-19", zone=EASTERN_WINTER), (0.9, 0.95, 5.56)),   # a day more: left out
])


class EarningsHistoryTests(InstrumentEventsTestCase):
    def run_history(self, specs, symbols, **kwargs):
        return self.run_symbols(specs, symbols, mode="earningsHistory", **kwargs)

    def test_each_shape_of_figures_exactly_as_given(self):
        envelopes, fake = self.run_history(
            {"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": US_EARNINGS}}, ["ALPHA"])

        envelope = envelopes[0]
        self.assertTrue(envelope["success"])
        self.assertNotIn("events", envelope, "a history answer has its own key")
        history = envelope["earningsHistory"]
        self.assertEqual(history["symbol"], "ALPHA")
        self.assertEqual(history["epsCurrency"], "USD")
        self.assertEqual(history["fetchedAt"], NOW.timestamp())
        self.assertEqual(history["earnings"], [
            {"date": "2025-11-20", "reportedEPS": 0.95, "estimatedEPS": 0.9, "surprisePercent": 5.56},
            {"date": "2026-02-06", "reportedEPS": 2.42, "estimatedEPS": 2.09, "surprisePercent": -10.88},
            {"date": "2026-05-06", "reportedEPS": None, "estimatedEPS": None, "surprisePercent": None},
            {"date": "2026-07-22", "reportedEPS": 1.54, "estimatedEPS": None, "surprisePercent": None},
            {"date": "2026-10-30", "reportedEPS": 1.52, "estimatedEPS": 1.48, "surprisePercent": 2.7},
        ])
        self.assertIn(("ALPHA", "earnings_dates", 12), fake.log)
        self.assertNotIn(("ALPHA", "dividends", "2y"), fake.log, "the history mode asks for nothing else")
        self.assertNotIn(("ALPHA", "calendar", None), fake.log)

    def test_pence_quotes_keep_the_dates_and_drop_the_eps_figures(self):
        for currency in ("GBp", "GBX", "ILA", "ZAc"):
            with self.subTest(currency=currency):
                envelopes, _ = self.run_history(
                    {"BETA.L": {"metadata": {"instrumentType": "EQUITY", "currency": currency}, "earnings": US_EARNINGS}}, ["BETA.L"])
                history = envelopes[0]["earningsHistory"]
                self.assertIsNone(history["epsCurrency"])
                self.assertEqual([row["date"] for row in history["earnings"]],
                                 ["2025-11-20", "2026-02-06", "2026-05-06", "2026-07-22", "2026-10-30"])
                self.assertTrue(all(row["reportedEPS"] is None and row["estimatedEPS"] is None
                                    for row in history["earnings"]))
                # The surprise is a percentage, in no currency: kept as given.
                self.assertEqual(history["earnings"][-1]["surprisePercent"], 2.7)
                self.assertIn("EPS figures left out", self.stderr)

    def test_unknown_currency_drops_the_figures_and_never_falls_back_to_the_suffix(self):
        for metadata in ({"instrumentType": "EQUITY"}, {"instrumentType": "EQUITY", "currency": "  "}):
            with self.subTest(metadata=metadata):
                envelopes, _ = self.run_history(
                    {"GAMMA": {"metadata": metadata, "earnings": US_EARNINGS}}, ["GAMMA"])
                history = envelopes[0]["earningsHistory"]
                self.assertIsNone(history["epsCurrency"])
                self.assertTrue(all(row["reportedEPS"] is None for row in history["earnings"]))

    def test_pounds_and_other_currencies_are_given_as_they_are(self):
        envelopes, _ = self.run_history({
            "DELTA.L": {"metadata": {"instrumentType": "EQUITY", "currency": "GBP"}, "earnings": US_EARNINGS},
            "EPS.AS": {"metadata": {"instrumentType": "EQUITY", "currency": "EUR"}, "earnings": US_EARNINGS},
        }, ["DELTA.L", "EPS.AS"])
        for envelope, currency in zip(envelopes, ("GBP", "EUR")):
            history = envelope["earningsHistory"]
            self.assertEqual(history["epsCurrency"], currency)
            self.assertEqual(history["earnings"][-1]["reportedEPS"], 1.52, "never divided")

    def test_the_chart_is_asked_only_when_a_report_falls_near_the_year(self):
        old_only = _FakeEarningsFrame([(report("2024-05-01"), (1.0, 1.1, 10.0)),
                                       (report("2027-02-01"), (1.2, NAN, NAN))])
        envelopes, fake = self.run_history(
            {"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": old_only}}, ["ALPHA"])
        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"], [])
        self.assertNotIn(("ALPHA", "metadata", None), fake.log, "no chart request when nothing falls in the year")

        # A report without figures still needs the chart, for the exchange's zone.
        no_figures = _FakeEarningsFrame([(report("2026-08-01"), (NAN, NAN, NAN))])
        envelopes, fake = self.run_history(
            {"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD",
                                    "exchangeTimezoneName": "America/New_York"}, "earnings": no_figures}}, ["ALPHA"])
        history = envelopes[0]["earningsHistory"]
        self.assertEqual(history["earnings"],
                         [{"date": "2026-08-01", "reportedEPS": None, "estimatedEPS": None, "surprisePercent": None}])
        self.assertIsNone(history["epsCurrency"], "no figures, so no currency")
        self.assertEqual(fake.log.count(("ALPHA", "history", "5d")), 1, "one chart request")

    def test_dates_are_taken_in_the_exchanges_zone(self):
        # The shapes the live check of 2026-11-26 found: Yahoo stamps a London
        # report in New York time, often the evening before.
        london = _FakeEarningsFrame([
            (report("2026-05-04", hour=22), (0.42, 0.44, 3.72)),            # 03:00 in London on 5 May
            (report("2026-02-24", hour=19, zone=EASTERN_WINTER), (0.33, 0.37, 11.95)),  # midnight in London
            (report("2026-10-27", hour=0), (0.44, 0.42, -3.88)),            # 05:00 in London, the same day
            (report("2025-11-19", hour=21, zone=EASTERN_WINTER), (0.3, 0.3, 0.0)),  # 20 Nov in London: the first day of the year
        ])
        metadata = {"instrumentType": "EQUITY", "currency": "GBp", "exchangeTimezoneName": "Europe/London"}
        envelopes, _ = self.run_history({"HSBC.L": {"metadata": metadata, "earnings": london}}, ["HSBC.L"])
        self.assertEqual([row["date"] for row in envelopes[0]["earningsHistory"]["earnings"]],
                         ["2025-11-20", "2026-02-25", "2026-05-05", "2026-10-27"])

        # A New York share keeps its New York dates, evening ones included.
        new_york = _FakeEarningsFrame([(report("2026-10-30", hour=21), (1.48, 1.52, 2.7))])
        envelopes, _ = self.run_history({"ALPHA": {"metadata": {
            "instrumentType": "EQUITY", "currency": "USD", "exchangeTimezoneName": "America/New_York"},
            "earnings": new_york}}, ["ALPHA"])
        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"][0]["date"], "2026-10-30")

    def test_without_a_known_zone_the_dates_are_taken_as_stamped(self):
        frame = _FakeEarningsFrame([(report("2026-05-04", hour=22), (0.42, 0.44, 3.72))])
        for zone in (None, "", "Not/AZone"):
            with self.subTest(zone=zone):
                metadata = {"instrumentType": "EQUITY", "currency": "USD"}
                if zone is not None:
                    metadata["exchangeTimezoneName"] = zone
                envelopes, _ = self.run_history({"ALPHA": {"metadata": metadata, "earnings": frame}}, ["ALPHA"])
                self.assertEqual(envelopes[0]["earningsHistory"]["earnings"][0]["date"], "2026-05-04")
                self.assertIn("no exchange time zone", self.stderr)

    def test_an_empty_history_is_an_answer_and_no_page_is_no_data(self):
        old_only = _FakeEarningsFrame([(report("2024-05-01"), (1.0, 1.1, 10.0))])
        envelopes, _ = self.run_history({
            "ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": _FakeEarningsFrame([])},
            "BETA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": old_only},
            "FUND.L": {"metadata": {"instrumentType": "EQUITY", "currency": "GBP"}},
        }, ["ALPHA", "BETA", "FUND.L"])

        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"], [])
        self.assertEqual(envelopes[1]["earningsHistory"]["earnings"], [])
        self.assertFalse(envelopes[2]["success"])
        self.assertEqual(envelopes[2]["error"]["error_code"], "NO_DATA",
                         "no earnings page is no data, not a failure")

    def test_a_day_listed_twice_keeps_the_row_with_more_figures(self):
        twice = _FakeEarningsFrame([
            (report("2026-10-30", hour=8), (NAN, NAN, NAN)),
            (report("2026-10-30"), (1.48, 1.52, 2.7)),
            (report("2026-10-30", hour=17), (1.48, NAN, NAN)),
        ])
        envelopes, _ = self.run_history({"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": twice}}, ["ALPHA"])
        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"],
                         [{"date": "2026-10-30", "reportedEPS": 1.52, "estimatedEPS": 1.48, "surprisePercent": 2.7}])

    def test_odd_values_become_null_and_strings_are_read_as_numbers(self):
        odd = _FakeEarningsFrame([
            (report("2026-10-30"), ("1.48", "+1.52", "2.70")),
            (report("2026-07-22"), (float("inf"), "n/a", None)),
            (None, (1.0, 1.0, 1.0)),
            (_NaTLike(), (1.0, 1.0, 1.0)),
        ])
        envelopes, _ = self.run_history({"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": odd}}, ["ALPHA"])
        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"], [
            {"date": "2026-07-22", "reportedEPS": None, "estimatedEPS": None, "surprisePercent": None},
            {"date": "2026-10-30", "reportedEPS": 1.52, "estimatedEPS": 1.48, "surprisePercent": 2.7},
        ])

    def test_a_page_without_one_of_the_columns_still_reads(self):
        frame = _FakeEarningsFrame([(report("2026-10-30"), (1.52, 3.0))], columns=("Reported EPS", "Surprise (%)"))
        envelopes, _ = self.run_history({"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": frame}}, ["ALPHA"])
        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"],
                         [{"date": "2026-10-30", "reportedEPS": 1.52, "estimatedEPS": None, "surprisePercent": 3.0}])

    def test_real_pandas_shape_when_pandas_is_installed(self):
        try:
            import pandas
        except ImportError:
            self.skipTest("pandas is not installed")
        # The shape yfinance 1.8.0's scrape returns (base.py, _get_earnings_dates_using_scrape).
        index = pandas.DatetimeIndex([
            pandas.Timestamp("2027-01-28 16:00").tz_localize("America/New_York"),
            pandas.Timestamp("2026-10-30 16:00").tz_localize("America/New_York"),
            pandas.Timestamp("2026-07-22 16:00").tz_localize("America/New_York"),
        ], name="Earnings Date")
        frame = pandas.DataFrame({"EPS Estimate": [1.61, 1.48, NAN], "Reported EPS": [NAN, 1.52, 1.54],
                                  "Surprise(%)": [NAN, 2.7, NAN]}, index=index)
        envelopes, _ = self.run_history({"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": frame}}, ["ALPHA"])
        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"], [
            {"date": "2026-07-22", "reportedEPS": 1.54, "estimatedEPS": None, "surprisePercent": None},
            {"date": "2026-10-30", "reportedEPS": 1.52, "estimatedEPS": 1.48, "surprisePercent": 2.7},
        ])
        envelopes, _ = self.run_history({"ALPHA": {"earnings": frame.iloc[0:0]}}, ["ALPHA"])
        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"], [])

        # A London report stamped the evening before in New York, as pandas gives it.
        london = pandas.DataFrame({"EPS Estimate": [0.42], "Reported EPS": [0.44], "Surprise(%)": [3.72]},
                                  index=pandas.DatetimeIndex([pandas.Timestamp("2026-05-04 22:00").tz_localize(
                                      "America/New_York")], name="Earnings Date"))
        envelopes, _ = self.run_history({"HSBC.L": {"metadata": {
            "instrumentType": "EQUITY", "currency": "GBp", "exchangeTimezoneName": "Europe/London"},
            "earnings": london}}, ["HSBC.L"])
        self.assertEqual(envelopes[0]["earningsHistory"]["earnings"][0]["date"], "2026-05-05")

    def test_yfinances_page_cache_is_cleared_once_per_history_run_only(self):
        cleared = []
        with mock.patch.object(self.module, "forget_cached_pages", lambda: cleared.append(True)):
            self.run_history({"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": US_EARNINGS},
                              "BETA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": US_EARNINGS}}, ["ALPHA", "BETA"])
            self.assertEqual(cleared, [True])
            self.run_symbols({"ALPHA": US_SHARE}, ["ALPHA"])
            self.assertEqual(cleared, [True], "the events mode reads no cached page")

    def test_forget_cached_pages_clears_yfinances_lru_cache(self):
        cleared = []
        cache_get = mock.Mock()
        cache_get.cache_clear = lambda: cleared.append(True)
        fake_data = mock.Mock(YfData=mock.Mock(cache_get=cache_get))
        with mock.patch.dict(sys.modules, {"yfinance": mock.Mock(), "yfinance.data": fake_data}):
            self.module.forget_cached_pages()
        self.assertEqual(cleared, [True])
        # Without yfinance it says so on stderr and carries on.
        with mock.patch.dict(sys.modules, {"yfinance.data": None}), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.module.forget_cached_pages()
        self.assertIn("Could not clear", stderr.getvalue())


class EarningsHistoryFailureTests(InstrumentEventsTestCase):
    def run_history(self, specs, symbols, **kwargs):
        return self.run_symbols(specs, symbols, mode="earningsHistory", **kwargs)

    def test_each_failure_class(self):
        envelopes, _ = self.run_history({
            "NET": {"earnings_error": ConnectionError("Max retries exceeded")},
            "SLOW": {"earnings_logged_errors": ["Read timed out. (read timeout=30)"], "earnings": None},
            "ODD": {"earnings_error": KeyError("table")},
            "FINE": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": US_EARNINGS},
        }, ["NET", "SLOW", "ODD", "FINE"])
        codes = [envelope.get("error", {}).get("error_code") for envelope in envelopes]
        self.assertEqual(codes, ["NETWORK_ERROR", "TIMEOUT", "PROVIDER_ERROR", None])
        self.assertIn("KeyError", envelopes[2]["error"]["message"])
        self.assertTrue(envelopes[3]["success"], "one symbol's failure does not fail the others")

    def test_a_failure_yfinance_only_logged_is_not_an_empty_history(self):
        envelopes, _ = self.run_history(
            {"ALPHA": {"earnings_logged_errors": ["Failed to resolve 'finance.yahoo.com' (could not resolve host)"]}},
            ["ALPHA"])
        self.assertEqual(envelopes[0]["error"]["error_code"], "NETWORK_ERROR")

    def test_a_chart_that_does_not_answer_fails_the_symbol_instead_of_dropping_its_figures(self):
        envelopes, _ = self.run_history({
            "EMPTY": {"metadata": {}, "earnings": US_EARNINGS},
            "LIMITED": {"chart_error": YFRateLimitError(), "earnings": US_EARNINGS},
            "LATER": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": US_EARNINGS},
        }, ["EMPTY", "LIMITED", "LATER"])
        self.assertEqual(envelopes[0]["error"]["error_code"], "PROVIDER_ERROR", "nothing saved with its figures dropped")
        self.assertEqual(envelopes[1]["error"]["error_code"], "RATE_LIMIT", "a rate-limited chart pauses the app")
        self.assertEqual(envelopes[2]["error"]["error_code"], "RATE_LIMIT", "and nothing more is asked")

    def test_rate_limit_stops_the_run_and_marks_the_rest(self):
        envelopes, fake = self.run_history({
            "ALPHA": {"earnings_error": YFRateLimitError()},
            "BETA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": US_EARNINGS},
        }, ["ALPHA", "BETA"])
        self.assertEqual([envelope["error"]["error_code"] for envelope in envelopes], ["RATE_LIMIT", "RATE_LIMIT"])
        self.assertNotIn("BETA", fake.constructed, "nothing more is asked after a rate limit")

    def test_the_deadline_and_the_batch_budget_still_apply(self):
        readings = iter([100.0, 100.0, 200.0])
        envelopes, fake = self.run_history(
            {"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": US_EARNINGS}, "BETA": {}},
            ["ALPHA", "BETA"], time_budget_seconds=30, clock=lambda: next(readings))
        self.assertTrue(envelopes[0]["success"])
        self.assertEqual(envelopes[1]["error"]["error_code"], "TIMEOUT")
        self.assertEqual(fake.constructed, ["ALPHA"])

        with mock.patch.object(self.module, "SYMBOL_DEADLINE_SECONDS", 0.05), \
                mock.patch.object(self.module, "fetch_earnings_history", lambda *args: time.sleep(1)):
            envelopes, _ = self.run_history({}, ["SLOW"])
        self.assertEqual(envelopes[0]["error"]["error_code"], "TIMEOUT")

    def test_an_unknown_mode_is_refused(self):
        with self.assertRaises(ValueError):
            self.module.fetch_all(["ALPHA"], now=NOW, mode="dividends")


class CommandLineTests(InstrumentEventsTestCase):
    def run_main(self, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        code = 0
        with mock.patch.object(sys, "argv", ["get_instrument_events.py"] + argv), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                self.module.main()
            except SystemExit as error:
                code = error.code
        return code, stdout.getvalue()

    def test_answers_every_symbol_as_one_json_array(self):
        self.module.yf = _FakeYF({"ALPHA": US_SHARE, "BETA.L": LONDON_SHARE})
        self.module.YFINANCE_AVAILABLE = True

        code, output = self.run_main(["--json", "--deadline-seconds", "60", "alpha", "BETA.L"])

        self.assertEqual(code, 0)
        envelopes = json.loads(output)
        self.assertEqual([envelope["symbol"] for envelope in envelopes], ["ALPHA", "BETA.L"])
        self.assertTrue(all(envelope["success"] for envelope in envelopes))
        self.assertEqual(output.count("\n"), 1, "One line of JSON on stdout")

    def test_earnings_history_flag_answers_with_the_history_envelope(self):
        self.module.yf = _FakeYF({"ALPHA": {"metadata": {"instrumentType": "EQUITY", "currency": "USD"}, "earnings": US_EARNINGS}})
        self.module.YFINANCE_AVAILABLE = True

        with mock.patch.object(self.module, "forget_cached_pages", lambda: None):
            code, output = self.run_main(["--json", "--earnings-history", "--deadline-seconds", "60", "ALPHA", "NONE"])

        self.assertEqual(code, 0)
        envelopes = json.loads(output)
        self.assertEqual(envelopes[0]["earningsHistory"]["epsCurrency"], "USD")
        self.assertEqual(envelopes[1]["error"]["error_code"], "NO_DATA")
        self.assertEqual(output.count("\n"), 1)

    def test_no_symbols_is_a_structured_error(self):
        code, output = self.run_main([])

        self.assertEqual(code, 1)
        error = json.loads(output)
        self.assertTrue(error["error"])
        self.assertEqual(error["error_code"], "INVALID_REQUEST")

    def test_missing_yfinance_is_a_structured_error(self):
        self.module.yf = None
        self.module.YFINANCE_AVAILABLE = False

        code, output = self.run_main(["ALPHA"])

        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output)["error_code"], "PROVIDER_UNAVAILABLE")

    def test_loading_the_script_leaves_the_import_path_as_it_was(self):
        before = list(sys.path)
        load_module()
        self.assertEqual(sys.path, before)


if __name__ == "__main__":
    unittest.main()
