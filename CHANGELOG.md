# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning according to [SemVer](https://semver.org/).

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
