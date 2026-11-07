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
- Prevent parallel runs via `flock` on the configuration file, log with
  timestamps, `set -euo pipefail`, shellcheck-clean.
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
  only. Pre failure skips backup; all post scripts run after preparation starts,
  including on errors/signals. Preserve failure status, log output and mail
  action failures. Export BACKUP_CONFIG, BACKUP_NAME and BACKUP_EXIT_CODE.
  Lock the whole lifecycle and check source existence after pre actions.
  Skip actions for dry runs and administrative commands. Check root ownership
  and writable permissions when executing as root. Ignore user action files in
  Git but track directory placeholders and a guide. Old hooks/pre.d and post.d
  remain inactive and generate a migration warning.
- Wrapper `nextcloud-backup.sh [--check] [backup.sh options]` next to
  `backup.sh`: detect the installation (folder with `occ`), its user (owner
  of `config/config.php`) and the PHP version the web server uses (running
  php-fpm, Apache mod_php, FPM sockets in the web server configuration;
  verified with `occ status`, falling back to other installed versions);
  enable maintenance mode, dump the database with the credentials from the
  Nextcloud configuration (MySQL/MariaDB via a temporary option file,
  PostgreSQL, SQLite via `sqlite3 .backup`, never a plain copy) to `/var/backups/nextcloud` (`.tmp` + `mv`), run
  `backup.sh` with the given options, and always end maintenance mode in an
  EXIT trap (also on signals and if it was on before). Warn if the config,
  data or dump folder is missing from `SOURCES`. `-n`: no maintenance mode
  and no dump, `backup.sh -n`. Mail to `MAIL_TO` of the backup
  configuration on failures before the backup, when maintenance mode could
  not be ended, and on warnings – not on failures of `backup.sh`, which
  mails them itself. Optional overrides in `nextcloud.conf` next to the
  backup configuration.
- Both scripts must work under cron's minimal `PATH` (add the sbin
  directories so `runuser` and `sendmail` are found).
- All output, comments and documentation in English.

Also provide README.md (how it works, setup, configuration, Nextcloud, mail,
systemd timer, restoring), CHANGELOG.md and this PROMPT.md in the repository
`BackupStorageBox`.
