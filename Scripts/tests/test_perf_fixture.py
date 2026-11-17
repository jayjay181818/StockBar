"""The benchmark's synthetic store, built against a stand-in for the app's schema."""
import importlib.util
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('make_fixture', REPO / 'Scripts/perf/make_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

# The columns make_fixture.py writes, as Core Data names them.
SCHEMA = '''
CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
CREATE TABLE ZTRADEENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNAME, ZUNITSIZE,
    ZPOSITIONAVGCOST, ZCURRENCY, ZCOSTCURRENCY, ZSHOWINMENUBAR, ZISWATCHLISTONLY, ZLASTMODIFIED);
CREATE TABLE ZTRADINGINFOENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZSYMBOL, ZSHORTNAME,
    ZCURRENCY, ZCURRENTPRICE, ZPREVCLOSEPRICE, ZPREVIOUSCLOSE, ZMARKETSTATE, ZEXCHANGETIMEZONENAME,
    ZLASTUPDATETIME, ZREGULARMARKETTIME, ZPREMARKETTIME, ZPOSTMARKETTIME, ZLASTMODIFIED);
CREATE TABLE ZPORTFOLIOSNAPSHOTENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZTIMESTAMP,
    ZTOTALVALUE, ZTOTALCOST, ZTOTALGAINS, ZCURRENCY, ZCOMPOSITIONHASH, ZID);
CREATE TABLE ZPOSITIONSNAPSHOTENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
    ZPORTFOLIOSNAPSHOT, ZSYMBOL, ZCURRENCY, ZUNITS, ZPRICEATDATE, ZVALUEATDATE);
CREATE TABLE ZPRICESNAPSHOTENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZSYMBOL,
    ZTIMESTAMP, ZPRICE, ZPREVIOUSCLOSE, ZVOLUME, ZID);
CREATE TABLE ZOHLCSNAPSHOTENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZSYMBOL,
    ZTIMESTAMP, ZOPENPRICE, ZHIGHPRICE, ZLOWPRICE, ZCLOSEPRICE, ZVOLUME, ZID);
'''
ENTITIES = ('OHLCSnapshotEntity', 'PortfolioSnapshotEntity', 'PositionSnapshotEntity',
            'PriceSnapshotEntity', 'TradeEntity', 'TradingInfoEntity')


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = os.path.join(self.directory.name, 'StockbarDataModel.sqlite')
        self.db = sqlite3.connect(self.store)
        self.addCleanup(self.db.close)
        self.db.executescript(SCHEMA)
        self.db.executemany('INSERT INTO Z_PRIMARYKEY VALUES (?, ?, 0, 0)', enumerate(ENTITIES, 2))
        self.db.commit()

    def test_the_store_gets_the_documented_shape(self):
        counts = fixture.build(self.db, now=1_800_000_000)

        shape = fixture.SHAPE
        self.assertEqual(counts['ZTRADEENTITY'], len(fixture.HOLDINGS))
        self.assertEqual(counts['ZPORTFOLIOSNAPSHOTENTITY'], shape['portfolio_snapshots'])
        self.assertEqual(counts['ZPOSITIONSNAPSHOTENTITY'],
                         shape['portfolio_snapshots'] * shape['positions_per_snapshot'])
        self.assertEqual(counts['ZOHLCSNAPSHOTENTITY'], shape['candles'])
        # Core Data takes the next primary key from Z_MAX.
        for table, entity in (('ZPRICESNAPSHOTENTITY', 'PriceSnapshotEntity'), ('ZTRADEENTITY', 'TradeEntity')):
            highest = self.db.execute(f'SELECT MAX(Z_PK) FROM {table}').fetchone()[0]
            stored = self.db.execute('SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = ?', (entity,)).fetchone()[0]
            self.assertEqual(stored, highest)
        orphans = self.db.execute(
            'SELECT COUNT(*) FROM ZPOSITIONSNAPSHOTENTITY WHERE ZPORTFOLIOSNAPSHOT NOT IN '
            '(SELECT Z_PK FROM ZPORTFOLIOSNAPSHOTENTITY)').fetchone()[0]
        self.assertEqual(orphans, 0)

    def test_times_are_relative_to_now_in_core_data_seconds(self):
        now = 1_800_000_000
        fixture.build(self.db, now=now)

        newest, oldest = self.db.execute(
            'SELECT MAX(ZTIMESTAMP), MIN(ZTIMESTAMP) FROM ZPORTFOLIOSNAPSHOTENTITY').fetchone()
        self.assertLess(newest, now - fixture.REFERENCE_DATE)
        self.assertAlmostEqual(now - fixture.REFERENCE_DATE - oldest,
                               fixture.SHAPE['portfolio_days'] * fixture.DAY, delta=fixture.DAY)

    def test_the_same_seed_gives_the_same_prices(self):
        fixture.build(self.db, now=1_800_000_000)
        first = self.db.execute('SELECT SUM(ZPRICE) FROM ZPRICESNAPSHOTENTITY').fetchone()[0]
        self.db.close()
        os.remove(self.store)
        self.setUp()

        fixture.build(self.db, now=1_800_000_000)

        self.assertEqual(self.db.execute('SELECT SUM(ZPRICE) FROM ZPRICESNAPSHOTENTITY').fetchone()[0], first)

    def test_a_store_that_already_has_rows_is_refused(self):
        self.db.execute("INSERT INTO ZTRADEENTITY (Z_PK, ZNAME) VALUES (1, 'REAL')")

        with self.assertRaises(SystemExit):
            fixture.build(self.db, now=1_800_000_000)

        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM ZPRICESNAPSHOTENTITY').fetchone()[0], 0)

    def test_a_store_outside_the_temporary_directory_is_refused(self):
        with self.assertRaises(SystemExit):
            fixture.check_target(str(REPO / 'StockbarDataModel.sqlite'))
        self.assertEqual(fixture.check_target(self.store), os.path.realpath(self.store))


if __name__ == '__main__':
    unittest.main()
