#!/usr/bin/env bash
#
# backup.sh – Daily backup to a remote server via rsync or restic.
#
# BACKUP_METHOD="rsync" (default):
#   Each day goes to <REMOTE_BASE>/<BACKUP_NAME>/<YYYY-MM-DD>. Unchanged files
#   are hard-linked to the last complete backup via --link-dest and take up no
#   additional space. Every daily folder is still a complete snapshot.
#
# BACKUP_METHOD="restic":
#   Encrypted, deduplicated snapshots in a restic repository reached via SFTP
#   (default <REMOTE_BASE>/restic-<BACKUP_NAME>).
#
set -euo pipefail

readonly VERSION="3.1.0"
# Kept outside the script directory, so the repository can be updated or
# re-cloned at any time without touching the configuration.
readonly DEFAULT_CONFIG="/etc/backup/backup.conf"
readonly MARKER=".backup-complete"
readonly PERMS_FILE=".backup-perms.facl.gz"

CONFIG="${BACKUP_CONF:-$DEFAULT_CONFIG}"
DRY_RUN=0
INIT_CONFIG=0
INIT_TARGET=""
RESTORE_FILE=""
RESTORE_ROOT="/"
RESTIC_PASSTHRU=0
RESTIC_PASSTHRU_ARGS=()
LOG_FILE="/dev/null"

# --- Helpers -----------------------------------------------------------------

log() {
    local line
    line="$(date '+%F %T') $*"
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

die() { log "ERROR: $*"; exit 1; }

# Makes sure a command is available; otherwise installs its package.
# Usage: ensure_cmd COMMAND PACKAGE
ensure_cmd() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" >/dev/null && return 0

    if (( DRY_RUN )); then
        die "$cmd is missing (package $pkg). Nothing is installed during a dry run: sudo apt install $pkg"
    fi
    if (( EUID != 0 )); then
        die "$cmd is missing (package $pkg). Please install it: sudo apt install $pkg"
    fi
    command -v apt-get >/dev/null || die "$cmd is missing and apt-get is not available. Please install package $pkg."

    log "$cmd is missing – installing package $pkg ..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >>"$LOG_FILE" 2>&1; then
        log "Installation failed, updating package lists and retrying ..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >>"$LOG_FILE" 2>&1 \
            || die "Could not install package $pkg. Please install it manually: sudo apt install $pkg"
    fi
    command -v "$cmd" >/dev/null || die "$cmd still not found after installing $pkg."
    log "Package $pkg installed."
}

usage() {
    cat <<EOF
Usage: ${0##*/} [-c FILE] [-n] [-h] [-V] [--init-config [FILE]]
       ${0##*/} --restore-perms FILE [TARGET_ROOT] [-n]
       ${0##*/} [-c FILE] --restic RESTIC-ARGS...

  -c FILE                configuration file (default: $DEFAULT_CONFIG,
                         alternatively via environment variable BACKUP_CONF)
  -n                     dry run (nothing is changed)
  --init-config [FILE]   write a sample configuration and exit
  --restore-perms FILE [TARGET_ROOT]
                         rsync method: restore owners, groups, permissions
                         and ACLs from a saved $PERMS_FILE
                         (TARGET_ROOT default: /, with -n only check)
  --restic ARGS...       run restic with the configured repository, password
                         and SSH settings, e.g. "--restic snapshots"
                         (all following arguments are passed to restic)
  -h                     show this help
  -V                     show version
EOF
}

config_template() {
    cat <<'EOF'
# backup.conf – configuration for backup.sh (sourced as Bash)

# --- Backup method: "rsync" or "restic" ---
# rsync:  plain daily folders with hard links, readable without extra tools
# restic: encrypted, deduplicated, compressed snapshots (needs restic to restore)
BACKUP_METHOD="rsync"

# --- Target server: Hetzner Storage Box ---
REMOTE_USER="u712238"           # Storage Box user
REMOTE_HOST="${REMOTE_USER}.your-storagebox.de"
SSH_PORT=23                     # Storage Box SSH/rsync/SFTP port
SSH_KEY="/root/.ssh/backup_ed25519"   # empty = ssh default key (path without spaces)

# --- Target path ---
# rsync:  <REMOTE_BASE>/<BACKUP_NAME>/<YYYY-MM-DD>
# restic: RESTIC_REPO_PATH (see below)
REMOTE_BASE="."                 # relative to the Storage Box home
BACKUP_NAME="$(hostname -s)"

# --- Directories to back up (absolute paths) ---
SOURCES=(
    "/etc"
    "/home"
    "/root"
)

# --- Excludes (rsync patterns; for restic a trailing "/" is dropped) ---
EXCLUDES=(
    ".cache/"
    "*.tmp"
    "node_modules/"
)

# --- Retention in days (0 = never delete) ---
# restic: used as "forget --keep-within <KEEP_DAYS>d" unless RESTIC_FORGET_OPTS is set
KEEP_DAYS=30

# --- Log file ---
LOG_FILE="/var/log/backup.log"

# =============================================================================
# rsync only
# =============================================================================

# Without -A/-X: the Storage Box is not written to as root, so ACLs and
# extended attributes cannot be stored there (SAVE_PERMS covers this).
# For a target with root access: RSYNC_OPTS=(-aHAX --numeric-ids --delete --delete-excluded)
RSYNC_OPTS=(-aH --numeric-ids --delete --delete-excluded)

# Additionally save permissions with getfacl (1 = yes, 0 = no).
# Important if the target cannot store owners/groups (e.g. Storage Box).
# Requires the "acl" package – if missing, the script installs it (as root)
# or aborts. Restore with: backup.sh --restore-perms FILE
SAVE_PERMS=1

# =============================================================================
# restic only
# =============================================================================

# Repository path on the target (relative = relative to the Storage Box home).
# One repository per machine by default; several machines may share one
# repository (same password) to deduplicate across them.
RESTIC_REPO_PATH="${REMOTE_BASE%/}/restic-${BACKUP_NAME}"

# Repository password. WITHOUT IT THE BACKUPS ARE LOST – keep a copy elsewhere.
# Create it with:
#   sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /etc/backup/restic.pass'
RESTIC_PASSWORD_FILE="/etc/backup/restic.pass"

# Retention instead of KEEP_DAYS, e.g. staggered:
#   RESTIC_FORGET_OPTS=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)
RESTIC_FORGET_OPTS=()
EOF
}

# --- Arguments ---------------------------------------------------------------

while (( $# )); do
    case "$1" in
        -c) CONFIG="${2:?-c requires a file name}"; shift 2 ;;
        -n) DRY_RUN=1; shift ;;
        --init-config)
            INIT_CONFIG=1
            if [[ -n ${2:-} && $2 != -* ]]; then INIT_TARGET="$2"; shift; fi
            shift ;;
        --restore-perms)
            RESTORE_FILE="${2:?--restore-perms requires a file}"; shift 2
            if [[ -n ${1:-} && $1 != -* ]]; then RESTORE_ROOT="$1"; shift; fi ;;
        --restic)
            RESTIC_PASSTHRU=1; shift
            RESTIC_PASSTHRU_ARGS=("$@")
            break ;;
        -h|--help)    usage; exit 0 ;;
        -V|--version) echo "${0##*/} $VERSION"; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

# --- Write sample configuration ----------------------------------------------

if (( INIT_CONFIG )); then
    target="${INIT_TARGET:-$CONFIG}"
    dir="$(dirname "$target")"
    if [[ -e $target ]]; then
        echo "Error: $target already exists – nothing changed." >&2
        exit 1
    fi
    if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w $dir ]]; then
        echo "Error: no write permission for $dir." >&2
        echo "Run with sudo or choose another path: ${0##*/} --init-config ~/backup.conf" >&2
        exit 1
    fi
    config_template > "$target"
    chmod 600 "$target"
    echo "Sample configuration written: $target"
    echo "Note: mode 600 – view/edit with sudo, e.g. sudo nano $target"
    exit 0
fi

# --- Restore permissions (rsync method) --------------------------------------

if [[ -n $RESTORE_FILE ]]; then
    ensure_cmd setfacl acl
    [[ -r $RESTORE_FILE ]] || { echo "Error: $RESTORE_FILE is not readable." >&2; exit 1; }
    [[ -d $RESTORE_ROOT ]] || { echo "Error: target root $RESTORE_ROOT does not exist." >&2; exit 1; }
    RESTORE_FILE="$(realpath -- "$RESTORE_FILE")"
    (( EUID == 0 )) || echo "Warning: owners and groups cannot be set without root." >&2
    cd "$RESTORE_ROOT"
    if (( DRY_RUN )); then
        echo "Dry run: showing what would be set under $RESTORE_ROOT (first 50 lines) ..."
        zcat -f -- "$RESTORE_FILE" | setfacl --test --restore=- 2>/dev/null | head -n 50 || true
        exit 0
    fi
    echo "Restoring permissions from $RESTORE_FILE under $RESTORE_ROOT ..."
    errfile="$(mktemp)"
    zcat -f -- "$RESTORE_FILE" | setfacl --restore=- 2>"$errfile" || true
    # Missing files are normal (excludes, files deleted since the backup)
    missing=$(grep -c 'No such file or directory' "$errfile" || true)
    grep -v 'No such file or directory' "$errfile" > "$errfile.real" || true
    (( missing > 0 )) && echo "Note: skipped $missing entries because the file is missing in the target (e.g. excludes)."
    if [[ -s $errfile.real ]]; then
        echo "Errors while setting permissions:" >&2
        head -n 20 "$errfile.real" >&2
        rm -f "$errfile" "$errfile.real"
        exit 1
    fi
    rm -f "$errfile" "$errfile.real"
    echo "Done."
    exit 0
fi

# --- Load configuration ------------------------------------------------------

[[ -r $CONFIG ]] || die "Configuration not readable: $CONFIG (create it with --init-config)"

BACKUP_METHOD="rsync"
REMOTE_USER=""; REMOTE_HOST=""; SSH_PORT=22; SSH_KEY=""
REMOTE_BASE="/home"; BACKUP_NAME="$(hostname -s)"
SOURCES=(); EXCLUDES=(); KEEP_DAYS=30; SAVE_PERMS=1
RSYNC_OPTS=(-aHAX --numeric-ids --delete --delete-excluded)
RESTIC_REPO_PATH=""
RESTIC_PASSWORD_FILE="/etc/backup/restic.pass"
RESTIC_FORGET_OPTS=()

# shellcheck source=/dev/null
source "$CONFIG"

if ! touch "$LOG_FILE" 2>/dev/null; then
    (( RESTIC_PASSTHRU )) || echo "Warning: log file $LOG_FILE is not writable, logging to the console only." >&2
    LOG_FILE="/dev/null"
fi

[[ $BACKUP_METHOD == rsync || $BACKUP_METHOD == restic ]] \
                               || die "BACKUP_METHOD must be \"rsync\" or \"restic\" (is \"$BACKUP_METHOD\")"
[[ -n $REMOTE_USER ]]          || die "REMOTE_USER is missing in $CONFIG"
[[ -n $REMOTE_HOST ]]          || die "REMOTE_HOST is missing in $CONFIG"
[[ -n $BACKUP_NAME ]]          || die "BACKUP_NAME is missing in $CONFIG"
(( ${#SOURCES[@]} > 0 ))       || die "SOURCES is empty"
[[ $KEEP_DAYS =~ ^[0-9]+$ ]]   || die "KEEP_DAYS must be an integer"
for src in "${SOURCES[@]}"; do
    [[ $src == /* ]] || die "Source must be an absolute path: $src"
    [[ -e $src ]]    || die "Source does not exist: $src"
done

# --- SSH basics --------------------------------------------------------------
#
# NO shell commands are run on the target – only rsync or SFTP.
# This makes restricted targets like the Hetzner Storage Box work as well.

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH_CMD=(ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15)
[[ -n $SSH_KEY ]] && SSH_CMD+=(-i "$SSH_KEY")
RSH="${SSH_CMD[*]}"
TODAY="$(date +%F)"

# =============================================================================
# restic
# =============================================================================

restic_setup() {
    ensure_cmd restic restic
    [[ -n $RESTIC_REPO_PATH ]] || RESTIC_REPO_PATH="${REMOTE_BASE%/}/restic-${BACKUP_NAME}"
    [[ -r $RESTIC_PASSWORD_FILE ]] || die "restic password file not readable: $RESTIC_PASSWORD_FILE
  Create it (and keep a copy elsewhere – without it the backups are lost):
  sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > $RESTIC_PASSWORD_FILE'"
    export RESTIC_REPOSITORY="sftp:${REMOTE}:${RESTIC_REPO_PATH}"
    export RESTIC_PASSWORD_FILE
    # Port and key via our own ssh command; "-s sftp" requests the SFTP subsystem
    RESTIC_ARGS=(-o "sftp.command=${RSH} ${REMOTE} -s sftp")
}

# Returns 0 if the repository exists, 1 if it does not; dies on other errors.
restic_repo_exists() {
    local out rc
    out="$(restic "${RESTIC_ARGS[@]}" cat config 2>&1 >/dev/null)" && return 0
    rc=$?
    # Exit code 10 = repository does not exist (restic >= 0.17)
    if (( rc == 10 )) || grep -q 'Is there a repository' <<<"$out"; then
        return 1
    fi
    die "Cannot open restic repository $RESTIC_REPOSITORY (exit code $rc): $out"
}

backup_restic() {
    local rc
    log "=== Backup $BACKUP_NAME -> $RESTIC_REPOSITORY (restic, v$VERSION) ==="
    (( DRY_RUN )) && log "DRY RUN – nothing will be changed."

    if ! restic_repo_exists; then
        if (( DRY_RUN )); then
            log "Repository does not exist yet – a real run would initialize it."
            log "Dry run finished (${SECONDS}s)."
            exit 0
        fi
        log "Repository does not exist yet – initializing ..."
        set +e
        restic "${RESTIC_ARGS[@]}" init 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        set -e
        (( rc == 0 )) || die "Could not initialize the restic repository (exit code $rc)."
        log "Repository initialized. Keep a copy of $RESTIC_PASSWORD_FILE in a safe place!"
    fi

    local -a args=(backup --host "$BACKUP_NAME")
    local ex
    for ex in "${EXCLUDES[@]}"; do args+=("--exclude=${ex%/}"); done
    (( DRY_RUN )) && args+=(--dry-run)

    # One snapshot per source: progress per source, failures stay isolated
    local -a failed=()
    local n=0 src
    for src in "${SOURCES[@]}"; do
        n=$((n + 1))
        log "[$n/${#SOURCES[@]}] Backing up $src ..."
        set +e
        restic "${RESTIC_ARGS[@]}" "${args[@]}" "$src" 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        set -e
        case $rc in
            0) log "[$n/${#SOURCES[@]}] $src done." ;;
            3) log "[$n/${#SOURCES[@]}] $src done – WARNING: some files could not be read (restic 3)." ;;
            *) log "[$n/${#SOURCES[@]}] ERROR for $src (restic exit code $rc)."
               failed+=("$src") ;;
        esac
    done

    (( ${#failed[@]} == 0 )) \
        || die "Backup $TODAY is INCOMPLETE – failed: ${failed[*]}"

    # Retention: only snapshots of this host; prune removes unreferenced data
    local -a forget=()
    if (( ${#RESTIC_FORGET_OPTS[@]} > 0 )); then
        forget=("${RESTIC_FORGET_OPTS[@]}")
    elif (( KEEP_DAYS > 0 )); then
        forget=(--keep-within "${KEEP_DAYS}d")
    fi
    if (( ${#forget[@]} > 0 )); then
        log "Removing old snapshots (${forget[*]}) ..."
        local -a fargs=(forget --host "$BACKUP_NAME" --prune "${forget[@]}")
        (( DRY_RUN )) && fargs+=(--dry-run)
        set +e
        restic "${RESTIC_ARGS[@]}" "${fargs[@]}" 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        set -e
        (( rc == 0 )) || log "Warning: removing old snapshots failed (restic exit code $rc)."
    fi

    if (( DRY_RUN )); then
        log "Dry run finished (${SECONDS}s)."
    else
        log "Backup $TODAY complete."
        log "=== Done after ${SECONDS}s ==="
    fi
}

# =============================================================================
# rsync
# =============================================================================

backup_rsync() {
    ensure_cmd rsync rsync
    (( SAVE_PERMS )) && ensure_cmd getfacl acl

    DEST_ROOT="${REMOTE_BASE%/}/${BACKUP_NAME}"
    DEST="${DEST_ROOT}/${TODAY}"
    local DATE_PAT='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'

    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    mkdir -p "$STAGE/empty"

    log "=== Backup $BACKUP_NAME -> $REMOTE:$DEST (rsync, v$VERSION) ==="
    (( DRY_RUN )) && log "DRY RUN – nothing will be changed."

    # Create the target folder (rsync creates the last level itself)
    rs -r "$STAGE/empty/" "${REMOTE}:${DEST_ROOT}/" \
        || die "Target server unreachable or ${DEST_ROOT} cannot be created."

    # List existing backups: daily folders and their completion markers
    LISTING="$(rs -r --list-only \
        --include="/${DATE_PAT}/" --include="/${DATE_PAT}/${MARKER}" --exclude='*' \
        "${REMOTE}:${DEST_ROOT}/" | awk '{print $NF}')" \
        || die "Could not list existing backups."

    # Last complete backup (before today) as hard-link base
    PREV="$(grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}/${MARKER//./\\.}\$" <<<"$LISTING" \
            | cut -d/ -f1 | grep -vx "$TODAY" | sort | tail -n 1 || true)"

    if [[ -n $PREV ]]; then
        log "Hard-link base: $PREV"
    else
        log "No previous backup found – creating a full backup."
    fi

    RSYNC_ARGS=("${RSYNC_OPTS[@]}" --relative --partial --stats -e "$RSH")
    # Relative to the daily folder – works regardless of the target's path layout
    [[ -n $PREV ]] && RSYNC_ARGS+=("--link-dest=../${PREV}")
    local ex
    for ex in "${EXCLUDES[@]}"; do RSYNC_ARGS+=("--exclude=$ex"); done
    (( DRY_RUN )) && RSYNC_ARGS+=(--dry-run)

    # On a second run the same day: remove the marker until rsync has finished
    if (( ! DRY_RUN )) && grep -qx "${TODAY}/${MARKER}" <<<"$LISTING"; then
        rs -r --delete --include="/${MARKER}" --exclude='*' "$STAGE/empty/" "${REMOTE}:${DEST}/" \
            || die "Could not remove the old marker in $TODAY."
    fi

    # Record permissions and owners of all sources (before copying = state of the backup)
    local src
    mkdir -p "$STAGE/mark/$TODAY"
    if (( SAVE_PERMS )) && (( ! DRY_RUN )); then
        : > "$STAGE/perms.facl"
        for src in "${SOURCES[@]}"; do
            log "Recording permissions: $src"
            # without leading "/" -> relative, can be restored into any target root
            (cd / && getfacl -R -P -- "${src#/}" >> "$STAGE/perms.facl" 2>/dev/null) || true
        done
        gzip -c "$STAGE/perms.facl" > "$STAGE/mark/$TODAY/$PERMS_FILE"
        rm -f "$STAGE/perms.facl"
        log "Permissions recorded ($(du -h "$STAGE/mark/$TODAY/$PERMS_FILE" | cut -f1) compressed)."
    fi

    local -a failed=()
    local n=0 rc
    for src in "${SOURCES[@]}"; do
        n=$((n + 1))
        log "[$n/${#SOURCES[@]}] Backing up $src ..."
        set +e
        rsync "${RSYNC_ARGS[@]}" "$src" "${REMOTE}:${DEST}/" 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        set -e
        case $rc in
            0)  log "[$n/${#SOURCES[@]}] $src done." ;;
            24) log "[$n/${#SOURCES[@]}] $src done – some files vanished during transfer (rsync 24)." ;;
            *)  log "[$n/${#SOURCES[@]}] ERROR for $src (rsync exit code $rc)."
                failed+=("$src") ;;
        esac
    done

    (( ${#failed[@]} == 0 )) \
        || die "Backup $TODAY is INCOMPLETE – failed: ${failed[*]}"

    if (( DRY_RUN )); then
        log "Dry run finished (${SECONDS}s)."
        return 0
    fi

    # Finish: set marker, update "latest"
    : > "$STAGE/mark/$TODAY/$MARKER"
    rs -r "$STAGE/mark/" "${REMOTE}:${DEST_ROOT}/" \
        || die "Could not set the completion marker."
    log "Backup $TODAY complete."

    mkdir -p "$STAGE/link"
    ln -s "$TODAY" "$STAGE/link/latest"
    rs -rl "$STAGE/link/" "${REMOTE}:${DEST_ROOT}/" \
        || log "Warning: could not set symlink 'latest' (not supported by the target?)."

    # Remove old backups: sync an empty directory with --delete and a filter
    # matching the old daily folders – rsync deletes exactly these, nothing else.
    if (( KEEP_DAYS > 0 )); then
        local cutoff d
        cutoff="$(date -d "-${KEEP_DAYS} days" +%F)"
        local -a old=() filter=()
        mapfile -t old < <(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' <<<"$LISTING" \
                           | awk -v c="$cutoff" '$0 < c')
        if (( ${#old[@]} > 0 )); then
            for d in "${old[@]}"; do
                log "Removing old backup: $d"
                filter+=("--include=/${d}/***")
            done
            rs -r --delete "${filter[@]}" --exclude='*' "$STAGE/empty/" "${REMOTE}:${DEST_ROOT}/" \
                || log "Warning: old backups could not be removed completely."
        fi
    fi

    log "=== Done after ${SECONDS}s ==="
}

# rsync without data transfer, only for housekeeping steps
rs() { rsync -e "$RSH" "$@"; }

# --- Main --------------------------------------------------------------------

# Pass-through to restic (snapshots, restore, mount, check, ...)
if (( RESTIC_PASSTHRU )); then
    restic_setup
    exec restic "${RESTIC_ARGS[@]}" "${RESTIC_PASSTHRU_ARGS[@]}"
fi

[[ $BACKUP_METHOD == restic ]] && restic_setup

# Only one instance at a time
exec 9>"/tmp/backup-${BACKUP_NAME}.lock"
flock -n 9 || die "A backup for $BACKUP_NAME is already running."

case $BACKUP_METHOD in
    rsync)  backup_rsync ;;
    restic) backup_restic ;;
esac
