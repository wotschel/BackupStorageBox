"""Regression checks using a fake restic; never contact a backup server."""
import os
import fcntl
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
WRAPPERS_DIR='{self.base / 'wrappers'}'
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

    def action(self, phase, name, body):
        directory = self.base / 'wrappers' / phase
        directory.mkdir(parents=True, exist_ok=True)
        script = directory / name
        script.write_text('#!/bin/bash\nset -e\n' + body + '\n')
        script.chmod(0o700)
        return script

    def test_action_order_and_post_status(self):
        self.action('pre', '20-second', 'echo pre20 >> "$CALLS"')
        self.action('pre', '10-first', 'echo pre10 >> "$CALLS"')
        self.action('post', '10-first', 'echo post:$BACKUP_EXIT_CODE >> "$CALLS"')
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = self.calls.read_text().splitlines()
        self.assertEqual(lines[:2], ['pre10', 'pre20'])
        self.assertEqual(lines[-1], 'post:0')

    def test_pre_failure_skips_backup_and_runs_post(self):
        self.action('pre', '10-fail', 'exit 7')
        self.action('pre', '20-skipped', 'echo unexpected >> "$CALLS"')
        self.action('post', '10-cleanup', 'echo post:$BACKUP_EXIT_CODE >> "$CALLS"')
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls.read_text().splitlines(), ['post:1'])

    def test_backup_failure_runs_post(self):
        self.action('post', '10-cleanup', 'echo post:$BACKUP_EXIT_CODE >> "$CALLS"')
        result = self.run_backup(self.base, rc=2)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls.read_text().splitlines()[-1], 'post:1')

    def test_post_failure_continues_remaining_actions(self):
        self.action('post', '10-fail', 'exit 8')
        self.action('post', '20-cleanup', 'echo cleaned >> "$CALLS"')
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls.read_text().splitlines()[-1], 'cleaned')

    def test_dry_run_and_passthrough_skip_actions(self):
        for phase in ('pre', 'post'):
            self.action(phase, '10-action', 'echo unexpected >> "$CALLS"')
        for args in [('-n',), ('--restic', 'snapshots')]:
            with self.subTest(args=args):
                result = self.run_backup(self.base, *args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('unexpected', self.calls.read_text())

    def test_pre_can_create_source(self):
        source = self.base / 'new-source'
        self.action('pre', '10-create', 'mkdir "' + str(source) + '"')
        result = self.run_backup(source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(source.is_dir())

    def test_nonexecutable_actions_are_skipped(self):
        script = self.action('pre', '10-disabled', 'exit 9')
        script.chmod(0o600)
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_signal_runs_post(self):
        self.action('pre', '10-signal', 'kill -TERM "$PPID"')
        self.action('post', '10-cleanup', 'echo post:$BACKUP_EXIT_CODE >> "$CALLS"')
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ['post:143'])

    def test_lock_rejection_does_not_run_actions(self):
        self.action('pre', '10-action', 'echo unexpected >> "$CALLS"')
        self.action('post', '10-action', 'echo unexpected >> "$CALLS"')
        self.config.touch()
        with self.config.open() as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_backup(self.base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already running', result.stdout)
        self.assertFalse(self.calls.exists())



if __name__ == '__main__':
    unittest.main()
