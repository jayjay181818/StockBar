"""The helper's import layers: what is started, and how the starts are summarised."""
import argparse
import importlib.util
import stat
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PERF = REPO / 'Scripts/perf'


def load(name):
    spec = importlib.util.spec_from_file_location(name, PERF / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


helper_cost = load('helper_cost')
layers = load('helper_layers')

SAMPLER = """#!/bin/sh
echo app_footprint_mb_median=12.5
echo app_resident_mb_median=20.0
echo app_cpu_s_before_window=0.03
"""


class HelperLayersTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.sampler = Path(directory.name) / 'sampler'
        self.sampler.write_text(SAMPLER)
        self.sampler.chmod(self.sampler.stat().st_mode | stat.S_IXUSR)

    def test_each_layer_and_each_floor_gets_a_row_under_the_header(self):
        script = Path(self.sampler.parent) / 'floor'
        script.write_text(f'#!/bin/sh\nexec "{sys.executable}" -c "{layers.READY}"\n')
        script.chmod(script.stat().st_mode | stat.S_IXUSR)

        rows = layers.table(
            sys.executable, str(self.sampler), runs=2,
            floors=[('A compiled floor', str(script))],
            layers=[('Interpreter only', 'pass'), ('+ json', 'import json')],
        )

        self.assertIn('of 2 starts', rows[0])
        self.assertEqual([row.split(' | ')[0] for row in rows[2:]],
                         ['| Interpreter only', '| + json', '| A compiled floor'])
        self.assertIn('12.5 (12.5 to 12.5) MB', rows[2])
        self.assertIn('0.03 (0.03 to 0.03) s', rows[2])

    def test_the_last_layer_is_what_the_helper_imports(self):
        helper = (REPO / 'Stockbar/Resources/get_stock_data.py').read_text()
        self.assertIn('import yfinance', helper)
        self.assertIn('yfinance', layers.LAYERS[-1][1])
        self.assertEqual(layers.LAYERS[0][1], 'pass')

    def test_a_floor_is_a_label_and_a_program(self):
        self.assertEqual(layers.parse_floor('Swift=build/floor'), ('Swift', 'build/floor'))
        for malformed in ('build/floor', '=build/floor', 'Swift='):
            with self.assertRaises(argparse.ArgumentTypeError):
                layers.parse_floor(malformed)

    def test_a_program_that_exits_without_answering_is_an_error(self):
        with self.assertRaises(SystemExit) as stopped:
            helper_cost.started_usage([sys.executable, '-c', 'pass'], str(self.sampler))
        self.assertIn('exited before answering', str(stopped.exception))


if __name__ == '__main__':
    unittest.main()
