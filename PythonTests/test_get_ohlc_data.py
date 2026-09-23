import importlib.util
import os
import sys
import unittest


SCRIPT_PATH = os.path.abspath(
    os.path.join(
        os.path.dirname(__file__),
        "..",
        "Stockbar",
        "Resources",
        "get_ohlc_data.py",
    )
)


def load_module():
    spec = importlib.util.spec_from_file_location("stockbar_ohlc_test", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class _Row(dict):
    """Minimal stand-in for a pandas row indexed by column name."""


class _FakeHistory:
    def __init__(self, rows):
        self._rows = rows

    @property
    def empty(self):
        return not self._rows

    def iterrows(self):
        for index, row in self._rows:
            yield index, row


class _FakeIndex:
    def __init__(self, value):
        self._value = value

    def isoformat(self):
        return self._value


class _FakeFastInfo:
    def __init__(self, currency):
        self._currency = currency

    def get(self, key):
        return self._currency if key == "currency" else None


class _FakeTicker:
    def __init__(self, rows, currency):
        self._rows = rows
        self.fast_info = _FakeFastInfo(currency)

    def history(self, period=None, interval=None):
        return _FakeHistory(self._rows)


class OHLCCurrencyTests(unittest.TestCase):
    """Regression cover for the GBX -> GBP conversion.

    UK tickers are quoted in pence by the provider; every downstream consumer
    (charts, Core Data) assumes pounds, so the divide must happen here.
    """

    def setUp(self):
        self.module = load_module()

    def _fetch(self, symbol, currency, close=250.0):
        rows = [(
            _FakeIndex("2026-07-24T00:00:00+00:00"),
            _Row(Open=200.0, High=300.0, Low=100.0, Close=close, Volume=1234),
        )]
        self.module.yf = type("_FakeYF", (), {
            "Ticker": staticmethod(lambda s: _FakeTicker(rows, currency))
        })
        self.module.YFINANCE_AVAILABLE = True
        return self.module.fetch_ohlc_data(symbol)

    def test_uk_symbol_suffixes_are_recognised(self):
        self.assertTrue(self.module.is_uk_symbol("VOD.L"))
        self.assertTrue(self.module.is_uk_symbol("vod.l"))
        self.assertTrue(self.module.is_uk_symbol("BP.LON"))
        self.assertTrue(self.module.is_uk_symbol("AV.XC"))
        self.assertFalse(self.module.is_uk_symbol("AAPL"))

    def test_pence_detection_prefers_reported_currency(self):
        self.assertTrue(self.module.uses_pence_quotes("VOD.L", "GBp"))
        self.assertTrue(self.module.uses_pence_quotes("VOD.L", "GBX"))
        # Provider says pounds, so do not divide even for a .L ticker.
        self.assertFalse(self.module.uses_pence_quotes("VOD.L", "GBP"))
        self.assertFalse(self.module.uses_pence_quotes("AAPL", "USD"))

    def test_pence_detection_falls_back_to_suffix(self):
        self.assertTrue(self.module.uses_pence_quotes("VOD.L", None))
        self.assertTrue(self.module.uses_pence_quotes("BP.LON", None))
        self.assertFalse(self.module.uses_pence_quotes("AAPL", None))

    def test_uk_prices_are_converted_to_pounds(self):
        result = self._fetch("VOD.L", "GBp")
        point = result["data"][0]
        self.assertTrue(result["success"])
        self.assertAlmostEqual(point["open"], 2.0)
        self.assertAlmostEqual(point["high"], 3.0)
        self.assertAlmostEqual(point["low"], 1.0)
        self.assertAlmostEqual(point["close"], 2.5)
        self.assertEqual(result["currency"], "GBP")

    def test_volume_is_never_rescaled(self):
        result = self._fetch("VOD.L", "GBp")
        # Volume is a share count, not a price.
        self.assertEqual(result["data"][0]["volume"], 1234)

    def test_non_uk_prices_are_untouched(self):
        result = self._fetch("AAPL", "USD")
        point = result["data"][0]
        self.assertAlmostEqual(point["open"], 200.0)
        self.assertAlmostEqual(point["close"], 250.0)
        self.assertIsNone(result["currency"])

    def test_uk_symbol_already_quoted_in_pounds_is_not_divided(self):
        # Guards against double-conversion if the provider switches units.
        result = self._fetch("VOD.L", "GBP")
        self.assertAlmostEqual(result["data"][0]["close"], 250.0)


if __name__ == "__main__":
    unittest.main()
