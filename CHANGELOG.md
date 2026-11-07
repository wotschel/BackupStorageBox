# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning according to [SemVer](https://semver.org/).

## [4.0.0] – 2026-11-07

### Removed
- **The rsync method.** restic is the only backup method now; the script
  shrinks from 828 to about 600 lines. Removed with it: `BACKUP_METHOD`,
  `KEEP_DAYS`, `RSYNC_OPTS`, `SAVE_PERMS`, `--restore-perms`, the
  permissions file and the `rsync`/`acl` dependencies
- `KEEP_DAYS` as fallback retention for restic: `RESTIC_FORGET_OPTS=()` now
  means "never delete"; for a fixed number of days use
  `RESTIC_FORGET_OPTS=(--keep-within 30d)`
- `BACKUP_METHOD` in the hook environment and the "Method" line in mails
  (replaced by "Repository")

### Changed
- Default `RESTIC_REPO_PATH` is `restic-<BACKUP_NAME>` in the SSH user's
  home; `REMOTE_BASE` is no longer in the sample configuration but still
  honoured if set
- Sample configuration: restic settings first, excludes written as restic
  patterns (`.cache` instead of `.cache/`)

### Migration
- A configuration with `BACKUP_METHOD="rsync"` makes the script abort with
  a hint; `BACKUP_METHOD="restic"` is still accepted. Other old settings
  are ignored
- Existing rsync daily folders on the target are left untouched; delete
  them yourself when no longer needed (see README, "Migrating from rsync")

## [3.6.1] – 2026-11-07

### Changed
- The sample configuration from `--init-config` also backs up `/opt`
  (existing configurations are not changed)

## [3.6.0] – 2026-11-07

### Added
- Ready-made Nextcloud hooks `hooks/pre.d/10-nextcloud` and
  `hooks/post.d/90-nextcloud`:
  - detect installation, web server user and the PHP version in use
    (php-fpm, Apache mod_php, web server configuration; verified with
    `occ status`, falls back to other installed versions)
  - maintenance mode on before, always off after the backup – also after a
    failed one and if it was already on before
  - database dump with the credentials from the Nextcloud configuration
    (MySQL/MariaDB, PostgreSQL, SQLite) to `/var/backups/nextcloud`
  - warn if config, data or dump folder is missing from `SOURCES`
  - `--check` shows what was detected without changing anything
  - optional overrides in `/etc/backup/nextcloud.conf`

### Changed
- PROMPT.md: dropped the four-files-per-script rule from the original
  `scripts` repository

## [3.5.0] – 2026-11-07

### Added
- Mail notification to `MAIL_TO` (comma-separated, optional `MAIL_FROM`)
  via `sendmail` (e.g. msmtp-mta, nullmailer, postfix):
  - `[backup] FAILED: <name>` when a run ends with an error – including
    configuration errors, failed hooks and interrupted runs
  - `[backup] WARNING: <name>` when a successful run had warnings
  - the mail contains the error, the warnings and the log of this run
    (last 200 lines); no mails in a dry run
  - `--test-mail` sends a test mail
- Free-space check before the backup: less than `MIN_FREE_PERCENT`
  (default 5, `0` = off) free on the target is a warning. Uses `df` in
  sftp, so no shell is needed on the target (the Storage Box reports its
  quota there); if it cannot be determined, only a note is logged

### Changed
- These are now warnings (and trigger a mail): restic exit code 3 (some
  files unreadable), failed removal of old snapshots/backups

### Fixed
- After post hooks had run, errexit was active again in the exit handler

## [3.4.1] – 2026-11-07

### Changed
- A backup run creates the missing hook folders `<HOOKS_DIR>/pre.d/` and
  `post.d/` itself (not in a dry run), so existing installations need no
  manual `mkdir`; if that is not possible, it continues without hooks

## [3.4.0] – 2026-11-07

### Added
- Pre and post hooks: executable files in `<HOOKS_DIR>/pre.d/` run before
  the backup, those in `<HOOKS_DIR>/post.d/` afterwards, each in lexical
  order with their output in the log (e.g. database dumps, Nextcloud
  maintenance mode)
  - `HOOKS_DIR` defaults to the `hooks` folder next to the configuration
    (`/etc/backup/hooks`); `--init-config` creates `pre.d/` and `post.d/`
  - a failing pre hook aborts the backup; post hooks always run once the pre
    phase has started, also after errors, `SIGINT`, `SIGTERM` and `SIGHUP`,
    and get `BACKUP_RESULT=success|failure` and `BACKUP_EXIT_CODE`
  - a failing post hook makes the run exit with code 1
  - `HOOK_TIMEOUT` (default 3600 s, `0` = no limit) per hook
  - as root, hooks not owned by root or writable by group/others are refused
  - non-executable files are skipped with a note (`chmod -x` disables a
    hook), as are hidden files and `*~`, `*.bak`, `*.disabled`, `*.dpkg-*`
  - a dry run only lists the hooks it would run

## [3.3.1] – 2026-11-07

### Fixed
- `Permission denied` on `/tmp/backup-<name>.lock` when the lock file had been
  created by another user (Ubuntu's `fs.protected_regular` blocks even root).
  The lock is now held on the configuration file itself (opened read-only),
  so no lock file is created anymore; stale `/tmp/backup-*.lock` files can be
  deleted

## [3.3.0] – 2026-11-07

### Added
- `-v` / `--progress`: live progress display on the terminal
  - rsync: overall progress per source (`--info=progress2 --no-inc-recursive`);
    the log only keeps the final state of the progress line
  - restic: restic's own progress bar; its output then goes to the terminal
    only, the script's log lines and restic errors are still logged
  - ignored with a note when not running on a terminal (systemd, cron)

## [3.2.0] – 2026-11-07

### Changed
- restic now uses a staggered retention by default:
  `RESTIC_FORGET_OPTS=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)`
  (about one year of history). `KEEP_DAYS` only applies to restic when
  `RESTIC_FORGET_OPTS=()` is set; the rsync method is unchanged

## [3.1.0] – 2026-11-07

### Added
- `BACKUP_METHOD` in the configuration selects `rsync` (default, unchanged
  behavior) or `restic`
- restic method: encrypted, deduplicated snapshots via SFTP in
  `RESTIC_REPO_PATH` (default `<REMOTE_BASE>/restic-<BACKUP_NAME>`), password
  from `RESTIC_PASSWORD_FILE`; the repository is initialized on the first run;
  one snapshot per source with progress in the log; retention via
  `forget --prune` with `KEEP_DAYS` or `RESTIC_FORGET_OPTS`; restic code 3
  (unreadable files) is logged as a warning
- `--restic ARGS...` runs restic with the configured repository, password and
  SSH settings (snapshots, restore, mount, check, ...)
- Dependency check installs `restic` when needed

### Changed
- rsync and acl are only required for the rsync method

## [3.0.0] – 2026-11-07

### Changed
- **Breaking:** the default configuration is `/etc/backup/backup.conf` again
  instead of `backup.conf` next to the script, so the repository can be
  updated with `git pull` or re-cloned without touching the configuration.
  Move an existing `backup.conf` there or pass it with `-c` / `BACKUP_CONF`
- Recommended installation: clone the repository to `/opt/backup` and link
  `backup.sh` into `/usr/local/sbin`
- Sample configuration from `--init-config` is preset for the Hetzner Storage
  Box (port 23, `REMOTE_BASE="."`, `RSYNC_OPTS` without `-A`/`-X`, key
  `/root/.ssh/backup_ed25519`) with user `u712238`; `REMOTE_HOST` is derived
  from `REMOTE_USER`

## [2.0.0] – 2026-11-07

### Changed
- **Breaking:** the default configuration is now `backup.conf` in the same
  directory as the script (symlinks are resolved) instead of
  `/etc/backup/backup.conf`. Existing installations should move the file or
  pass it with `-c` / `BACKUP_CONF`
- **Breaking:** all output, log messages, help text, sample configuration and
  documentation are now in English (affects anyone parsing the log)
- Recommended installation location is now `/opt/backup/`

## [1.3.0] – 2026-11-07

### Added
- Dependency check at startup: if `rsync` or (with `SAVE_PERMS=1`) `acl` is
  missing, the script installs it via `apt-get` as root; without root, without
  apt or during a dry run it aborts with a clear message before transferring anything
- Same check for `setfacl` with `--restore-perms`

### Changed
- A missing `getfacl` no longer leads to a backup without permissions file;
  it is installed or causes an abort

## [1.2.0] – 2026-11-07

### Added
- Progress display: each source is backed up and logged separately (`[2/3] Backing up /home ...`)
- Permissions backup via `getfacl` into `.backup-perms.facl.gz` in the daily folder
  (owner, group, mode, ACLs; can be disabled with `SAVE_PERMS=0`)
- `--restore-perms FILE [TARGET_ROOT]` restores permissions via `setfacl --restore`,
  dry run only with `-n`; missing files are skipped

### Changed
- If one source fails, the others continue; the day then stays incomplete

## [1.1.0] – 2026-11-07

### Changed
- No more shell commands on the target: listing (`--list-only`), marker,
  `latest` symlink and deletion of old snapshots run entirely through rsync
- `--link-dest` relative to the daily folder (`../YYYY-MM-DD`)
- Configuration template with notes for the Hetzner Storage Box

### Fixed
- Run failed on the Hetzner Storage Box ("Command not found") because its
  restricted shell does not support loops, `&&` or `ln`

## [1.0.1] – 2026-11-07

### Fixed
- `--init-config` now respects `-c` and `BACKUP_CONF`, regardless of option order
- Understandable error message with a hint to `sudo` if the target directory is not writable
- Clear message if the configuration already exists ("nothing changed")

## [1.0.0] – 2026-11-07

### Added
- Daily backup via rsync over SSH to `<REMOTE_BASE>/<BACKUP_NAME>/<YYYY-MM-DD>`
- Hard links to the last complete backup via `--link-dest`
- Completion marker `.backup-complete`; aborted runs do not serve as base
- Symlink `latest` to the most recent complete backup
- Configuration file with source directories, excludes and target settings
- `--init-config` to create a sample configuration
- Dry run with `-n`
- Deletion of old backups after `KEEP_DAYS`
- Lock against parallel runs via `flock`
- Log file with timestamps
