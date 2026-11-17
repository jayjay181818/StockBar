#!/usr/bin/env python3
"""Fill an empty Stockbar store with synthetic history for benchmarking.

    python3 Scripts/perf/make_fixture.py <temp dir>/.../StockbarDataModel.sqlite

The store must be one the app has just created (`Stockbar
--acceptance-preflight`), so the schema always comes from the app's own data
model. The rows are synthetic: seeded random walks over public ticker symbols,
sized like a store that has been in use for a few months (see SHAPE). Times are
relative to now, so age-based thinning treats every run alike.

Refuses a store outside the temporary directory or one that already has rows,
so it cannot be pointed at a real portfolio.
"""
import os
import random
import sqlite3
import sys
import tempfile
import time
import uuid

# Core Data stores dates as seconds since 2001-01-01.
REFERENCE_DATE = 978307200
DAY = 86400.0

HOLDINGS = ["AAPL", "MSFT", "GOOGL", "AMZN", "NVDA", "META", "TSLA", "JPM", "V", "JNJ", "WMT"]
OTHER_SYMBOLS = ["PG", "XOM", "KO", "DIS", "NFLX", "ADBE", "CSCO", "INTC", "PEP", "^GSPC", "^FTSE"]
SHAPE = {
    "portfolio_snapshots": 7000,     # spread over portfolio_days
    "portfolio_days": 67,
    "positions_per_snapshot": 15,
    "recent_price_rows": 48000,      # the last 31 days, all symbols
    "older_price_rows": 22000,       # the five years before that
    "candles": 160,                  # daily, one symbol
}
TABLES = (
    "ZTRADEENTITY", "ZTRADINGINFOENTITY", "ZPORTFOLIOSNAPSHOTENTITY",
    "ZPOSITIONSNAPSHOTENTITY", "ZPRICESNAPSHOTENTITY", "ZOHLCSNAPSHOTENTITY",
)


def check_target(path):
    real = os.path.realpath(path)
    temp = os.path.realpath(tempfile.gettempdir())
    if os.path.commonpath([real, temp]) != temp:
        sys.exit(f"Refusing: {real} is not below the temporary directory {temp}.")
    if not os.path.isfile(real):
        sys.exit(f"No store at {real}; create it with the app's --acceptance-preflight first.")
    return real


def insert(db, table, entity, rows):
    """Insert dict rows, adding Core Data's bookkeeping columns."""
    start = db.execute(f"SELECT COALESCE(MAX(Z_PK), 0) FROM {table}").fetchone()[0]
    columns = ["Z_PK", "Z_ENT", "Z_OPT"] + list(rows[0])
    marks = ", ".join("?" for _ in columns)
    db.executemany(
        f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({marks})",
        ([start + index, entity, 1] + list(row.values()) for index, row in enumerate(rows, 1)),
    )
    db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_ENT = ?", (start + len(rows), entity))


def walk(rng, price):
    return max(1.0, price * (1 + rng.gauss(0, 0.004)))


def build(db, now):
    rng = random.Random(20261111)
    entities = dict(db.execute("SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY"))
    for table in TABLES:
        if db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]:
            sys.exit(f"Refusing: {table} already has rows.")
    new_id = lambda: uuid.UUID(int=rng.getrandbits(128)).bytes
    stamp = lambda unix: unix - REFERENCE_DATE
    symbols = HOLDINGS + OTHER_SYMBOLS
    prices = {symbol: rng.uniform(40, 400) for symbol in symbols}
    units = {symbol: float(rng.randint(5, 200)) for symbol in symbols}

    insert(db, "ZTRADEENTITY", entities["TradeEntity"], [{
        "ZNAME": symbol, "ZUNITSIZE": str(units[symbol]),
        "ZPOSITIONAVGCOST": f"{prices[symbol] * 0.9:.2f}",
        "ZCURRENCY": "USD", "ZCOSTCURRENCY": "USD",
        "ZSHOWINMENUBAR": 1, "ZISWATCHLISTONLY": 0, "ZLASTMODIFIED": stamp(now),
    } for symbol in HOLDINGS])
    insert(db, "ZTRADINGINFOENTITY", entities["TradingInfoEntity"], [{
        "ZSYMBOL": symbol, "ZSHORTNAME": f"Synthetic {symbol}", "ZCURRENCY": "USD",
        "ZCURRENTPRICE": prices[symbol], "ZPREVCLOSEPRICE": prices[symbol] * 0.99,
        "ZPREVIOUSCLOSE": prices[symbol] * 0.99, "ZMARKETSTATE": "CLOSED",
        "ZEXCHANGETIMEZONENAME": "America/New_York",
        "ZLASTUPDATETIME": int(now), "ZREGULARMARKETTIME": int(now),
        "ZPREMARKETTIME": 0, "ZPOSTMARKETTIME": 0, "ZLASTMODIFIED": stamp(now),
    } for symbol in HOLDINGS])

    held = symbols[:SHAPE["positions_per_snapshot"]]
    composition = ",".join(sorted(f"{symbol}:{units[symbol]}" for symbol in held))
    cost = sum(units[symbol] * prices[symbol] * 0.9 for symbol in held)
    count = SHAPE["portfolio_snapshots"]
    step = SHAPE["portfolio_days"] * DAY / count
    snapshots, positions = [], []
    for index in range(count):
        when = stamp(now - (count - index) * step)
        value = 0.0
        for symbol in held:
            prices[symbol] = walk(rng, prices[symbol])
            worth = units[symbol] * prices[symbol]
            value += worth
            positions.append({
                "ZPORTFOLIOSNAPSHOT": index + 1, "ZSYMBOL": symbol, "ZCURRENCY": "USD",
                "ZUNITS": units[symbol], "ZPRICEATDATE": prices[symbol], "ZVALUEATDATE": worth,
            })
        snapshots.append({
            "ZTIMESTAMP": when, "ZTOTALVALUE": value, "ZTOTALCOST": cost,
            "ZTOTALGAINS": value - cost, "ZCURRENCY": "USD",
            "ZCOMPOSITIONHASH": composition, "ZID": new_id(),
        })
    insert(db, "ZPORTFOLIOSNAPSHOTENTITY", entities["PortfolioSnapshotEntity"], snapshots)
    insert(db, "ZPOSITIONSNAPSHOTENTITY", entities["PositionSnapshotEntity"], positions)

    price_rows = []
    spans = ((SHAPE["older_price_rows"], 5 * 365 * DAY, 31 * DAY), (SHAPE["recent_price_rows"], 31 * DAY, 0))
    for total, oldest, newest in spans:
        per_symbol = total // len(symbols)
        for symbol in symbols:
            price = prices[symbol]
            for index in range(per_symbol):
                price = walk(rng, price)
                age = oldest - (oldest - newest) * index / per_symbol
                price_rows.append({
                    "ZSYMBOL": symbol, "ZTIMESTAMP": stamp(now - age), "ZPRICE": price,
                    "ZPREVIOUSCLOSE": price * 0.99, "ZVOLUME": rng.randint(1000, 5_000_000), "ZID": new_id(),
                })
    insert(db, "ZPRICESNAPSHOTENTITY", entities["PriceSnapshotEntity"], price_rows)

    candles, price = [], prices[HOLDINGS[0]]
    for index in range(SHAPE["candles"]):
        price = walk(rng, price)
        candles.append({
            "ZSYMBOL": HOLDINGS[0], "ZTIMESTAMP": stamp(now - (SHAPE["candles"] - index) * DAY),
            "ZOPENPRICE": price, "ZHIGHPRICE": price * 1.01, "ZLOWPRICE": price * 0.99,
            "ZCLOSEPRICE": price * 1.002, "ZVOLUME": rng.randint(1000, 5_000_000), "ZID": new_id(),
        })
    insert(db, "ZOHLCSNAPSHOTENTITY", entities["OHLCSnapshotEntity"], candles)
    return {table: db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] for table in TABLES}


def main(arguments):
    if len(arguments) != 1:
        sys.exit("Usage: " + __doc__.strip().splitlines()[2].strip())
    store = check_target(arguments[0])
    db = sqlite3.connect(store)
    try:
        with db:
            counts = build(db, time.time())
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        db.close()
    print(" ".join(f"{table}={count}" for table, count in counts.items()))


if __name__ == "__main__":
    main(sys.argv[1:])
