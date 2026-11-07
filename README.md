# backup.sh

Daily backup of selected directories with [restic](https://restic.net/)
over SFTP to a remote server, preset for the Hetzner Storage Box:

- **encrypted** on the client (repository password), **deduplicated** in
  blocks across files and renames, **compressed**
- one snapshot per source, owners, groups, permissions, ACLs and extended
  attributes included
- **staggered retention**: 7 daily, 5 weekly, 12 monthly snapshots
- **Nextcloud wrapper** `nextcloud-backup.sh`: maintenance mode, database
  dump, backup, maintenance mode off – fully automatic
- **mail** on failure, on warnings and when the target runs out of space

The script runs **no shell commands** on the target – only SFTP – so
restricted targets like the Hetzner Storage Box work.

## How it works

The repository is reached via SFTP at `RESTIC_REPO_PATH` (default
`restic-<BACKUP_NAME>` in the home of the SSH user). The first run
initializes it automatically. Each source becomes its own snapshot
(host = `BACKUP_NAME`), so the log shows progress per source and a failing
source does not affect the others. Afterwards `restic forget --prune`
removes old snapshots of this host according to the retention policy.

A run consists of:

1. check the free space on the target (`MIN_FREE_PERCENT`),
2. restic backup per source, then `forget --prune`,
3. mail if something failed or there were warnings.

Anything that has to happen before or after – dumping a database, putting
an application into maintenance mode – goes into a wrapper script that calls
`backup.sh`, see "Nextcloud" and "Own steps before and after the backup".

The repository password is read from `RESTIC_PASSWORD_FILE` (default
`/etc/backup/restic.pass`). **Without this password all backups are lost** –
keep a copy outside the server, e.g. in a password manager.

## Requirements

- Ubuntu 26.04 LTS or newer
- SSH access by key without password prompt (`BatchMode=yes`)
- SFTP on the target; no shell is needed
- `restic`: if it is missing, the script installs it via `apt-get` when
  running as root. Without root or during a dry run it aborts with a hint
  instead, before anything is transferred.
- for mails: a working `sendmail`, see "Mail notification"

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
sudo nano /etc/backup/backup.conf       # REMOTE_USER, SOURCES, EXCLUDES, MAIL_TO

# 4. Create the repository password – and store a copy safely!
sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /etc/backup/restic.pass'

# 5. Dry run, then a real run
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
| `REMOTE_USER` | User on the target server                         | –       |
| `REMOTE_HOST` | Target server                                     | –       |
| `SSH_PORT`    | SSH port                                          | `22`    |
| `SSH_KEY`     | Path to the private key (without spaces)          | empty   |
| `BACKUP_NAME` | restic host name of this machine's snapshots      | `hostname -s` |
| `RESTIC_REPO_PATH` | Repository path on the target (relative = home) | `restic-<BACKUP_NAME>` |
| `RESTIC_PASSWORD_FILE` | File containing the repository password  | `/etc/backup/restic.pass` |
| `SOURCES`     | Array of directories to back up (absolute)        | –       |
| `EXCLUDES`    | Array of restic exclude patterns                  | empty   |
| `RESTIC_FORGET_OPTS` | Array of `restic forget` policies, `()` = never delete | `--keep-daily 7 --keep-weekly 5 --keep-monthly 12` |
| `LOG_FILE`    | Log file                                          | `/dev/null` (sample: `/var/log/backup.log`) |
| `MAIL_TO`     | Mail recipients (comma-separated), see "Mail"     | empty = no mails |
| `MAIL_FROM`   | Sender address                                    | empty = mail system default |
| `MIN_FREE_PERCENT` | Warn below this free space on the target, `0` = off | `5` |

`EXCLUDES` are restic patterns: a name without `/` (`.cache`) matches
anywhere, `/home/*/Downloads` only that path. A trailing `/` is dropped.

### Retention

By default restic keeps a staggered history of about one year:

```bash
RESTIC_FORGET_OPTS=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)
```

- the last snapshot of each of the last 7 days,
- the last snapshot of each of the last 5 weeks,
- the last snapshot of each of the last 12 months.

Actual storage use depends on how much data changes and how well it
deduplicates. Any
`restic forget` policy can be used, e.g. add `--keep-yearly 3`, or keep
everything of the last 30 days with `(--keep-within 30d)`. With
`RESTIC_FORGET_OPTS=()` nothing is deleted.

Several machines may share one restic repository (same `RESTIC_REPO_PATH`
and password) to deduplicate across them; snapshots and retention stay
separate per `BACKUP_NAME`.

### Hetzner Storage Box

The sample configuration from `--init-config` is already set up for the
Storage Box `u712238` (port 23, key `/root/.ssh/backup_ed25519`). The host is
derived from `REMOTE_USER`:

```bash
REMOTE_USER="u712238"
REMOTE_HOST="${REMOTE_USER}.your-storagebox.de"
SSH_PORT=23
```

SSH support must be enabled in the Hetzner Console. Deploy the key with
`ssh-copy-id -p 23 -s u712238@u712238.your-storagebox.de` (`-s` uses SFTP,
because the box has no shell).

To keep machines apart, give each one its own sub-account
(`u712238-sub1`, ...) with its own key. Its home then only contains that
machine's repository, so it can live directly in the home:

```bash
REMOTE_USER="u712238-sub1"
SSH_KEY="/root/.ssh/backup_sv32_ed25519"
RESTIC_REPO_PATH="."
```

## Usage

```
backup.sh [-c FILE] [-n] [-v] [-h] [-V] [--init-config [FILE]]
backup.sh [-c FILE] --test-mail
backup.sh [-c FILE] --restic RESTIC-ARGS...
```

| Option | Effect |
|---|---|
| `-c FILE` | different configuration (alternatively `BACKUP_CONF=...`); default `/etc/backup/backup.conf` |
| `-n` | dry run, nothing is changed |
| `-v` / `--progress` | live progress display (terminal only, see below) |
| `--init-config [FILE]` | write a sample configuration |
| `--test-mail` | send a test mail to `MAIL_TO` |
| `--restic ARGS...` | run restic with the configured repository, password and SSH settings |
| `-h` / `-V` | help / version |

Exit code `0` on success, `1` on error. restic code 3 (some files could not
be read) counts as success but is a warning. In that case retention and
pruning are skipped to preserve previous snapshots. Parallel runs with the same
configuration are prevented by a `flock` lock.

Each source is backed up separately, and the log shows the progress:

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

Shows restic's own progress bar (files, bytes, ETA). It is only drawn when
restic writes directly to the terminal, so with `-v` restic's normal output
(including its summary) goes to the terminal only; the script's own log
lines and restic's error messages are still logged.

Without a terminal (systemd, cron, output redirected) `-v` is ignored with a
note, so the journal stays clean.

## Nextcloud

`nextcloud-backup.sh` wraps `backup.sh` for a server running Nextcloud:

1. detects the installation, its user, the PHP version in use and the
   database,
2. enables maintenance mode and dumps the database,
3. runs `backup.sh` (from the same directory) with all given options,
4. **always** ends maintenance mode afterwards – also after a failed backup,
   `Ctrl+C` or `systemctl stop`, and also if it was already on before.
   Do not let a backup run during an upgrade.

It detects automatically:

- the **installation** (folder with `occ` under `/var/www`, `/srv`, `/opt`),
- the **user** occ runs as (owner of `config/config.php`, usually `www-data`),
- the **PHP version** the web server uses: running php-fpm, Apache
  mod_php and the FPM sockets in the nginx/Apache configuration. The choice
  is verified with `occ status`; if that PHP cannot run this Nextcloud, the
  other installed versions are tried,
- the **database** and its credentials from the Nextcloud configuration:
  MySQL/MariaDB (`mariadb-dump`/`mysqldump`, password via a temporary option
  file, never on the command line), PostgreSQL (`pg_dump`) or SQLite.

The dump goes to `/var/backups/nextcloud/nextcloud-db.sql.gz` (SQLite:
`nextcloud-db.sqlite`). It is first written to a `.tmp` file, so a failed
dump never replaces the last good one; a failed dump aborts the run before
the backup. SQLite requires the `sqlite3` command and uses its `.backup`
function; a plain file copy could miss data in the WAL. Include the dump
directory in `SOURCES` for SQLite as well.

```bash
# Check what is detected – changes nothing
sudo /opt/backup/nextcloud-backup.sh --check

# Dry run: no maintenance mode, no dump, "backup.sh -n"
sudo /opt/backup/nextcloud-backup.sh -n

# Real run (all options are passed on to backup.sh, e.g. -v or -c FILE)
sudo /opt/backup/nextcloud-backup.sh
```

Example output of `--check`:

```
Nextcloud: /var/www/nextcloud (version 30.0.2.1, user www-data, PHP 8.3.6, database mysql)
Nextcloud: Warning: /var/backups/nextcloud is not in SOURCES of /etc/backup/backup.conf – it will not be backed up.
Nextcloud: maintenance mode is currently false; data directory /srv/nextcloud-data.
Nextcloud: check only – a real run would enable maintenance mode, dump the database to /var/backups/nextcloud and run /opt/backup/backup.sh.
```

`SOURCES` in the backup configuration then needs at least:

```bash
SOURCES=(
    "/var/www/nextcloud"        # installation incl. config/ and apps
    "/srv/nextcloud-data"       # data directory (datadirectory in config.php)
    "/var/backups/nextcloud"    # database dump
)
```

**Mails:** `backup.sh` reports its own failures. The wrapper reports, to
the same `MAIL_TO`, what happens around it:

- `[backup] FAILED before the backup` – e.g. Nextcloud not found or the
  dump failed; no backup was made,
- `[backup] FAILED – Nextcloud still in maintenance mode` – ending the
  maintenance mode failed,
- `[backup] WARNING` – e.g. a Nextcloud folder is missing from `SOURCES`.

If the detection picks the wrong thing, override it in
`/etc/backup/nextcloud.conf` (next to the backup configuration, owned by
root, sourced as Bash):

```bash
NEXTCLOUD_DIR="/var/www/nextcloud"
NEXTCLOUD_PHP="/usr/bin/php8.3"
NEXTCLOUD_DUMP=1                            # 0 = maintenance mode only
NEXTCLOUD_DUMP_DIR="/var/backups/nextcloud"
```

For the daily run, put the wrapper into the systemd service instead of
`backup.sh`: `ExecStart=/opt/backup/nextcloud-backup.sh`.

Not supported: snap and Docker installations.

## Own steps before and after the backup

`backup.sh` itself only backs up. Wrap it in a small script for anything
else; a `trap` makes sure the "after" part always runs:

```bash
#!/bin/bash
set -euo pipefail
umask 077

trap 'systemctl start myapp' EXIT     # always, also on errors and Ctrl+C
systemctl stop myapp

mkdir -p /var/backups/mysql
mysqldump --all-databases --single-transaction --routines --events \
    | gzip > /var/backups/mysql/all-databases.sql.gz.tmp
mv /var/backups/mysql/all-databases.sql.gz.tmp /var/backups/mysql/all-databases.sql.gz

/opt/backup/backup.sh "$@"
```

Keep in mind that `backup.sh` only mails its own failures: if the wrapper
fails before calling it (e.g. the dump), no mail is sent. Let systemd
report that (`OnFailure=` in the service) or send a mail from the wrapper,
as `nextcloud-backup.sh` does.

## Mail notification

With `MAIL_TO` set, the script sends a mail

- **`[backup] FAILED: <name> (<date>)`** when the run ends with an error:
  failed source, unreachable target, configuration error, interrupted run;
- **`[backup] WARNING: <name> (<date>)`** when the backup succeeded but
  there were warnings: less than `MIN_FREE_PERCENT` free space on the
  target, unreadable files (restic code 3), old snapshots not removed.

The mail contains the error, the warnings and the log of this run (last
200 lines; empty if `LOG_FILE` is not writable). A dry run sends no mail,
a successful run without warnings neither.

```bash
MAIL_TO="admin@example.org, ops@example.org"
MAIL_FROM="backup@sv32.example.org"
MIN_FREE_PERCENT=5
```

Mails are handed to `sendmail`, so the machine needs a mail transfer agent.
For a server that does not receive mail, `msmtp-mta` (relay via an SMTP
account) or `nullmailer` is enough; postfix works as well. The script does
not install one, because it needs credentials. Test it with:

```bash
sudo backup.sh --test-mail
```

If sending fails, this is logged; the exit code of the backup stays the same.

### Free space on the target

Before the backup the script asks the target
for its free space with `df` in sftp – no shell needed; the Storage Box
reports its quota there. The log shows e.g.
`Space on the target: 476.8 of 1024.0 GiB free (46.6%).` Below
`MIN_FREE_PERCENT` this becomes a warning (and a mail); the backup still
runs. If the server does not support `df` in sftp, only a note is logged.
Storage Box snapshots count towards the quota as well.

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

With Nextcloud, use `ExecStart=/opt/backup/nextcloud-backup.sh` instead.

`Persistent=true` catches up on a missed run, e.g. if the machine was off at
night.

## Running daily (cron)

Instead of the systemd timer, a file in `/etc/cron.d` works too (root
crontab format with a user column):

`/etc/cron.d/backup`
```cron
# Daily backup at 02:30; with Nextcloud use nextcloud-backup.sh instead
30 2 * * *  root  nice -n 10 ionice -c 3 /opt/backup/backup.sh >/dev/null 2>&1
```

```cron
30 2 * * *  root  nice -n 10 ionice -c 3 /opt/backup/nextcloud-backup.sh >/dev/null 2>&1
```

- Everything is logged to `LOG_FILE` and failures are mailed to `MAIL_TO`, so
  the output is discarded instead of being mailed by cron. If you have no
  `MAIL_TO`, redirect to a file (`>>/var/log/backup-cron.log 2>&1`) to keep
  errors that happen before the log file is opened.
- Both scripts add `/usr/sbin` etc. to cron's minimal `PATH` themselves
  (needed for `runuser` and `sendmail`).
- Unlike `Persistent=true`, cron does not catch up on a run missed while the
  machine was off.
- Files in `/etc/cron.d` must be owned by root, not group/other-writable,
  and their names must not contain dots.
- Do not schedule `backup.sh` and `nextcloud-backup.sh` both – the wrapper
  already runs the backup.

## Restoring

`backup.sh --restic` passes all following arguments to restic, with
repository, password and SSH settings taken from the configuration. The
original `SOURCES` do not need to exist for recovery commands:

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

## Migrating from rsync (before 4.0.0)

Up to 3.6 the script could also back up with rsync into plain daily
folders. That method has been removed. To switch:

1. Remove `BACKUP_METHOD`, `KEEP_DAYS`, `RSYNC_OPTS` and `SAVE_PERMS` from
   the configuration (a remaining `BACKUP_METHOD="rsync"` makes the script
   abort with a hint), set `RESTIC_REPO_PATH` and create the password file.
2. Run a backup; the first run initializes the repository.
3. The old daily folders (`<BACKUP_NAME>/2026-11-05/` …) stay on the target
   untouched and can still be read with any SFTP client. Delete them
   yourself (e.g. `rm -r` in lftp or FileZilla) once the restic history
   covers what you need.

Owners and permissions of an old rsync backup are in its
`.backup-perms.facl.gz`; apply them after copying the files back:

```bash
cd /mnt/restore && zcat /tmp/.backup-perms.facl.gz | sudo setfacl --restore=-
```

## Notes

- Keep a copy of the repository password outside the server, and check the
  repository now and then: `sudo backup.sh --restic check` (add
  `--read-data-subset 5%` to also read part of the data).
- Dump databases beforehand and back up the dump, not the live files – in a
  wrapper script, see "Own steps before and after the backup".

## Development checks

```bash
bash -n backup.sh nextcloud-backup.sh
python3 -m unittest discover -s tests -v
```

The regression tests use a fake restic executable and temporary configuration
files; they do not connect to a repository or run a real backup.
