# Prompt

Reconstructed prompt that can be used to generate this script:

---

Write a Bash script `backup.sh` for Ubuntu 26.04 LTS or newer that creates a
daily backup with restic over SFTP to a remote server (Hetzner Storage Box).

Requirements:

- Repository via SFTP at `RESTIC_REPO_PATH` (default `restic-<BACKUP_NAME>`,
  relative to the SSH user's home; `BACKUP_NAME` default `$(hostname -s)`),
  port and key through `-o sftp.command`, password from
  `RESTIC_PASSWORD_FILE` (default `/etc/backup/restic.pass`). Initialize the
  repository on the first run (not in a dry run).
- The directories to back up, excludes, target settings (user, host, port,
  SSH key), repository, retention and log file are stored in a configuration
  file (default `/etc/backup/backup.conf`, outside the repository so it
  survives `git pull` or a fresh clone; changeable via `-c` or
  `BACKUP_CONF`).
- Option `--init-config` creates a commented sample configuration (embedded
  in the script, so a single file is enough to get started), preset for the
  Storage Box (port 23, host derived from `REMOTE_USER`).
- Dry run with `-n`, help with `-h`, version with `-V`.
- One snapshot per source with `--host <BACKUP_NAME>`; show in the log which
  one is running (`[n/total]`), keep going if one fails and report the failed
  sources at the end. Treat restic code 3 as a warning and skip retention
  after it to preserve previous snapshots. Recovery commands must work even
  if the configured sources no longer exist.
- Retention via `forget --host <BACKUP_NAME> --prune` with
  `RESTIC_FORGET_OPTS`, default staggered
  `--keep-daily 7 --keep-weekly 5 --keep-monthly 12`; empty = never delete.
- `--restic ARGS...` passes arguments to restic with the configured settings
  (snapshots, restore, mount, check, ...).
- Prevent parallel runs via `flock` on the configuration file. Default log
  `/var/log/backup/backup.log`, configurable; use restrictive file permissions
  and clear console fallback warnings. Prefix lines with ISO timestamp,
  severity, run ID and phase, including child command output. Log action
  durations/exit codes; emit a single summary after post actions with status,
  duration and successful/failed source counts. Preserve terminal progress.
  Supply a daily logrotate configuration (30 archives, max age 30 days,
  compression). Never print password contents. Use `set -euo pipefail`.

- Do not run shell commands on the target, only SFTP, so that the Hetzner
  Storage Box with its restricted shell works too.
- At startup, check whether `restic` is available; install it as root via
  `apt-get`, otherwise (without root, without apt, during a dry run) abort
  with a clear message.
- Option `-v` / `--progress` for a live progress display, only on a terminal
  (otherwise ignored with a note): restic writes stdout directly to the
  terminal so it draws its own progress bar, errors are still logged.
- Configurations from older versions: abort with a hint if
  `BACKUP_METHOD` is set to anything but `restic` (the rsync method was
  removed in 4.0.0); still honour `REMOTE_BASE` for the default repository
  path; `--restore-perms` explains how to use `setfacl --restore` instead.
- Mail notification via `sendmail` to `MAIL_TO` (optional `MAIL_FROM`):
  `FAILED` on any error exit (also configuration errors, signals),
  `WARNING` if a successful run collected warnings; body with error,
  warnings and the log of this run (last 200 lines); none in a dry run;
  `--test-mail` sends a test mail. Before the backup, check the free space
  on the target with `df` in sftp (no shell needed) and warn below
  `MIN_FREE_PERCENT` (default 5, 0 = off); if `df` fails, only log a note.
- Execute local scripts directly from `wrappers/pre/` and `wrappers/post/`
  beside the resolved `backup.sh` (`WRAPPERS_DIR` configurable; empty disables).
  Use ascending C-locale filename order, separate processes, executable files
  only; warn with a file path and `chmod +x` hint when a file is not
  executable. Pre failure skips backup; all post scripts run after preparation starts,
  including on errors/signals. Preserve failure status, log output and mail
  action failures. Export BACKUP_CONFIG, BACKUP_NAME and BACKUP_EXIT_CODE.
  Lock the whole lifecycle and check source existence after pre actions.
  Skip actions for dry runs and administrative commands. Check root ownership
  and writable permissions when executing as root. Ignore user action files in
  Git but track directory placeholders and a guide. Old hooks/pre.d and post.d
  remain inactive and generate a migration warning.
- Work under cron's minimal `PATH` (add the sbin directories so `sendmail`
  and commands used by custom actions are found).
- Provide installable `units/backup.service` and `units/backup.timer` for daily
  root backups at 02:30 local time, randomized delay 15 minutes and persistent
  catch-up. Service runs `/opt/backup/backup.sh`, logs to the journal, has no
  startup time limit and allows five minutes to stop. Document installation,
  verification, schedule/config overrides, updates and disabling the timer.
- Publish atomic numeric JSON status after cleanup for each real run to
  STATUS_FILE (default `/var/lib/backup/status.json`, empty disables), with
  mode 644 and newly created status directory mode 755. Hold the configuration
  lock until status publication; dry runs/admin commands and rejected concurrent
  runs must not overwrite previous status. Provide a Python 3 Nagios check
  with standard exit codes, 30h warning/36h critical age thresholds by default,
  performance data and an NRPE example. Missing status is critical; invalid or
  unreadable status is unknown. Never source status files or include credentials.
- Use explicit placeholders for personal usernames and hosts in documentation
  and sample configurations; do not embed real account details.
- All output, comments and documentation in English.

Also provide README.md (how it works, setup, configuration, local actions, mail,
systemd timer, restoring), CHANGELOG.md and this PROMPT.md in the repository
`BackupStorageBox`.
