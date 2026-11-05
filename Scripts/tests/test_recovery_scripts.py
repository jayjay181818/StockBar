"""Exercise backup and restore scripts against isolated fixture data."""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
BACKUP = REPO / "Scripts" / "backup_stockbar_data.sh"
RESTORE = REPO / "Scripts" / "restore_stockbar_data.sh"


class RecoveryScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="stockbar-recovery-")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.data = self.home / "Library" / "Application Support" / "Stockbar"
        self.config_dir = self.home / "Library" / "Application Support" / "com.stockbar"
        self.bin = self.root / "bin"
        self.data.mkdir(parents=True)
        self.config_dir.mkdir(parents=True)
        self.bin.mkdir()
        self.defaults = self.bin / "defaults"
        self.pgrep = self.bin / "pgrep"
        self.defaults.write_text(
            "#!/bin/bash\n"
            "if [[ $1 == export ]]; then printf 'fixture-defaults\\n' > \"$3\";"
            " else cp \"$3\" \"$STOCKBAR_DEFAULTS_IMPORT_TARGET\"; fi\n"
        )
        self.defaults.chmod(stat.S_IRWXU)
        self.write_pgrep("1")

    def tearDown(self):
        self.temp.cleanup()

    def write_pgrep(self, status):
        self.pgrep.write_text(f"#!/bin/bash\nexit {status}\n")
        self.pgrep.chmod(stat.S_IRWXU)

    def env(self):
        return dict(
            os.environ,
            PATH=f"{self.bin}:{os.environ.get('PATH', '')}",
            STOCKBAR_HOME_OVERRIDE=str(self.home),
            STOCKBAR_DEFAULTS_COMMAND=str(self.defaults),
            STOCKBAR_DEFAULTS_IMPORT_TARGET=str(self.root / "defaults-imported.plist"),
        )

    def run_script(self, script, *args, input_text=None, env=None):
        return subprocess.run(
            ["bash", str(script), *args],
            input=input_text,
            env=env or self.env(),
            capture_output=True,
            text=True,
        )

    def seed(self, prefix):
        (self.data / "StockbarDataModel.sqlite").write_text(f"{prefix}-db")
        (self.data / "StockbarDataModel.sqlite-wal").write_text(f"{prefix}-wal")
        (self.data / "StockbarDataModel.sqlite-shm").write_text(f"{prefix}-shm")
        (self.config_dir / ".stockbar_config.json").write_text(f'{{"key":"{prefix}"}}\n')
        cache = self.home / "Library" / "Caches" / "stockbar-cache" / "quote_cache.json"
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(f"{prefix}-cache")

    def create_backup(self):
        result = self.run_script(BACKUP)
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = sorted(self.data.joinpath("Backups").glob("stockbar_complete_backup_*"))
        self.assertEqual(len(backups), 1)
        return backups[0]

    def test_canonical_round_trip_and_safety_copy(self):
        self.seed("before")
        backup = self.create_backup()
        self.seed("after")

        result = self.run_script(RESTORE, backup.name, input_text="yes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.data / "StockbarDataModel.sqlite").read_text(), "before-db")
        self.assertEqual((self.data / "StockbarDataModel.sqlite-wal").read_text(), "before-wal")
        self.assertEqual((self.data / "StockbarDataModel.sqlite-shm").read_text(), "before-shm")
        self.assertEqual((self.config_dir / ".stockbar_config.json").read_text(), '{"key":"before"}\n')
        self.assertEqual(
            (self.home / "Library" / "Caches" / "stockbar-cache" / "quote_cache.json").read_text(),
            "before-cache",
        )
        self.assertEqual((self.root / "defaults-imported.plist").read_text(), "fixture-defaults\n")
        safety = sorted(self.data.glob("StockbarDataModel_pre_restore_*"))[-1]
        self.assertEqual((safety / "StockbarDataModel.sqlite").read_text(), "after-db")
        self.assertIn("com.stockbar/.stockbar_config.json", result.stdout)
        self.assertIn("Keychain items were not restored", result.stdout)

    def test_backup_falls_back_to_legacy_home_folder_cache(self):
        self.seed("before")
        (self.home / "Library" / "Caches" / "stockbar-cache" / "quote_cache.json").unlink()
        (self.home / ".stockbar_cache.json").write_text("legacy-cache")

        backup = self.create_backup()

        self.assertEqual((backup / ".stockbar_cache.json").read_text(), "legacy-cache")

    def test_stale_sidecars_are_removed_after_safety_copy(self):
        self.seed("before")
        backup = self.create_backup()
        (backup / "StockbarDataModel.sqlite-wal").unlink()
        (backup / "StockbarDataModel.sqlite-shm").unlink()
        self.seed("after")

        result = self.run_script(RESTORE, backup.name, input_text="yes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.data / "StockbarDataModel.sqlite-wal").exists())
        self.assertFalse((self.data / "StockbarDataModel.sqlite-shm").exists())

    def test_running_process_refuses_before_mutation(self):
        self.seed("before")
        self.write_pgrep("0")
        result = self.run_script(BACKUP)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Stockbar is running", result.stderr)
        self.assertFalse((self.data / "Backups").exists())

    def test_pgrep_error_refuses_closed_state_assumption(self):
        self.seed("before")
        self.write_pgrep("2")
        result = self.run_script(BACKUP)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pgrep exited 2", result.stderr)
        self.assertFalse((self.data / "Backups").exists())

    def test_fixture_override_requires_mock_defaults(self):
        self.seed("before")
        env = self.env()
        del env["STOCKBAR_DEFAULTS_COMMAND"]
        result = self.run_script(BACKUP, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires STOCKBAR_DEFAULTS_COMMAND", result.stderr)

    def logging_defaults(self, export_exit=0, read_exit=0):
        """Stub that logs each call and records the state of the live data on import."""
        log = self.root / "defaults.log"
        self.defaults.write_text(
            "#!/bin/bash\n"
            "echo \"$1\" >> \"$STOCKBAR_DEFAULTS_LOG\"\n"
            "case $1 in\n"
            f"  export) [[ {export_exit} -eq 0 ]] && printf 'current-defaults\\n' > \"$3\"; exit {export_exit};;\n"
            f"  read) exit {read_exit};;\n"
            "  import) cp \"$STOCKBAR_SAFETY_PROBE\"/UserDefaults.plist \"$STOCKBAR_PROBE_OUT\" 2>/dev/null;\n"
            "          ls \"$STOCKBAR_SAFETY_PROBE\" > \"$STOCKBAR_PROBE_LS\";;\n"
            "esac\n"
        )
        self.defaults.chmod(stat.S_IRWXU)
        return log

    def test_current_data_is_saved_before_defaults_import_or_overwrite(self):
        self.seed("before")
        backup = self.create_backup()
        self.seed("after")
        log = self.logging_defaults()
        env = self.env()
        env["STOCKBAR_DEFAULTS_LOG"] = str(log)
        env["STOCKBAR_SAFETY_PROBE"] = "/nonexistent"
        # Resolve the safety directory at import time from the live data dir.
        self.defaults.write_text(
            self.defaults.read_text().replace(
                'cp "$STOCKBAR_SAFETY_PROBE"/UserDefaults.plist',
                'd=$(ls -d "$STOCKBAR_DATA_PROBE"/StockbarDataModel_pre_restore_* | head -1);'
                ' cp "$d"/UserDefaults.plist',
            ).replace(
                'ls "$STOCKBAR_SAFETY_PROBE"',
                'ls -A "$d"',
            )
        )
        env["STOCKBAR_DATA_PROBE"] = str(self.data)
        env["STOCKBAR_PROBE_OUT"] = str(self.root / "probe-defaults.plist")
        env["STOCKBAR_PROBE_LS"] = str(self.root / "probe-ls")

        result = self.run_script(RESTORE, backup.name, input_text="yes\n", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().split(), ["export", "import"])
        # At import time the safety directory already held the current data.
        self.assertEqual((self.root / "probe-defaults.plist").read_text(), "current-defaults\n")
        saved = (self.root / "probe-ls").read_text().split()
        for name in (".stockbar_config.json", "quote_cache.json", "StockbarDataModel.sqlite"):
            self.assertIn(name, saved)
        safety = sorted(self.data.glob("StockbarDataModel_pre_restore_*"))[-1]
        self.assertEqual((safety / ".stockbar_config.json").read_text(), '{"key":"after"}\n')
        self.assertEqual((safety / "quote_cache.json").read_text(), "after-cache")
        self.assertEqual((safety / "UserDefaults.plist").read_text(), "current-defaults\n")
        self.assertEqual((self.config_dir / ".stockbar_config.json").read_text(), '{"key":"before"}\n')

    def test_restore_aborts_without_changes_when_defaults_export_fails(self):
        self.seed("before")
        backup = self.create_backup()
        self.seed("after")
        log = self.logging_defaults(export_exit=1, read_exit=0)
        env = self.env()
        env["STOCKBAR_DEFAULTS_LOG"] = str(log)

        result = self.run_script(RESTORE, backup.name, input_text="yes\n", env=env)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restore aborted before any change", result.stderr)
        self.assertNotIn("import", log.read_text().split())
        self.assertEqual((self.data / "StockbarDataModel.sqlite").read_text(), "after-db")
        self.assertEqual((self.config_dir / ".stockbar_config.json").read_text(), '{"key":"after"}\n')

    def test_restore_rechecks_process_after_confirmation(self):
        self.seed("before")
        backup = self.create_backup()
        self.seed("after")
        # First check reports stopped; the check after confirmation reports an
        # unknown pgrep error. The restore must fail before importing/copying.
        self.pgrep.write_text(
            "#!/bin/bash\n"
            "count_file=\"$STOCKBAR_PGREP_COUNT\"\n"
            "count=0; [[ -f $count_file ]] && count=$(cat $count_file)\n"
            "count=$((count + 1)); printf '%s' $count > $count_file\n"
            "[[ $count -eq 1 ]] && exit 1\n"
            "exit 2\n"
        )
        self.pgrep.chmod(stat.S_IRWXU)
        env = self.env()
        env["STOCKBAR_PGREP_COUNT"] = str(self.root / "pgrep-count")
        result = self.run_script(RESTORE, backup.name, input_text="yes\n", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pgrep exited 2", result.stderr)
        self.assertEqual((self.data / "StockbarDataModel.sqlite").read_text(), "after-db")


if __name__ == "__main__":
    unittest.main()
