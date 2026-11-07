"""Nagios state mapping, stale backups and safe status parsing."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('check_backup', ROOT / 'monitoring/check_backup.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class MonitoringTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'status.json'
        self.data = dict(version=1, state=0, finished_at=1000000, duration=60,
                         exit_code=0, warnings=0, sources_ok=4, sources_failed=0)

    def write(self):
        self.path.write_text(json.dumps(self.data))

    def check(self, age=0, args=()):
        output = io.StringIO()
        with patch('sys.argv', ['check_backup', '-f', str(self.path), *args]), \
             patch.object(CHECK.time, 'time', return_value=1000000 + age), \
             redirect_stdout(output):
            rc = CHECK.main()
        return rc, output.getvalue()

    def test_success(self):
        self.write()
        rc, output = self.check(age=60)
        self.assertEqual(rc, 0)
        self.assertIn('OK - last backup succeeded', output)
        self.assertIn('age=60s;108000;129600;0', output)

    def test_warning(self):
        self.data.update(state=1, warnings=2)
        self.write()
        rc, output = self.check()
        self.assertEqual(rc, 1)
        self.assertIn('2 warning(s)', output)

    def test_failure_has_priority_over_age_warning(self):
        self.data.update(state=2, exit_code=1)
        self.write()
        rc, output = self.check(age=108001)
        self.assertEqual(rc, 2)
        self.assertIn('last backup failed', output)

    def test_stale_thresholds(self):
        self.write()
        for age, expected in [(108000, 0), (108001, 1), (129600, 1), (129601, 2)]:
            with self.subTest(age=age):
                self.assertEqual(self.check(age=age)[0], expected)

    def test_custom_thresholds(self):
        self.write()
        self.assertEqual(self.check(age=301, args=('-w', '100', '-c', '300'))[0], 2)

    def test_missing_status_is_critical(self):
        self.assertEqual(self.check()[0], 2)

    def test_corrupt_or_executable_content_is_unknown(self):
        for raw in ['garbage', '{}', '$(touch /tmp/not-executed)', '[]', 'x' * 4097]:
            with self.subTest(raw=raw[:20]):
                self.path.write_text(raw)
                self.assertEqual(self.check()[0], 3)

    def test_invalid_schema(self):
        for values in [dict(state=3), dict(state=1), dict(version=2),
                       dict(duration=-1), dict(warnings=True), dict(duration=10**13)]:
            with self.subTest(values=values):
                data = dict(self.data, **values)
                self.path.write_text(json.dumps(data))
                self.assertEqual(self.check()[0], 3)

    def test_future_timestamp(self):
        self.write()
        self.assertEqual(self.check(age=-1)[0], 3)

    def test_invalid_thresholds(self):
        self.assertEqual(self.check(args=('-w', '200', '-c', '100'))[0], 3)

    def test_symlink_is_unknown(self):
        target = self.path.parent / 'target'
        target.write_text(json.dumps(self.data))
        self.path.symlink_to(target)
        self.assertEqual(self.check()[0], 3)

    def test_fifo_does_not_block(self):
        os.mkfifo(self.path)
        self.assertEqual(self.check()[0], 3)

    def test_argument_errors_are_unknown_on_stdout(self):
        output = io.StringIO()
        with patch('sys.argv', ['check_backup', '--invalid']), redirect_stdout(output):
            with self.assertRaises(SystemExit) as error:
                CHECK.main()
        self.assertEqual(error.exception.code, 3)
        self.assertIn('UNKNOWN -', output.getvalue())
