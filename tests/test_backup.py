"""Regression checks using a fake restic; never contact a backup server."""
import os
import json
import fcntl
import re
import stat
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
    *" backup "*) echo "snapshot output"; exit "${BACKUP_RC:-0}" ;;
esac
''')
        restic.chmod(0o700)
        self.password = self.base / 'password'
        self.password.write_text('test-only')
        self.config = self.base / 'backup.conf'
        self.env = dict(os.environ, PATH=f'{self.base}:{os.environ["PATH"]}',
                        CALLS=str(self.calls))

    def run_backup(self, source, *args, rc=0, log_file="/dev/null", config_extra=""):
        self.config.write_text(f'''REMOTE_USER=test
REMOTE_HOST=example.invalid
SOURCES=('{source}')
RESTIC_PASSWORD_FILE='{self.password}'
MIN_FREE_PERCENT=0
LOG_FILE='{log_file}'
WRAPPERS_DIR='{self.base / 'wrappers'}'
STATUS_FILE='{self.base / 'status.json'}'
{config_extra}
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

    def test_nonexecutable_actions_warn_and_are_skipped(self):
        for phase in ('pre', 'post'):
            script = self.action(phase, '10-disabled script.sh', 'echo unexpected >> "$CALLS"; exit 9')
            script.chmod(0o600)
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('unexpected', self.calls.read_text())
        for phase in ('pre', 'post'):
            self.assertIn(f'Warning: Skipping {phase} action:', result.stdout)
            self.assertIn(str(self.base / 'wrappers' / phase / '10-disabled script.sh'), result.stdout)
        self.assertIn('is not executable. Enable it with: chmod +x -- ', result.stdout)

    def test_placeholders_and_subdirectories_do_not_warn(self):
        directory = self.base / 'wrappers' / 'pre'
        directory.mkdir(parents=True)
        (directory / '.gitkeep').touch()
        (directory / 'subdirectory').mkdir()
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('Skipping pre action:', result.stdout)

    def test_structured_log_and_final_summary_after_cleanup(self):
        logfile = self.base / 'logs' / 'backup.log'
        self.action('pre', '10-prepare', 'printf "first\\nsecond\\n"')
        self.action('post', '10-cleanup', 'echo cleanup-output')
        result = self.run_backup(self.base, log_file=logfile)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        content = logfile.read_text()
        self.assertEqual(content, result.stdout)
        lines = content.splitlines()
        pattern = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2} (INFO|WARN|ERROR|OUTPUT) \[([^]]+)\] [a-z]+: '
        run_ids = set()
        for line in lines:
            match = re.match(pattern, line)
            self.assertIsNotNone(match, line)
            run_ids.add(match.group(2))
        self.assertEqual(len(run_ids), 1)
        self.assertIn('pre: first', content)
        self.assertIn('pre: second', content)
        self.assertIn('backup: snapshot output', content)
        self.assertIn('post: Finished post action:', content)
        self.assertIn('duration=', content)
        self.assertIn('exit=0', content)
        self.assertIn('summary: finished status=OK', lines[-1])
        self.assertIn('sources_ok=1 sources_failed=0', lines[-1])
        self.assertNotIn('test-only', content)
        self.assertEqual(stat.S_IMODE(logfile.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(logfile.parent.stat().st_mode), 0o700)

    def test_post_failure_is_reflected_in_final_summary(self):
        self.action('post', '10-fail', 'exit 8')
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn('summary: finished status=FAILED', result.stdout.splitlines()[-1])
        self.assertIn('Finished post action:', result.stdout)
        self.assertIn('exit=8', result.stdout)

    def test_warning_and_failed_source_summary(self):
        for rc, status, counts in [(3, 'WARNING', 'sources_ok=1 sources_failed=0'),
                                    (2, 'FAILED', 'sources_ok=0 sources_failed=1')]:
            with self.subTest(rc=rc):
                result = self.run_backup(self.base, rc=rc)
                summary = result.stdout.splitlines()[-1]
                self.assertIn('summary: finished status=' + status, summary)
                self.assertIn(counts, summary)

    def test_log_failure_falls_back_to_console(self):
        blocked = self.base / 'not-a-directory'
        blocked.write_text('blocked')
        result = self.run_backup(self.base, log_file=blocked / 'backup.log')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('logging to the console only', result.stdout)
        self.assertIn('summary: finished status=WARNING', result.stdout)

    def test_logging_continues_after_rotation(self):
        logfile = self.base / 'backup.log'
        self.action('pre', '10-rotate', f'mv "{logfile}" "{logfile}.1"; echo after-rotation')
        result = self.run_backup(self.base, log_file=logfile)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('started backup=', Path(str(logfile) + '.1').read_text())
        self.assertIn('pre: after-rotation', logfile.read_text())
        self.assertIn('summary: finished status=OK', logfile.read_text())

    def test_administrative_command_does_not_create_log(self):
        logfile = self.base / 'logs' / 'backup.log'
        result = self.run_backup(self.base / 'missing', '--restic', 'snapshots', log_file=logfile)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(logfile.exists())
        self.assertNotIn('summary:', result.stdout)

    def test_mail_excerpt_only_contains_current_run(self):
        logfile = self.base / 'backup.log'
        logfile.write_text('old-run-secret-marker\n')
        mailbox = self.base / 'mail'
        sendmail = self.base / 'sendmail'
        sendmail.write_text('#!/bin/bash\ncat > "' + str(mailbox) + '"\n')
        sendmail.chmod(0o700)
        self.action('post', '10-fail', 'exit 8')
        result = self.run_backup(self.base, log_file=logfile,
                                 config_extra='MAIL_TO="test@example.invalid"')
        self.assertEqual(result.returncode, 1)
        mail = mailbox.read_text()
        self.assertIn('Run ID:', mail)
        self.assertIn('summary: finished status=FAILED', mail)
        self.assertNotIn('old-run-secret-marker', mail)
        self.assertNotIn('test-only', mail)

    def test_status_file_covers_backup_and_post_failures(self):
        for backup_rc, expected in [(0, 0), (3, 1), (2, 2)]:
            with self.subTest(backup_rc=backup_rc):
                result = self.run_backup(self.base, rc=backup_rc)
                status_file = self.base / 'status.json'
                data = json.loads(status_file.read_text())
                self.assertEqual(data['state'], expected)
                self.assertEqual(data['exit_code'], result.returncode)
                self.assertEqual(stat.S_IMODE(status_file.stat().st_mode), 0o644)
                check = subprocess.run(['python3', str(ROOT / 'monitoring/check_backup.py'),
                                        '-f', str(status_file)], capture_output=True, text=True)
                self.assertEqual(check.returncode, expected, check.stdout + check.stderr)
                self.assertNotIn('test-only', status_file.read_text())
        self.action('post', '10-fail', 'exit 9')
        self.run_backup(self.base)
        self.assertEqual(json.loads((self.base / 'status.json').read_text())['state'], 2)

    def test_status_is_preserved_by_dry_run_admin_and_lock_rejection(self):
        status_file = self.base / 'status.json'
        status_file.write_text('previous status')
        for args in [('-n',), ('--restic', 'snapshots')]:
            self.run_backup(self.base, *args)
            self.assertEqual(status_file.read_text(), 'previous status')
        with self.config.open() as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_backup(self.base)
        self.assertEqual(status_file.read_text(), 'previous status')

    def test_missing_source_and_pre_failure_publish_critical(self):
        self.run_backup(self.base / 'missing')
        status_file = self.base / 'status.json'
        self.assertEqual(json.loads(status_file.read_text())['state'], 2)
        self.action('pre', '10-fail', 'exit 8')
        self.run_backup(self.base)
        self.assertEqual(json.loads(status_file.read_text())['state'], 2)

    def test_status_write_failure_warns_and_does_not_leave_temporary_file(self):
        blocker = self.base / 'blocker'
        blocker.write_text('not a directory')
        result = self.run_backup(self.base, config_extra=f'STATUS_FILE="{blocker}/status.json"')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Could not publish monitoring status', result.stdout)
        self.assertIn('summary: finished status=WARNING', result.stdout)
        self.assertEqual(list(self.base.glob('.backup-status.*')), [])

    def test_status_destination_directory_is_rejected_without_temp_leaks(self):
        destination = self.base / 'destination'
        destination.mkdir()
        result = self.run_backup(self.base, config_extra=f'STATUS_FILE="{destination}"')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Could not publish monitoring status', result.stdout)
        self.assertEqual(list(destination.iterdir()), [])
        self.assertEqual(list(self.base.glob('.backup-status.*')), [])

    def test_dependency_setup_failure_publishes_critical(self):
        self.run_backup(self.base, config_extra=f'RESTIC_PASSWORD_FILE="{self.base}/missing-password"')
        data = json.loads((self.base / 'status.json').read_text())
        self.assertEqual(data['state'], 2)
        self.assertEqual(data['exit_code'], 1)

    def test_status_publishing_can_be_disabled(self):
        self.run_backup(self.base, config_extra='STATUS_FILE=""')
        self.assertFalse((self.base / 'status.json').exists())

    def test_signal_runs_post(self):
        self.action('pre', '10-signal', 'kill -TERM "$PPID"')
        self.action('post', '10-cleanup', 'echo post:$BACKUP_EXIT_CODE >> "$CALLS"')
        result = self.run_backup(self.base)
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ['post:143'])
        data = json.loads((self.base / 'status.json').read_text())
        self.assertEqual(data['state'], 2)
        self.assertEqual(data['exit_code'], 143)

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
