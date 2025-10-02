#!/usr/bin/env python3
"""
Diagnostic script to test UNH stock data fetching directly
This helps identify if the issue is with the Python backend or the Swift app
"""

import sys
import yfinance as yf
from datetime import datetime

def test_unh_fetch():
    """Test fetching UNH data directly using yfinance"""
    print(f"🔍 Testing UNH data fetch at {datetime.now()}")
    print("=" * 60)

    try:
        # Fetch UNH ticker
        ticker = yf.Ticker("UNH")

        # Get current price
        info = ticker.info

        print(f"\n✅ Successfully fetched UNH data:")
        print(f"   Symbol: {info.get('symbol', 'N/A')}")
        print(f"   Current Price: ${info.get('currentPrice', info.get('regularMarketPrice', 'N/A'))}")
        print(f"   Previous Close: ${info.get('previousClose', 'N/A')}")
        print(f"   Market State: {info.get('marketState', 'N/A')}")
        print(f"   Currency: {info.get('currency', 'N/A')}")
        print(f"   Exchange: {info.get('exchange', 'N/A')}")

        # Try to get the most recent price from history
        hist = ticker.history(period="1d")
        if not hist.empty:
            latest = hist.iloc[-1]
            print(f"\n📊 Latest historical data:")
            print(f"   Date: {hist.index[-1]}")
            print(f"   Close: ${latest['Close']:.2f}")
            print(f"   Volume: {int(latest['Volume']):,}")

        return True

    except Exception as e:
        print(f"\n❌ ERROR fetching UNH: {str(e)}")
        print(f"   Error type: {type(e).__name__}")
        return False

def test_batch_fetch():
    """Test batch fetching with multiple symbols including UNH"""
    print(f"\n\n🔍 Testing batch fetch with UNH + others")
    print("=" * 60)

    symbols = ["AAPL", "UNH", "GOOGL", "MSFT"]

    try:
        for symbol in symbols:
            ticker = yf.Ticker(symbol)
            info = ticker.info
            price = info.get('currentPrice', info.get('regularMarketPrice', 'N/A'))
            print(f"   {symbol:6s}: ${price}")

        print("\n✅ Batch fetch successful")
        return True

    except Exception as e:
        print(f"\n❌ Batch fetch failed: {str(e)}")
        return False

def check_rate_limiting():
    """Check if we're being rate limited"""
    print(f"\n\n🔍 Checking for rate limiting")
    print("=" * 60)

    try:
        # Make multiple rapid requests
        for i in range(3):
            ticker = yf.Ticker("UNH")
            info = ticker.info
            price = info.get('currentPrice', info.get('regularMarketPrice', 'N/A'))
            print(f"   Request {i+1}: ${price}")

        print("\n✅ No rate limiting detected")
        return True

    except Exception as e:
        print(f"\n⚠️  Possible rate limiting: {str(e)}")
        return False

if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("UNH DIAGNOSTIC TEST SCRIPT")
    print("=" * 60)

    # Run all tests
    test1 = test_unh_fetch()
    test2 = test_batch_fetch()
    test3 = check_rate_limiting()

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"   Individual UNH fetch: {'✅ PASS' if test1 else '❌ FAIL'}")
    print(f"   Batch fetch test:     {'✅ PASS' if test2 else '❌ FAIL'}")
    print(f"   Rate limiting check:  {'✅ PASS' if test3 else '❌ FAIL'}")

    if all([test1, test2, test3]):
        print("\n✅ All tests passed - Python backend can fetch UNH successfully")
        print("   ➡️  Issue is likely in Swift app cache/refresh logic")
    else:
        print("\n❌ Some tests failed - Python backend has issues")
        print("   ➡️  Check yfinance installation and network connection")

    print("=" * 60 + "\n")

    sys.exit(0 if all([test1, test2, test3]) else 1)
