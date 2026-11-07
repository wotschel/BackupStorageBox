# backup.sh

Daily backup of selected directories via `rsync` over SSH to a remote server.
Each day gets its own folder; unchanged files are hard-linked to the last
complete backup via `--link-dest`. Every daily folder is therefore a complete
snapshot but only takes up the space of the changed files.

## Layout on the target server

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

With the default values this is `/home/<hostname>/<YYYY-MM-DD>`. Source paths
are preserved (`/etc` ends up in `2026-11-07/etc`).

A day only counts as finished once rsync has succeeded; then the file
`.backup-complete` is created. Only such folders serve as hard-link base, so an
aborted run does not corrupt the next one. If a day is missing, the script
automatically links against the last complete backup.

The script runs **no shell commands** on the target. Listing, marking, setting
`latest` and cleanup are done exclusively through rsync. This makes restricted
targets like the Hetzner Storage Box work as well.

## Requirements

- Ubuntu 26.04 LTS or newer, `rsync` on both sides
- SSH access by key without password prompt (`BatchMode=yes`)
- On the target, rsync as the counterpart is enough; no shell is needed
- Packages `rsync` and `acl` (`getfacl`/`setfacl`). If they are missing, the
  script installs them itself via `apt-get` when running as root. Without root
  or during a dry run it aborts with a hint instead, before anything is transferred.
- Target server with a file system that supports hard links (ext4, XFS, Btrfs, ZFS)

## Setup

The script runs directly from a clone of the repository; the configuration
lives separately in `/etc/backup/backup.conf`. Updating is therefore just a
`git pull`, and the repository can be deleted and cloned again at any time
without losing the configuration.

```bash
# 1. Create an SSH key for the backup and deploy it to the Storage Box
sudo ssh-keygen -t ed25519 -f /root/.ssh/backup_ed25519 -N ""
sudo ssh-copy-id -p 23 -s -i /root/.ssh/backup_ed25519 u712238@u712238.your-storagebox.de

# 2. Clone the repository and link the script
sudo git clone https://github.com/wotschel/BackupStorageBox.git /opt/backup
sudo ln -s /opt/backup/backup.sh /usr/local/sbin/backup.sh

# 3. Create the sample configuration and adjust it
sudo backup.sh --init-config          # -> /etc/backup/backup.conf
sudo nano /etc/backup/backup.conf       # check SOURCES, EXCLUDES, KEEP_DAYS

# 4. Dry run, then a real run
sudo backup.sh -n
sudo backup.sh
```

Update later with:

```bash
sudo git -C /opt/backup pull
```

## Configuration

The file is sourced as Bash (hence `chmod 600`, owned by root).

| Variable      | Meaning                                           | Default |
|---------------|---------------------------------------------------|---------|
| `REMOTE_USER` | User on the target server                         | –       |
| `REMOTE_HOST` | Target server                                     | –       |
| `SSH_PORT`    | SSH port                                          | `22`    |
| `SSH_KEY`     | Path to the private key (without spaces)          | empty   |
| `REMOTE_BASE` | Base directory on the target server               | `/home` |
| `BACKUP_NAME` | Subfolder per backed-up machine                   | `hostname -s` |
| `SOURCES`     | Array of directories to back up (absolute)        | –       |
| `EXCLUDES`    | Array of rsync exclude patterns                   | empty   |
| `KEEP_DAYS`   | Retention in days, `0` = never delete             | `30`    |
| `RSYNC_OPTS`  | rsync options                                     | `-aHAX --numeric-ids --delete --delete-excluded` |
| `SAVE_PERMS`  | Additionally save permissions via getfacl (1/0)   | `1`     |
| `LOG_FILE`    | Log file                                          | `/var/log/backup.log` |

`-A` (ACLs) and `-X` (extended attributes) require root on the target server.
If you write there as a regular user, remove them from `RSYNC_OPTS`.

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
because the box has no shell). Since the box is not written to as root, owners
and groups of the files are not preserved; permissions are. That is what the
permissions file is for, see "Restoring permissions".

## Usage

```
backup.sh [-c FILE] [-n] [-h] [-V] [--init-config [FILE]]
backup.sh --restore-perms FILE [TARGET_ROOT] [-n]
```

| Option | Effect |
|---|---|
| `-c FILE` | different configuration (alternatively `BACKUP_CONF=...`); default `/etc/backup/backup.conf` |
| `-n` | dry run, nothing is changed |
| `--init-config [FILE]` | write a sample configuration |
| `--restore-perms FILE [TARGET_ROOT]` | restore permissions, see below |
| `-h` / `-V` | help / version |

Exit code `0` on success, `1` on error. rsync code 24 (files vanished during
the backup) counts as success and is only logged. A second run on the same day
updates the daily folder; parallel runs are prevented by a `flock` lock.

Each source is transferred separately, and the log shows the progress:

```
[1/3] Backing up /etc ...
[1/3] /etc done.
[2/3] Backing up /home ...
```

If one source fails, the others still run. At the end the day then counts as
incomplete, and the failed sources are listed.

## Running daily (systemd timer)

`/etc/systemd/system/backup.service`
```ini
[Unit]
Description=Daily rsync backup
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
Description=Daily rsync backup

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

Each daily folder is a normal directory tree:

```bash
# Restore a single file from Nov 5
rsync -a backup@backup.example.lan:/home/myhost/2026-11-05/etc/fstab /tmp/

# Whole directory from the latest snapshot
rsync -aHAX backup@backup.example.lan:/home/myhost/latest/home/alice/ /home/alice/
```

### Restoring permissions

Before copying, the script uses `getfacl` to write owner, group, mode and ACLs
of all files and directories in the sources to `.backup-perms.facl.gz`. The
paths in it are relative (`etc/shadow`), so they can be applied to any target
root. This matters most when the target cannot store owners, as with the
Storage Box.

```bash
# Fetch the permissions file from the target
rsync -e 'ssh -p23' u712238@u712238.your-storagebox.de:myhost/2026-11-05/.backup-perms.facl.gz /tmp/

# Check first, then apply (as root)
sudo backup.sh --restore-perms /tmp/.backup-perms.facl.gz /mnt/restore -n
sudo backup.sh --restore-perms /tmp/.backup-perms.facl.gz /mnt/restore
```

Without a target root, `/` is used. Entries for files missing in the target
(e.g. due to excludes) are skipped and only counted. With `SAVE_PERMS=0` the
permissions file is not created, and `acl` is not needed either.

## Notes

- Hard links share their content: if you *edit* a file in a daily folder on
  the server, you change it in all days. Only read backups.
- `du -sh` across all days counts hard links only once; `du -sh 2026-11-07`
  alone shows the full size.
- The backup is not encrypted. For an off-site target server, use an
  encrypted file system.
- Dump databases beforehand and back up the dump, not the live files.
