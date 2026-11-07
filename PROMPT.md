# Prompt

Reconstructed prompt that can be used to generate this script:

---

Write a Bash script `backup.sh` for Ubuntu 26.04 LTS or newer that creates a
daily backup via rsync over SSH to a remote server.

Requirements:

- Target path: `<REMOTE_BASE>/<BACKUP_NAME>/<YYYY-MM-DD>`, defaults
  `REMOTE_BASE=/home` and `BACKUP_NAME=$(hostname -s)`.
- Create unchanged files as hard links to the last complete backup via
  `--link-dest` (usually the previous day; if a day is missing, the most
  recent existing one).
- A day only counts as complete after a successful rsync (marker file); only
  complete backups serve as hard-link base. Symlink `latest` pointing to the
  most recent complete backup.
- The directories to back up, excludes, target settings (user, host, port,
  SSH key), retention in days, rsync options and log file are stored in a
  configuration file (default `/etc/backup/backup.conf`, outside the
  repository so it survives `git pull` or a fresh clone; changeable via `-c`
  or `BACKUP_CONF`). Preserve
  source paths at the target (`--relative`).
- Option `--init-config` creates a commented sample configuration (embedded
  in the script, so a single file is enough to get started).
- Dry run with `-n`, help with `-h`, version with `-V`.
- Delete old backups after `KEEP_DAYS` (0 = never).
- Prevent parallel runs via `flock`, treat rsync code 24 as success, log with
  timestamps, `set -euo pipefail`, shellcheck-clean.
- Do not run shell commands on the target, do everything through rsync
  (`--list-only`, `--delete` with filters), so that the Hetzner Storage Box
  with its restricted shell works too.
- Transfer each source separately with rsync and show in the log which one is
  currently running (`[n/total]`); report failed sources at the end.
- Before copying, save owners, groups, permissions and ACLs with `getfacl`
  (relative paths) into `.backup-perms.facl.gz` in the daily folder
  (`SAVE_PERMS`), and be able to restore them via
  `--restore-perms FILE [TARGET_ROOT]` with `setfacl --restore`, including a
  dry run with `-n`.
- At startup, check whether `rsync` and (if permissions backup is active)
  `acl` are available; install missing packages as root via `apt-get`,
  otherwise (without root, without apt, during a dry run) abort with a clear
  message.
- Alternatively back up with restic, selected via `BACKUP_METHOD="rsync"` or
  `"restic"` in the configuration (default rsync): repository via SFTP at
  `RESTIC_REPO_PATH` (default `<REMOTE_BASE>/restic-<BACKUP_NAME>`), port and
  key through `-o sftp.command`, password from `RESTIC_PASSWORD_FILE`;
  initialize the repository on the first run (not in a dry run); one snapshot
  per source with `--host <BACKUP_NAME>` and `[n/total]` progress; retention
  via `forget --prune` with `RESTIC_FORGET_OPTS`, default staggered
  `--keep-daily 7 --keep-weekly 5 --keep-monthly 12` (if empty, fall back to
  `--keep-within <KEEP_DAYS>d`); treat restic code 3 as a warning; `--restic ARGS...`
  passes arguments to restic with the configured settings (for restore etc.);
  install `restic` like the other dependencies.
- Option `-v` / `--progress` for a live progress display, only on a terminal
  (otherwise ignored with a note): rsync with `--info=progress2
  --no-inc-recursive`, only the final state of the progress line goes to the
  log; restic writes stdout directly to the terminal so it draws its own
  progress bar, errors are still logged.
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
