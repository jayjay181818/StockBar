#!/usr/bin/env python3
import yfinance as yf
import sys

symbol = 'GOOG'
print(f'Testing {symbol}...')

try:
    ticker = yf.Ticker(symbol)
    info = ticker.info
    print(f'Current Price: {info.get("currentPrice", "N/A")}')
    print(f'Previous Close: {info.get("previousClose", "N/A")}')
    print(f'Currency: {info.get("currency", "N/A")}')
    print('Success!')
except Exception as e:
    print(f'Error: {e}') 