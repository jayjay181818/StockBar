"""Exercise setup_python_env.sh's own-uv download offline with a fake uv release."""
import hashlib
import os
import platform
import subprocess
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / 'Stockbar/Resources/setup_python_env.sh'
ARCH = 'aarch64' if platform.machine() in ('arm64', 'aarch64') else 'x86_64'

# Fake uv: records its arguments and the uv environment, and makes a "venv"
# whose python3 answers the script's check and runs its os.replace call.
FAKE_UV = r'''#!/bin/bash
printf 'uv %s | install=%s cache=%s pref=%s\n' "$*" "$UV_PYTHON_INSTALL_DIR" "$UV_CACHE_DIR" "$UV_PYTHON_PREFERENCE" >> "$TEST_CALLS"
if [[ "$1" == venv ]]; then
  dir="${@: -1}"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/python3" <<'PY'
#!/bin/bash
if [[ "$1" == -c ]]; then exec /usr/bin/python3 "$@"; fi
cat > /dev/null
echo "Python 3.13.0, OpenSSL 3.0.0"
PY
  chmod +x "$dir/bin/python3"
fi
'''


class SetupPythonEnvTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='stockbar-setup-')
        self.root = Path(self.temp.name)
        self.support = self.root / 'support'
        self.calls = self.root / 'calls'
        self.requirements = self.root / 'requirements.txt'
        self.requirements.write_text('yfinance==1.2.0\n')
        self.archive = self.root / 'uv.tar.gz'
        self.make_archive(FAKE_UV)
        self.env = dict(
            os.environ,
            STOCKBAR_USE_OWN_UV='1',
            STOCKBAR_SUPPORT_DIR=str(self.support),
            STOCKBAR_CACHE_DIR=str(self.root / 'cache'),
            STOCKBAR_REQUIREMENTS=str(self.requirements),
            STOCKBAR_UV_URL=self.archive.as_uri(),
            STOCKBAR_UV_SHA256=self.sha256(self.archive),
            TEST_CALLS=str(self.calls),
        )

    def tearDown(self):
        self.temp.cleanup()

    def make_archive(self, uv_body):
        staging = self.root / 'staging' / f'uv-{ARCH}-apple-darwin'
        staging.mkdir(parents=True, exist_ok=True)
        uv = staging / 'uv'
        uv.write_text(uv_body)
        uv.chmod(0o755)
        with tarfile.open(self.archive, 'w:gz') as archive:
            archive.add(staging, arcname=staging.name)

    @staticmethod
    def sha256(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def run_setup(self):
        return subprocess.run(['bash', str(SCRIPT)], env=self.env, capture_output=True, text=True)

    def uv_dirs(self):
        tools = self.support / 'tools'
        return sorted(p.name for p in tools.glob('uv-*')) if tools.exists() else []

    def test_downloads_verified_uv_and_keeps_python_with_stockbar(self):
        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Downloading uv', result.stderr)
        self.assertEqual(len(self.uv_dirs()), 1)
        self.assertTrue((self.support / 'python-env').is_symlink())
        calls = self.calls.read_text().splitlines()
        self.assertTrue(calls[0].startswith('uv venv --quiet --python 3.13 '), calls)
        self.assertTrue(calls[1].startswith(f'uv pip install --quiet --python '), calls)
        for call in calls:
            self.assertIn(f'install={self.support}/tools/python', call)
            self.assertIn(f'cache={self.root}/cache/uv', call)
            self.assertIn('pref=only-managed', call)

    def test_second_run_reuses_the_downloaded_uv(self):
        self.assertEqual(self.run_setup().returncode, 0)
        self.archive.unlink()  # A second download would now fail.

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('Downloading uv', result.stderr)

    def test_checksum_mismatch_installs_nothing(self):
        self.env['STOCKBAR_UV_SHA256'] = '0' * 64

        result = self.run_setup()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match its expected SHA-256', result.stderr)
        self.assertEqual(self.uv_dirs(), [])
        self.assertFalse(self.calls.exists())
        self.assertFalse((self.support / 'python-env').exists())
        self.assertEqual(list((self.support / 'tools').glob('.uv-download.*')), [])

    def test_changed_checksum_replaces_a_previously_downloaded_uv(self):
        self.assertEqual(self.run_setup().returncode, 0)
        self.make_archive(FAKE_UV + '# rebuilt\n')
        self.env['STOCKBAR_UV_SHA256'] = self.sha256(self.archive)

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Downloading uv', result.stderr)

    def test_failed_download_explains_what_to_do(self):
        self.env['STOCKBAR_UV_URL'] = (self.root / 'missing.tar.gz').as_uri()

        result = self.run_setup()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not download uv', result.stderr)
        self.assertFalse((self.support / 'python-env').exists())

    def test_removes_leftovers_but_keeps_the_previous_environment(self):
        self.assertEqual(self.run_setup().returncode, 0)
        previous = (self.support / 'python-env').resolve().name
        for name in ('python-env-20200101000000', 'python-env-previous-20200101000000'):
            (self.support / name / 'bin').mkdir(parents=True)
        (self.support / 'python-env.new').symlink_to('python-env-20200101000000')
        time.sleep(1.1)  # Build folders are named to the second.

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        current = (self.support / 'python-env').resolve().name
        self.assertNotEqual(current, previous)
        self.assertEqual(sorted(p.name for p in self.support.glob('python-env*')),
                         sorted(['python-env', previous, current]))

    def test_stopping_the_script_stops_the_install_and_removes_the_build(self):
        self.make_archive(FAKE_UV + 'if [[ "$1" == pip ]]; then touch "$TEST_CALLS.installing"; sleep 30; fi\n')
        self.env['STOCKBAR_UV_SHA256'] = self.sha256(self.archive)
        process = subprocess.Popen(['bash', str(SCRIPT)], env=self.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        marker = Path(str(self.calls) + '.installing')
        deadline = time.time() + 20
        while not marker.exists() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(marker.exists())

        process.terminate()

        self.assertEqual(process.wait(timeout=10), 143)
        self.assertEqual(list(self.support.glob('python-env*')), [])


if __name__ == '__main__':
    unittest.main()
