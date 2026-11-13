"""What benchmark.sh leaves behind when a launch fails, with a stand-in for the app."""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_perf_fixture import ENTITIES, SCHEMA

REPO = Path(__file__).resolve().parents[2]

# Passes the preflight and makes a store the fixture can fill, as the app does.
# Launched normally, it logs one line and exits at once.
STAND_IN = '''#!{python}
import os, sqlite3, sys
root = os.environ['STOCKBAR_ACCEPTANCE_ROOT']
if sys.argv[1:] == ['--acceptance-preflight']:
    folder = os.path.join(root, 'Application Support', 'Stockbar')
    os.makedirs(folder)
    db = sqlite3.connect(os.path.join(folder, 'StockbarDataModel.sqlite'))
    db.executescript({schema!r})
    db.executemany('INSERT INTO Z_PRIMARYKEY VALUES (?, ?, 0, 0)', enumerate({entities!r}, 2))
    db.commit()
    print('{{ "liveProviderRequestsAllowed" : false }}')
else:
    folder = os.path.join(root, 'Logs', 'com.stockbar')
    os.makedirs(folder)
    with open(os.path.join(folder, 'stockbar.log'), 'w') as log:
        log.write('stand-in app started\\n')
    print('storage: ' + root)
    sys.exit(3)
'''


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs macOS and its developer tools')
class FailedRunTests(unittest.TestCase):
    def test_a_run_that_stops_early_keeps_the_log_and_deletes_the_storage(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        base = Path(directory.name)
        contents = base / 'dd/Build/Products/Release/Stockbar.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.stockbar.acceptance'}))
        app = contents / 'MacOS/Stockbar'
        app.write_text(STAND_IN.format(python=sys.executable, schema=SCHEMA, entities=ENTITIES))
        app.chmod(0o755)
        results = base / 'results'
        environment = dict(os.environ, STOCKBAR_DERIVED_DATA=str(base / 'dd'), PYTHON=sys.executable)

        # Output goes to files: a pipe would stay open for as long as anything
        # the script started still held it.
        with open(base / 'out.txt', 'w') as out, open(base / 'err.txt', 'w') as err:
            finished = subprocess.run(
                ['bash', str(REPO / 'Scripts/perf/benchmark.sh'), '--skip-build', '--commit-label', 'stand-in',
                 '--label', 'failing', '--runs', '1', '--output', str(results)],
                env=environment, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=170)

        errors = (base / 'err.txt').read_text()
        self.assertNotEqual(finished.returncode, 0, errors)
        self.assertIn('Stockbar exited during the benchmark', errors)
        self.assertIn(str(results / 'app-failed.log'), errors)
        self.assertEqual((results / 'app-failed.log').read_text(), 'stand-in app started\n')
        storage = (results / 'app-output-failed.log').read_text().strip().removeprefix('storage: ')
        self.assertIn('stockbar-bench.', storage)
        self.assertFalse(os.path.exists(storage), storage)
        self.assertFalse((results / 'app.log').exists())


if __name__ == '__main__':
    unittest.main()
