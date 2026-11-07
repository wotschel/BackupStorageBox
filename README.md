# backup.sh

Daily backup of selected directories over SSH to a remote server, with one of
two methods selected in the configuration (`BACKUP_METHOD`):

| | `rsync` (default) | `restic` |
|---|---|---|
| Storage | one plain folder per day, unchanged files hard-linked | encrypted repository with snapshots |
| Restore | any tool (rsync, SFTP client, Hetzner web UI) | needs `restic` (`backup.sh --restic ...`) |
| Encryption | none | yes, client-side (password file) |
| Deduplication | whole unchanged files only | blocks, across files and renames |
| Compression | no | yes |
| Owners/groups on the Storage Box | via `getfacl` file, restored with `--restore-perms` | stored in the repository |
| Retention | `KEEP_DAYS` (30 days) | staggered: 7 daily, 5 weekly, 12 monthly (`RESTIC_FORGET_OPTS`) |

Both methods run **no shell commands** on the target – only rsync or SFTP – so
restricted targets like the Hetzner Storage Box work.

## Method rsync

### Layout on the target server

```
<REMOTE_BASE>/<BACKUP_NAME>/
├── 2026-11-05/          complete snapshot of Nov 5
├── 2026-11-06/          complete snapshot of Nov 6 (hard links to Nov 5)
├── 2026-11-07/
│   ├── .backup-complete         completion marker
│   ├── .backup-perms.facl.gz    owners, permissions, ACLs (getfacl)
│   ├── etc/ ...
└── latest -> 2026-11-07
```

Source paths are preserved (`/etc` ends up in `2026-11-07/etc`). Every daily
folder is a complete snapshot but only takes up the space of the changed files.

A day only counts as finished once rsync has succeeded; then the file
`.backup-complete` is created. Only such folders serve as hard-link base, so an
aborted run does not corrupt the next one. If a day is missing, the script
automatically links against the last complete backup. Listing, marking,
setting `latest` and cleanup are done exclusively through rsync.

## Method restic

The repository is reached via SFTP at `RESTIC_REPO_PATH` (default
`<REMOTE_BASE>/restic-<BACKUP_NAME>`, i.e. `restic-sv32` in the box's home).
The first run initializes it automatically. Each source becomes its own
snapshot (host = `BACKUP_NAME`), so the log shows progress per source and a
failing source does not affect the others. Afterwards
`restic forget --prune` removes old snapshots of this host according to the
staggered retention (see "Configuration").

The repository password is read from `RESTIC_PASSWORD_FILE` (default
`/etc/backup/restic.pass`). **Without this password all backups are lost** –
keep a copy outside the server, e.g. in a password manager.

## Requirements

- Ubuntu 26.04 LTS or newer
- SSH access by key without password prompt (`BatchMode=yes`)
- On the target, rsync or SFTP is enough; no shell is needed
- Packages, depending on the method: `rsync` and `acl` (`getfacl`/`setfacl`),
  or `restic`. If they are missing, the script installs them itself via
  `apt-get` when running as root. Without root or during a dry run it aborts
  with a hint instead, before anything is transferred.
- rsync method: target file system that supports hard links (the Storage Box does)

## Setup

The script runs directly from a clone of the repository; the configuration
lives separately in `/etc/backup/`. Updating is therefore just a `git pull`,
and the repository can be deleted and cloned again at any time without losing
the configuration.

```bash
# 1. Create an SSH key for the backup and deploy it to the Storage Box
sudo ssh-keygen -t ed25519 -f /root/.ssh/backup_ed25519 -N ""
sudo ssh-copy-id -p 23 -s -i /root/.ssh/backup_ed25519 u712238@u712238.your-storagebox.de

# 2. Clone the repository and link the script
sudo git clone https://github.com/wotschel/BackupStorageBox.git /opt/backup
sudo ln -s /opt/backup/backup.sh /usr/local/sbin/backup.sh

# 3. Create the sample configuration and adjust it
sudo backup.sh --init-config          # -> /etc/backup/backup.conf
sudo nano /etc/backup/backup.conf       # BACKUP_METHOD, SOURCES, EXCLUDES, KEEP_DAYS

# 3a. Only for restic: create the repository password – and store a copy safely!
sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /etc/backup/restic.pass'

# 4. Dry run, then a real run
sudo backup.sh -n
sudo backup.sh
```

Update later with:

```bash
sudo git -C /opt/backup pull
```

## Configuration

The file is sourced as Bash (hence `chmod 600`, owned by root). Defaults below
are the script's built-in values; the sample from `--init-config` is preset
for the Storage Box (see below).

| Variable      | Meaning                                           | Default |
|---------------|---------------------------------------------------|---------|
| `BACKUP_METHOD` | `rsync` or `restic`                             | `rsync` |
| `REMOTE_USER` | User on the target server                         | –       |
| `REMOTE_HOST` | Target server                                     | –       |
| `SSH_PORT`    | SSH port                                          | `22`    |
| `SSH_KEY`     | Path to the private key (without spaces)          | empty   |
| `REMOTE_BASE` | Base directory on the target server               | `/home` |
| `BACKUP_NAME` | Folder (rsync) or restic host name per machine    | `hostname -s` |
| `SOURCES`     | Array of directories to back up (absolute)        | –       |
| `EXCLUDES`    | Array of exclude patterns                         | empty   |
| `KEEP_DAYS`   | rsync retention in days, `0` = never delete       | `30`    |
| `LOG_FILE`    | Log file                                          | `/var/log/backup.log` |
| `HOOKS_DIR`   | Folder with `pre.d/` and `post.d/`, see "Hooks"   | `hooks` next to the configuration |
| `HOOK_TIMEOUT` | Time limit per hook in seconds, `0` = none       | `3600`  |
| **rsync only** | | |
| `RSYNC_OPTS`  | rsync options                                     | `-aHAX --numeric-ids --delete --delete-excluded` |
| `SAVE_PERMS`  | Additionally save permissions via getfacl (1/0)   | `1`     |
| **restic only** | | |
| `RESTIC_REPO_PATH` | Repository path on the target                | `<REMOTE_BASE>/restic-<BACKUP_NAME>` |
| `RESTIC_PASSWORD_FILE` | File containing the repository password  | `/etc/backup/restic.pass` |
| `RESTIC_FORGET_OPTS` | Array of `restic forget` policies           | `--keep-daily 7 --keep-weekly 5 --keep-monthly 12` |

`EXCLUDES` are rsync patterns; for restic a trailing `/` is dropped
(`.cache/` becomes `.cache`, which restic matches as a name anywhere).

`-A` (ACLs) and `-X` (extended attributes) in `RSYNC_OPTS` require root on the
target server. If you write there as a regular user, remove them.

### restic retention

By default restic keeps a staggered history of about one year:

```bash
RESTIC_FORGET_OPTS=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)
```

- the last snapshot of each of the last 7 days,
- the last snapshot of each of the last 5 weeks,
- the last snapshot of each of the last 12 months.

Thanks to deduplication this costs little more space than a few days. Any
`restic forget` policy can be used (e.g. add `--keep-yearly 3`). With
`RESTIC_FORGET_OPTS=()` restic falls back to `KEEP_DAYS`
(`--keep-within <KEEP_DAYS>d`); with both empty/`0`, nothing is deleted.

Several machines may share one restic repository (same `RESTIC_REPO_PATH`
and password) to deduplicate across them; snapshots and retention stay
separate per `BACKUP_NAME`.

### Hetzner Storage Box

The sample configuration from `--init-config` is already set up for the
Storage Box `u712238` (port 23, `REMOTE_BASE="."`, no `-A`/`-X`, key
`/root/.ssh/backup_ed25519`). The host is derived from `REMOTE_USER`. The
relevant values:

```bash
REMOTE_USER="u712238"
REMOTE_HOST="u712238.your-storagebox.de"
SSH_PORT=23
REMOTE_BASE="."          # relative to the box's home
RSYNC_OPTS=(-aH --numeric-ids --delete --delete-excluded)   # without -A/-X
```

SSH support must be enabled in the Hetzner Console. Deploy the key with
`ssh-copy-id -p 23 -s u712238@u712238.your-storagebox.de` (`-s` uses SFTP,
because the box has no shell). With rsync, the box is not written to as root,
so owners and groups of the files are not preserved; permissions are. That is
what the permissions file is for, see "Restoring permissions". restic stores
owners and groups in the repository, so this does not apply there.

## Usage

```
backup.sh [-c FILE] [-n] [-v] [-h] [-V] [--init-config [FILE]]
backup.sh --restore-perms FILE [TARGET_ROOT] [-n]
backup.sh [-c FILE] --restic RESTIC-ARGS...
```

| Option | Effect |
|---|---|
| `-c FILE` | different configuration (alternatively `BACKUP_CONF=...`); default `/etc/backup/backup.conf` |
| `-n` | dry run, nothing is changed |
| `-v` / `--progress` | live progress display (terminal only, see below) |
| `--init-config [FILE]` | write a sample configuration |
| `--restore-perms FILE [TARGET_ROOT]` | rsync method: restore permissions, see below |
| `--restic ARGS...` | run restic with the configured repository, password and SSH settings |
| `-h` / `-V` | help / version |

Exit code `0` on success, `1` on error. rsync code 24 (files vanished during
the backup) counts as success and is only logged; the same applies to restic
code 3 (some files could not be read), which is logged as a warning. Parallel
runs are prevented by a `flock` lock.

Each source is transferred separately, and the log shows the progress:

```
[1/3] Backing up /etc ...
[1/3] /etc done.
[2/3] Backing up /home ...
```

If one source fails, the others still run. At the end the backup then counts
as incomplete, and the failed sources are listed.

### Progress display (`-v`)

```bash
sudo backup.sh -v
```

- **rsync:** an overall progress line per source (`--info=progress2`) with
  bytes, percentage, speed and remaining files. The log only receives the
  final state of that line, not every update. `--no-inc-recursive` is used so
  the total is known from the start; for very large trees this needs some
  more memory and a short scan before the transfer starts.
- **restic:** restic's own progress bar (files, bytes, ETA). It is only drawn
  when restic writes directly to the terminal, so with `-v` restic's normal
  output (including its summary) goes to the terminal only; the script's own
  log lines and restic's error messages are still logged.

Without a terminal (systemd, cron, output redirected) `-v` is ignored with a
note, so the journal stays clean.

## Hooks

Hooks run commands before and after the backup, e.g. dump databases or put
an application into maintenance mode. They are executable files in two
folders next to the configuration. The first run creates them if they are
missing (as does `--init-config`):

```
/etc/backup/hooks/
├── pre.d/      before the backup
│   ├── 10-nextcloud-maintenance-on
│   └── 20-mysqldump
└── post.d/     after the backup – always
    └── 90-nextcloud-maintenance-off
```

- Files run in lexical order, so prefix them with numbers. Their output
  goes to the log.
- **pre.d:** if a hook fails (exit code ≠ 0 or timeout), the remaining pre
  hooks are skipped and the backup is aborted.
- **post.d:** they run **always** once the pre phase has started – after a
  successful backup, after an error, a failed pre hook and also when the
  run is interrupted (`Ctrl+C`, `systemctl stop`). So everything a pre hook
  switches on, a post hook can reliably switch off again. A failing post
  hook makes the whole run exit with code 1.
- Environment: `BACKUP_PHASE` (`pre`/`post`), `BACKUP_NAME`,
  `BACKUP_METHOD`, `BACKUP_CONFIG`, `BACKUP_LOG_FILE`; post hooks
  additionally get `BACKUP_RESULT` (`success`/`failure`) and
  `BACKUP_EXIT_CODE`.
- Each hook may run at most `HOOK_TIMEOUT` seconds (default 3600).
- When the script runs as root, a hook must be owned by root and must not
  be writable by group or others; otherwise it is refused (and counts as
  failed).
- Non-executable files are skipped with a note, so `chmod -x` disables a
  hook. Hidden files and `*~`, `*.bak`, `*.disabled`, `*.dpkg-*` are
  ignored.
- A dry run (`-n`) only lists the hooks, it does not run them.
- Hooks get no input (`stdin` is `/dev/null`).
- Signals: a hook that is currently running is finished first, then the
  post hooks run. Under systemd the running hook receives the `SIGTERM`
  itself.

### Example: Nextcloud with MariaDB/MySQL

`pre.d/10-nextcloud-maintenance-on`
```bash
#!/bin/sh
set -e
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on
```

`pre.d/20-mysqldump` – the dump folder must be in `SOURCES`
```bash
#!/bin/sh
set -e
umask 077
mkdir -p /var/backups/mysql
# Credentials from /root/.my.cnf (or socket authentication as root)
mysqldump --all-databases --single-transaction --routines --events \
    | gzip > /var/backups/mysql/all-databases.sql.gz.tmp
mv /var/backups/mysql/all-databases.sql.gz.tmp /var/backups/mysql/all-databases.sql.gz
```

`post.d/90-nextcloud-maintenance-off`
```bash
#!/bin/sh
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
```

```bash
sudo chmod 755 /etc/backup/hooks/*/*
sudo chown root:root /etc/backup/hooks/*/*
# and in backup.conf: SOURCES+=("/var/backups/mysql")
```

Without `pipefail` in `sh`, a failing `mysqldump` would not be noticed in
the pipe; with Bash use `#!/bin/bash` and `set -eo pipefail` instead. The
`.tmp` file and `mv` make sure a broken dump never replaces the last good
one.

## Running daily (systemd timer)

`/etc/systemd/system/backup.service`
```ini
[Unit]
Description=Daily backup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/backup/backup.sh
Nice=10
IOSchedulingClass=idle
```

`/etc/systemd/system/backup.timer`
```ini
[Unit]
Description=Daily backup

[Timer]
OnCalendar=*-*-* 02:30
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now backup.timer
systemctl list-timers backup.timer
journalctl -u backup.service
```

`Persistent=true` catches up on a missed run, e.g. if the machine was off at
night. Alternatively via cron: `30 2 * * * /opt/backup/backup.sh`.

## Restoring (rsync)

Each daily folder is a normal directory tree:

```bash
# Restore a single file from Nov 5
sudo rsync -e 'ssh -p23 -i /root/.ssh/backup_ed25519' \
    u712238@u712238.your-storagebox.de:sv32/2026-11-05/etc/fstab /tmp/

# Whole directory from the latest snapshot
sudo rsync -aH -e 'ssh -p23 -i /root/.ssh/backup_ed25519' \
    u712238@u712238.your-storagebox.de:sv32/latest/home/alice/ /home/alice/
```

### Restoring permissions

Before copying, the script uses `getfacl` to write owner, group, mode and ACLs
of all files and directories in the sources to `.backup-perms.facl.gz`. The
paths in it are relative (`etc/shadow`), so they can be applied to any target
root. This matters most when the target cannot store owners, as with the
Storage Box.

```bash
# Fetch the permissions file from the target
sudo rsync -e 'ssh -p23 -i /root/.ssh/backup_ed25519' \
    u712238@u712238.your-storagebox.de:sv32/2026-11-05/.backup-perms.facl.gz /tmp/

# Check first, then apply (as root)
sudo backup.sh --restore-perms /tmp/.backup-perms.facl.gz /mnt/restore -n
sudo backup.sh --restore-perms /tmp/.backup-perms.facl.gz /mnt/restore
```

Without a target root, `/` is used. Entries for files missing in the target
(e.g. due to excludes) are skipped and only counted. With `SAVE_PERMS=0` the
permissions file is not created, and `acl` is not needed either.

## Restoring (restic)

`backup.sh --restic` passes all following arguments to restic, with
repository, password and SSH settings taken from the configuration:

```bash
# List snapshots
sudo backup.sh --restic snapshots

# Restore /etc from the latest snapshot into /mnt/restore
sudo backup.sh --restic restore latest --path /etc --target /mnt/restore

# Single file from a specific snapshot
sudo backup.sh --restic restore 1a2b3c4d --include /etc/fstab --target /tmp/restore

# Browse all snapshots as a file system
sudo mkdir -p /mnt/restic && sudo backup.sh --restic mount /mnt/restic

# Verify the repository (add --read-data to check all data; slow)
sudo backup.sh --restic check
```

Owners, groups, permissions, ACLs and extended attributes are restored by
restic itself (as root).

## Notes

- rsync: hard links share their content – if you *edit* a file in a daily
  folder on the server, you change it in all days. Only read backups.
- rsync: `du -sh` across all days counts hard links only once;
  `du -sh 2026-11-07` alone shows the full size.
- rsync backups are not encrypted. For an off-site target, use the restic
  method or an encrypted file system.
- Switching `BACKUP_METHOD` does not migrate or delete existing backups; both
  can coexist on the same box (`sv32/` and `restic-sv32/`).
- Dump databases beforehand and back up the dump, not the live files – a
  pre hook does that automatically, see "Hooks".
