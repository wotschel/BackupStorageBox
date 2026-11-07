#!/usr/bin/env python3
"""Nagios-compatible check for backup.sh's atomic numeric status file."""
import argparse
import json
import os
import stat
import sys
import time


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(3, f"UNKNOWN - {message}\n")

    def exit(self, status=0, message=None):
        if message:
            print(message, end="")
        raise SystemExit(status)


def result(code, message, perf=""):
    label = ("OK", "WARNING", "CRITICAL", "UNKNOWN")[code]
    print(f"{label} - {message}" + (f" | {perf}" if perf else ""))
    return code


def main():
    parser = Parser(description=__doc__)
    parser.add_argument("-f", "--status-file", default="/var/lib/backup/status.json")
    parser.add_argument("-w", "--warning-age", type=int, default=108000,
                        help="warn if completion is older than this many seconds (default: 108000 = 30h)")
    parser.add_argument("-c", "--critical-age", type=int, default=129600,
                        help="critical if completion is older than this many seconds (default: 129600 = 36h)")
    args = parser.parse_args()
    if not 0 <= args.warning_age < args.critical_age:
        return result(3, "age thresholds must satisfy 0 <= warning < critical")

    try:
        # Refuse symlinks and non-regular files, including FIFOs; never source data.
        fd = os.open(args.status_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                return result(3, "status path is not a regular file")
            raw = stream.read(4097)
    except FileNotFoundError:
        return result(2, "no completed backup status found")
    except (OSError, UnicodeError):
        return result(3, "cannot read status file; check path and permissions")

    keys = {"version", "state", "finished_at", "duration", "exit_code",
            "warnings", "sources_ok", "sources_failed"}
    try:
        data = json.loads(raw)
        if len(raw) > 4096 or not isinstance(data, dict) or set(data) != keys:
            raise ValueError()
        if any(type(value) is not int or not 0 <= value <= 10**12
               for value in data.values()):
            raise ValueError()
        if data["version"] != 1 or data["state"] not in (0, 1, 2):
            raise ValueError()
        expected = 2 if data["exit_code"] else (1 if data["warnings"] else 0)
        if data["state"] != expected or data["finished_at"] == 0:
            raise ValueError()
    except (ValueError, TypeError):
        return result(3, "invalid or unsupported status file")

    age = int(time.time()) - data["finished_at"]
    if age < 0:
        return result(3, "backup completion time is in the future; check clocks")
    perf = (f"age={age}s;{args.warning_age};{args.critical_age};0 "
            f"duration={data['duration']}s;;;0 "
            f"sources_failed={data['sources_failed']};;;0")
    if data["state"] == 2:
        return result(2, f"last backup failed (exit={data['exit_code']}, age={age}s)", perf)
    if age > args.critical_age:
        return result(2, f"last completed backup is too old (age={age}s)", perf)
    if age > args.warning_age:
        return result(1, f"last completed backup is getting old (age={age}s)", perf)
    if data["state"] == 1:
        return result(1, f"last backup completed with {data['warnings']} warning(s) (age={age}s)", perf)
    return result(0, f"last backup succeeded (age={age}s, duration={data['duration']}s)", perf)


if __name__ == "__main__":
    sys.exit(main())
