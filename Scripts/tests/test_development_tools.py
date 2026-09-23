"""Exercise command side effects and failure propagation without Xcode or app data."""
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('agent_docs', REPO / 'Scripts/validate_agent_docs.py')
docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(docs)


class DevelopmentToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='stockbar-tools-')
        self.root = Path(self.temp.name)
        for name in ('script', 'Scripts', 'bin'):
            (self.root / name).mkdir()
        for name in ('develop.sh', 'build_and_run.sh'):
            shutil.copy2(REPO / 'script' / name, self.root / 'script' / name)
        self.calls = self.root / 'calls'
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + ':' + os.environ['PATH'],
                        TEST_CALLS=str(self.calls), STOCKBAR_LOG_DIR=str(self.root / 'logs'),
                        STOCKBAR_DERIVED_DATA=str(self.root / 'derived'))
        self.stub('xcodebuild', 'printf "%s\\n" "$@" >> "$TEST_CALLS"\nexit "${TEST_XCODE_EXIT:-0}"')
        self.stub('pgrep', 'exit "${TEST_APP_RUNNING:-1}"')
        self.stub('pkill', 'echo UNEXPECTED_KILL >> "$TEST_CALLS"\nexit 99')

    def tearDown(self):
        self.temp.cleanup()

    def stub(self, name, body):
        p = self.root / 'bin' / name
        p.write_text('#!/bin/bash\n' + body + '\n')
        p.chmod(0o755)

    def run_tool(self, *args, script='develop.sh'):
        return subprocess.run(['bash', str(self.root / 'script' / script), *args],
                              env=self.env, capture_output=True, text=True)

    def test_build_only_passes_consistent_flags(self):
        result = self.run_tool('build')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls[0], 'build')
        self.assertIn('Debug', calls)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', calls)
        self.assertNotIn('UNEXPECTED_KILL', calls)

    def test_test_filter_and_failure_exit_are_preserved(self):
        self.env['TEST_XCODE_EXIT'] = '42'
        result = self.run_tool('test', 'StockbarTests/ExampleTests/testExample')
        self.assertEqual(result.returncode, 42)
        self.assertIn('-only-testing:StockbarTests/ExampleTests/testExample', self.calls.read_text())
        self.assertIn('Full log:', result.stderr)

    def test_failure_reports_early_error_hidden_by_build_tail(self):
        self.stub('xcodebuild', 'echo "Example.swift:1: error: fixture failure"\nfor i in {1..100}; do echo "compile progress"; done\nexit 65')
        result = self.run_tool('build')
        self.assertEqual(result.returncode, 65)
        self.assertIn('error: fixture failure', result.stderr)
        self.assertLess(len(result.stderr.splitlines()), 25)

    def test_invalid_input_has_no_build_side_effect(self):
        for args in [('unknown',), ('test', '-bad'), ('build', 'unexpected'), ('acceptance',)]:
            result = self.run_tool(*args)
            self.assertEqual(result.returncode, 64, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_checks_stop_at_first_failure(self):
        self.stub('swiftlint', 'echo FIRST_FAILURE\nexit 23')
        (self.root / 'Scripts/validate_entitlements.sh').write_text('echo UNEXPECTED_NEXT_GATE >> "$TEST_CALLS"\n')
        result = self.run_tool('checks')
        self.assertEqual(result.returncode, 23)
        self.assertIn('FIRST_FAILURE', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_run_respects_derived_data_override_without_launching_missing_bundle(self):
        result = self.run_tool('run', script='build_and_run.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Expected app bundle was not produced', result.stderr)
        self.assertIn(str(self.root / 'derived'), self.calls.read_text().splitlines())

    def test_run_refuses_existing_app_without_killing_or_building(self):
        self.env['TEST_APP_RUNNING'] = '0'
        result = self.run_tool('run', script='build_and_run.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already running', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_process_probe_errors_prevent_launch(self):
        self.env['TEST_APP_RUNNING'] = '2'
        result = self.run_tool('run', script='build_and_run.sh')
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.calls.exists())

    def test_run_help_and_unknown_mode_do_not_build(self):
        self.assertEqual(self.run_tool('--help', script='build_and_run.sh').returncode, 0)
        self.assertEqual(self.run_tool('invalid', script='build_and_run.sh').returncode, 64)
        self.assertFalse(self.calls.exists())


class DocumentationValidationTests(unittest.TestCase):
    def test_missing_links_and_duplicate_names_fail_but_size_is_advisory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'AGENTS.md').write_text('[missing](missing.md)\n' + 'x' * 4500)
            (root / 'DATA_AGENTS.md').write_text('duplicate')
            (root / 'build').mkdir()
            (root / 'build/STALE_AGENTS.md').write_text('[bad](no.md)')
            errors, warnings, count, _ = docs.validate(root)
            self.assertEqual(count, 2)
            self.assertEqual(len(errors), 2)
            self.assertEqual(len(warnings), 1)
            (root / 'missing.md').write_text('reference')
            (root / 'DATA_AGENTS.md').unlink()
            errors, warnings, _, _ = docs.validate(root)
            self.assertFalse(errors)
            self.assertTrue(warnings)


if __name__ == '__main__':
    unittest.main()
