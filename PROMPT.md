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
  sources at the end. Treat restic code 3 as a warning.
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
- Pre and post hooks: run the executable files in `<HOOKS_DIR>/pre.d/`
  before and in `<HOOKS_DIR>/post.d/` after the backup, in lexical order,
  output to the log (`HOOKS_DIR` default: `hooks` next to the configuration
  file; `--init-config` and every backup run create missing folders). A failing pre hook aborts
  the backup; post hooks always run once the pre phase has started, also on
  errors and signals (EXIT trap), with `BACKUP_RESULT` and
  `BACKUP_EXIT_CODE` in the environment, and a failing post hook makes the
  run fail. Per-hook timeout `HOOK_TIMEOUT` (default 3600 s); as root, refuse
  hooks not owned by root or writable by group/others; skip non-executable
  files with a note; in a dry run only list the hooks.
- Mail notification via `sendmail` to `MAIL_TO` (optional `MAIL_FROM`):
  `FAILED` on any error exit (also configuration errors, hooks, signals),
  `WARNING` if a successful run collected warnings; body with error,
  warnings and the log of this run (last 200 lines); none in a dry run;
  `--test-mail` sends a test mail. Before the backup, check the free space
  on the target with `df` in sftp (no shell needed) and warn below
  `MIN_FREE_PERCENT` (default 5, 0 = off); if `df` fails, only log a note.
- Ready-made hooks in the repository: `hooks/pre.d/10-nextcloud` and
  `hooks/post.d/90-nextcloud`. The pre hook detects the installation
  (folder with `occ`), its user (owner of `config/config.php`) and the PHP
  version the web server uses (running php-fpm, Apache mod_php, FPM sockets
  in the web server configuration; verified with `occ status`, falling back
  to other installed versions), enables maintenance mode and dumps the
  database with the credentials from the Nextcloud configuration
  (MySQL/MariaDB via a temporary option file, PostgreSQL, SQLite) to
  `/var/backups/nextcloud` (`.tmp` + `mv`). It warns if the config, data or
  dump folder is missing from `SOURCES` and has a `--check` mode. The post
  hook always ends maintenance mode (also if it was on before), using the
  installation, user and PHP binary the pre hook stored in a state file in
  `/var/lib/backup`. Optional overrides in
  `/etc/backup/nextcloud.conf`.
- All output, comments and documentation in English.

Also provide README.md (how it works, setup, configuration, hooks, mail,
systemd timer, restoring), CHANGELOG.md and this PROMPT.md in the repository
`BackupStorageBox`.
