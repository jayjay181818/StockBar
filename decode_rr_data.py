#!/usr/bin/env python3
import json
from datetime import datetime

data = '[{"timestamp": 1748818800, "symbol": "RR.L", "price": 8.687999877929688, "previousClose": 8.715999755859375}, {"timestamp": 1748905200, "symbol": "RR.L", "price": 8.942000122070313, "previousClose": 8.687999877929688}, {"timestamp": 1748991600, "symbol": "RR.L", "price": 8.912000122070312, "previousClose": 8.942000122070313}, {"timestamp": 1749078000, "symbol": "RR.L", "price": 8.764000244140625, "previousClose": 8.912000122070312}, {"timestamp": 1749164400, "symbol": "RR.L", "price": 8.85, "previousClose": 8.764000244140625}]'

historical_data = json.loads(data)
print('📊 RR.L Historical Data (June 1-7, 2025):')
print('=' * 50)
for item in historical_data:
    date = datetime.fromtimestamp(item['timestamp']).strftime('%Y-%m-%d (%A)')
    price = item['price']
    prev_close = item['previousClose']
    print(f'{date}: £{price:.3f} (prev: £{prev_close:.3f})') 