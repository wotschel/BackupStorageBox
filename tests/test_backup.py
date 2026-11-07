"""Regression checks using a fake restic; never contact a backup server."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.calls = self.base / 'calls'
        restic = self.base / 'restic'
        restic.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
case " $* " in
    *" backup "*) exit "${BACKUP_RC:-0}" ;;
esac
''')
        restic.chmod(0o700)
        self.password = self.base / 'password'
        self.password.write_text('test-only')
        self.config = self.base / 'backup.conf'
        self.env = dict(os.environ, PATH=f'{self.base}:{os.environ["PATH"]}',
                        CALLS=str(self.calls))

    def run_backup(self, source, *args, rc=0):
        self.config.write_text(f'''REMOTE_USER=test
REMOTE_HOST=example.invalid
SOURCES=('{source}')
RESTIC_PASSWORD_FILE='{self.password}'
MIN_FREE_PERCENT=0
LOG_FILE=/dev/null
''')
        return subprocess.run(['bash', str(ROOT / 'backup.sh'), '-c',
                               str(self.config), *args], env=dict(self.env, BACKUP_RC=str(rc)),
                              capture_output=True, text=True)

    def test_restore_with_missing_source(self):
        result = self.run_backup(self.base / 'missing', '--restic', 'snapshots')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('snapshots', self.calls.read_text())

    def test_backup_rejects_missing_source(self):
        result = self.run_backup(self.base / 'missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_partial_backup_preserves_history(self):
        result = self.run_backup(self.base, rc=3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Retention skipped', result.stdout)
        self.assertNotIn(' forget ', self.calls.read_text())

    def test_success_runs_retention(self):
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(' forget ', self.calls.read_text())

    def test_nextcloud_rejects_broken_config(self):
        self.config.write_text('false\n')
        result = subprocess.run(['bash', str(ROOT / 'nextcloud-backup.sh'),
                                 '-c', str(self.config), '--check'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('could not load configuration', result.stderr)


if __name__ == '__main__':
    unittest.main()
