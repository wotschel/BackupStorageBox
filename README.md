# backup.sh

Daily backup of selected directories with [restic](https://restic.net/)
over SFTP to a remote server, preset for the Hetzner Storage Box:

- **encrypted** on the client (repository password), **deduplicated** in
  blocks across files and renames, **compressed**
- one snapshot per source, owners, groups, permissions, ACLs and extended
  attributes included
- **staggered retention**: 7 daily, 5 weekly, 12 monthly snapshots
- **hooks** before and after the backup (e.g. database dump, Nextcloud
  maintenance mode), ready-made hooks for Nextcloud included
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
2. pre hooks (`pre.d/`),
3. restic backup per source, then `forget --prune`,
4. post hooks (`post.d/`) – always, also after errors,
5. mail if something failed or there were warnings.

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
| `LOG_FILE`    | Log file                                          | `/var/log/backup.log` |
| `HOOKS_DIR`   | Folder with `pre.d/` and `post.d/`, see "Hooks"   | `hooks` next to the configuration |
| `HOOK_TIMEOUT` | Time limit per hook in seconds, `0` = none       | `3600`  |
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

Thanks to deduplication this costs little more space than a few days. Any
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
be read) counts as success but is a warning. Parallel runs with the same
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

## Hooks

Hooks run commands before and after the backup, e.g. dump databases or put
an application into maintenance mode. They are executable files in two
folders next to the configuration. The first run creates them if they are
missing (as does `--init-config`):

```
/etc/backup/hooks/
├── pre.d/      before the backup
│   ├── 10-nextcloud
│   └── 20-mysqldump
└── post.d/     after the backup – always
    └── 90-nextcloud
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
  `BACKUP_CONFIG`, `BACKUP_LOG_FILE`; post hooks
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

### Included hook: Nextcloud

The repository contains a ready-made pair of hooks for Nextcloud:

| Hook | Does |
|---|---|
| `hooks/pre.d/10-nextcloud` | maintenance mode on, database dump |
| `hooks/post.d/90-nextcloud` | maintenance mode off – also after a failed backup |

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
dump never replaces the last good one, and it aborts the backup.

The post hook **always** ends the maintenance mode, also if it was already
on before the backup. Do not let a backup run during an upgrade. The pre
hook passes the detected installation, user and PHP binary to the post hook
in `/var/lib/backup/nextcloud.state`.

The pre hook warns in the log if the Nextcloud `config` folder, the data
directory or the dump folder is missing from `SOURCES`.

```bash
# Install (from the repository clone)
sudo install -m 755 -o root -g root hooks/pre.d/10-nextcloud  /etc/backup/hooks/pre.d/
sudo install -m 755 -o root -g root hooks/post.d/90-nextcloud /etc/backup/hooks/post.d/

# Check what was detected – changes nothing
sudo BACKUP_CONFIG=/etc/backup/backup.conf /etc/backup/hooks/pre.d/10-nextcloud --check
```

Example output of `--check`:

```
Nextcloud: /var/www/nextcloud (version 30.0.2.1, user www-data, PHP 8.3.6, database mysql)
Nextcloud: WARNING: /var/backups/nextcloud is not in SOURCES of /etc/backup/backup.conf – it will not be backed up.
Nextcloud: maintenance mode is currently false; data directory /srv/nextcloud-data.
Nextcloud: check only – a real run would enable maintenance mode and dump the database to /var/backups/nextcloud.
```

`SOURCES` then needs at least:

```bash
SOURCES=(
    "/var/www/nextcloud"        # installation incl. config/ and apps
    "/srv/nextcloud-data"       # data directory (datadirectory in config.php)
    "/var/backups/nextcloud"    # database dump
)
```

If the detection picks the wrong thing, override it in
`/etc/backup/nextcloud.conf` (owned by root, sourced as Bash):

```bash
NEXTCLOUD_DIR="/var/www/nextcloud"
NEXTCLOUD_PHP="/usr/bin/php8.3"
NEXTCLOUD_DUMP=1                            # 0 = maintenance mode only
NEXTCLOUD_DUMP_DIR="/var/backups/nextcloud"
```

Not supported: snap and Docker installations.

The installed hooks are copies: after a `git pull`, install them again to
get updates.

### Writing your own hooks

A hook is any executable file. For example, dumping all MySQL/MariaDB
databases:

`pre.d/20-mysqldump` – the dump folder must be in `SOURCES`
```bash
#!/bin/bash
set -eo pipefail
umask 077
mkdir -p /var/backups/mysql
# Credentials from /root/.my.cnf (or socket authentication as root)
mysqldump --all-databases --single-transaction --routines --events \
    | gzip > /var/backups/mysql/all-databases.sql.gz.tmp
mv /var/backups/mysql/all-databases.sql.gz.tmp /var/backups/mysql/all-databases.sql.gz
```

`pipefail` makes a failing `mysqldump` fail the hook despite the pipe; the
`.tmp` file and `mv` make sure a broken dump never replaces the last good
one. Install your own hooks with owner root and mode 755 as well.

## Mail notification

With `MAIL_TO` set, the script sends a mail

- **`[backup] FAILED: <name> (<date>)`** when the run ends with an error:
  failed source, unreachable target, configuration error, failed hook,
  interrupted run;
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

Before the backup (and before the pre hooks) the script asks the target
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

`Persistent=true` catches up on a missed run, e.g. if the machine was off at
night. Alternatively via cron: `30 2 * * * /opt/backup/backup.sh`.

## Restoring

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
- Dump databases beforehand and back up the dump, not the live files – a
  pre hook does that automatically, see "Hooks".
