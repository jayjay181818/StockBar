"""What package_release.sh refuses, with a stand-in for the app."""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

COVERAGE_FLAGS = ['-fprofile-instr-generate', '-fcoverage-mapping']


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs macOS and its developer tools')
class CoverageInstrumentationTests(unittest.TestCase):
    def package(self, compiler_flags):
        """Packages a stand-in app built with these flags. Returns the result and the output folder."""
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        base = Path(directory.name)
        contents = base / 'Stockbar.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.0.1'}))
        source = base / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        subprocess.run(['xcrun', 'clang', *compiler_flags, '-o', str(contents / 'MacOS/Stockbar'), str(source)],
                       check=True, capture_output=True, timeout=120)
        output = base / 'release'
        finished = subprocess.run(
            ['bash', str(REPO / 'script/package_release.sh'), '--build', '0.0.1',
             '--app', str(base / 'Stockbar.app'), '--output', str(output)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        return finished, output

    def test_an_app_built_with_coverage_counters_is_refused(self):
        finished, output = self.package(COVERAGE_FLAGS)
        self.assertEqual(finished.returncode, 1, finished.stderr)
        self.assertIn('Refusing to package: the app was built with test-coverage instrumentation.', finished.stderr)
        self.assertFalse(output.exists(), 'nothing may be written for a refused app')

    def test_an_app_built_without_them_gets_past_that_check(self):
        finished, _ = self.package([])
        self.assertNotIn('test-coverage instrumentation', finished.stderr)
        # The stand-in has no frameworks, so the next check is the one that stops it.
        self.assertIn('Sparkle.framework is missing from the build', finished.stderr)


if __name__ == '__main__':
    unittest.main()
