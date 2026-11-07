# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning according to [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Atomic numeric monitoring status after real backups, including pre/post
  failures; configurable `STATUS_FILE` with read access for monitoring agents.
- Nagios-compatible Python check with failure/warning states, stale backup
  thresholds, performance data and an NRPE command example.
- Installable systemd service/timer in `units/`, with scheduling, drop-in
  customization, update and troubleshooting instructions.
- Structured logging with ISO timestamps, severity, unique run IDs and phases,
  including captured restic/action output and action duration/exit codes.
- Final status and source counts after post actions, including failure paths.
- Daily logrotate configuration with 30 archives, max age 30 days and compression.

### Changed
- Replace personal Storage Box account details and machine names in examples
  with explicit placeholders.
- Default log path is `/var/log/backup/backup.log`; new files/directories use
  restrictive permissions. Existing configured paths remain supported.
- Mail excerpts select the run ID instead of byte offsets in a shared log.

### Fixed
- Warn when local pre/post action files lack execute permission, including
  the file path and a `chmod +x` hint, instead of silently skipping them.

### Removed
- `nextcloud-backup.sh` and its setup instructions. Application-specific
  preparation and cleanup belong in local `wrappers/pre/` and `wrappers/post/`
  scripts. Existing scheduled calls to the Nextcloud wrapper must be updated
  to `backup.sh` after implementing the required local actions.

## [5.1.0] – 2026-11-07

### Added
- Local executable actions in `wrappers/pre/` and `wrappers/post/`, run by
  `backup.sh` in deterministic filename order under its configuration lock.
- Post actions on failures/signals after preparation starts; all cleanup
  actions run even if one fails. Action output is logged and failures mailed.
- `WRAPPERS_DIR` override and action environment with backup status/config/name.
- Git-ignored user scripts with tracked directory placeholders and guide.
- Regression coverage for ordering, errors, cleanup, dry runs and new sources.

### Changed
- Validate source existence after pre actions so they can create dump directories.
- Dry runs and administrative commands skip local actions.

## [5.0.2] – 2026-11-07

### Fixed
- Recovery commands and mail tests no longer require existing backup sources.
- Skip retention and pruning after restic exit code 3 to preserve earlier history.
- Abort Nextcloud configuration loading on errors instead of continuing with defaults.
- Require SQLite's backup function instead of falling back to a potentially
  incomplete database file copy; check dump coverage for SQLite too.
- Clarify storage requirements and the built-in log default in the README.

### Added
- Isolated regression tests for recovery, source validation, retention and
  Nextcloud configuration errors.

## [5.0.1] – 2026-11-07

### Fixed
- Under cron (`PATH=/usr/bin:/bin`) `runuser` and `sendmail` in `/usr/sbin`
  were not found: `nextcloud-backup.sh` failed and failure mails were
  silently skipped. Both scripts now add the sbin directories to `PATH`.

### Added
- README: section on running the backup via cron.

## [5.0.0] – 2026-11-07

### Removed
- **Hooks** (`pre.d/`, `post.d/`, `HOOKS_DIR`, `HOOK_TIMEOUT`, the hook
  folders created by `--init-config` and the first run) and the ready-made
  hooks in `hooks/`. Steps before and after the backup now belong in a
  wrapper script; `backup.sh` is down to about 500 lines

### Added
- `nextcloud-backup.sh`: wrapper replacing the Nextcloud hooks – same
  detection (installation, user, PHP version, database), maintenance mode
  on, database dump, `backup.sh` with all given options, maintenance mode
  always off in an EXIT trap. `--check` shows the detection, `-n` is a dry
  run without maintenance mode and dump. Mails failures before the backup,
  a maintenance mode that could not be ended, and warnings
- Warning (and mail) if the old hook folders still contain files, so they
  are not silently ignored

### Migration
- Delete `/etc/backup/hooks/` and run `nextcloud-backup.sh` instead of
  `backup.sh` (systemd: `ExecStart=/opt/backup/nextcloud-backup.sh`);
  `/etc/backup/nextcloud.conf` keeps working
- The state file `/var/lib/backup/nextcloud.state` is no longer used and
  can be deleted

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
  `/root/.ssh/backup_ed25519`) with user `YOUR_STORAGEBOX_USER`; `REMOTE_HOST` is derived
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
