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
# Hooks: executable files in <HOOKS_DIR>/pre.d run before the backup (e.g.
# database dumps, maintenance mode on), those in <HOOKS_DIR>/post.d afterwards
# – always, even if the backup failed or was interrupted.
#
# Mail (MAIL_TO): on failure, on warnings, and when the target has less than
# MIN_FREE_PERCENT free space before the backup.
#
set -euo pipefail

readonly VERSION="3.6.1"
# Kept outside the script directory, so the repository can be updated or
# re-cloned at any time without touching the configuration.
readonly DEFAULT_CONFIG="/etc/backup/backup.conf"
readonly MARKER=".backup-complete"
readonly PERMS_FILE=".backup-perms.facl.gz"

CONFIG="${BACKUP_CONF:-$DEFAULT_CONFIG}"
DRY_RUN=0
PROGRESS=0
INIT_CONFIG=0
INIT_TARGET=""
RESTORE_FILE=""
RESTORE_ROOT="/"
RESTIC_PASSTHRU=0
RESTIC_PASSTHRU_ARGS=()
LOG_FILE="/dev/null"
STAGE=""
POST_HOOKS_PENDING=0
TEST_MAIL=0
LAST_ERROR=""
WARNINGS=()
LOG_START=0

# --- Helpers -----------------------------------------------------------------

log() {
    local line
    line="$(date '+%F %T') $*"
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

die() { LAST_ERROR="$*"; log "ERROR: $*"; exit 1; }

# Logs a warning and collects it for the notification mail
warn() { WARNINGS+=("$*"); log "Warning: $*"; }

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
Usage: ${0##*/} [-c FILE] [-n] [-v] [-h] [-V] [--init-config [FILE]]
       ${0##*/} [-c FILE] --test-mail
       ${0##*/} --restore-perms FILE [TARGET_ROOT] [-n]
       ${0##*/} [-c FILE] --restic RESTIC-ARGS...

  -c FILE                configuration file (default: $DEFAULT_CONFIG,
                         alternatively via environment variable BACKUP_CONF)
  -n                     dry run (nothing is changed)
  -v, --progress         show a live progress display (terminal only;
                         the log gets the final state, not every update)
  --init-config [FILE]   write a sample configuration and exit
  --test-mail            send a test mail to MAIL_TO and exit
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
    "/opt"
    "/root"
)

# --- Excludes (rsync patterns; for restic a trailing "/" is dropped) ---
EXCLUDES=(
    ".cache/"
    "*.tmp"
    "node_modules/"
)

# --- Retention in days for rsync (0 = never delete) ---
# restic uses RESTIC_FORGET_OPTS below; KEEP_DAYS only applies there if
# RESTIC_FORGET_OPTS is empty (as "forget --keep-within <KEEP_DAYS>d")
KEEP_DAYS=30

# --- Log file ---
LOG_FILE="/var/log/backup.log"

# --- Hooks ---
# Executable files in <HOOKS_DIR>/pre.d run before the backup, those in
# <HOOKS_DIR>/post.d afterwards, each in lexical order (10-..., 20-...).
# A failing pre hook aborts the backup; post hooks ALWAYS run once the pre
# phase has started (also after errors or Ctrl+C), e.g. to end a maintenance
# mode. They get BACKUP_RESULT=success|failure and BACKUP_EXIT_CODE.
# Default: the "hooks" folder next to this configuration file.
#HOOKS_DIR="/etc/backup/hooks"
HOOK_TIMEOUT=3600               # seconds per hook, 0 = no limit

# --- Notifications ---
# Mail to MAIL_TO (comma-separated) when the backup fails or has warnings,
# e.g. less than MIN_FREE_PERCENT free space on the target before the backup.
# Needs a working "sendmail" (e.g. package msmtp-mta, nullmailer or postfix).
# Test with: backup.sh --test-mail
MAIL_TO=""                      # empty = no mails
MAIL_FROM=""                    # empty = default of the mail system
MIN_FREE_PERCENT=5              # 0 = do not check

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

# Staggered retention: last 7 days daily, last 5 weeks weekly, last 12 months
# monthly (about one year of history). Empty () = use KEEP_DAYS instead;
# empty and KEEP_DAYS=0 = never delete.
RESTIC_FORGET_OPTS=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)
EOF
}

# =============================================================================
# Free space and mail
# =============================================================================

# Warns if the target has less than MIN_FREE_PERCENT free space. Uses "df" in
# sftp (statvfs@openssh.com extension), so no shell is needed on the target;
# the Storage Box reports its quota there. Not determinable = note only.
check_free_space() {
    (( MIN_FREE_PERCENT > 0 )) || return 0
    local out size="" avail=""
    local -a sftp=(sftp -q -b - -P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15)
    [[ -n $SSH_KEY ]] && sftp+=(-i "$SSH_KEY")

    if ! out="$("${sftp[@]}" "$REMOTE" <<<"df" 2>&1)"; then
        log "Note: could not determine the free space on the target: ${out##*$'\n'}"
        return 0
    fi
    # Columns: Size Used Avail (root) %Capacity, in KiB
    read -r size avail < <(awk '$1 ~ /^[0-9]+$/ && NF >= 5 {print $1, $3; exit}' <<<"$out") || true
    if [[ ! $size =~ ^[0-9]+$ || ! $avail =~ ^[0-9]+$ ]] || (( size == 0 )); then
        log "Note: could not determine the free space on the target (unexpected df output)."
        return 0
    fi

    local info
    info="$(LC_ALL=C awk -v a="$avail" -v s="$size" \
        'BEGIN { printf "%.1f of %.1f GiB free (%.1f%%)", a/1048576, s/1048576, a*100/s }')"
    if (( avail * 100 < size * MIN_FREE_PERCENT )); then
        warn "Low space on the target: $info – less than ${MIN_FREE_PERCENT}%."
    else
        log "Space on the target: $info."
    fi
}

# Sends a plain-text mail to MAIL_TO via sendmail; body from stdin.
# Usage: send_mail SUBJECT
send_mail() {
    local subject="$1" sm
    sm="$(command -v sendmail 2>/dev/null || true)"
    [[ -z $sm && -x /usr/sbin/sendmail ]] && sm=/usr/sbin/sendmail
    if [[ -z $sm ]]; then
        log "Warning: cannot send mail – no sendmail found (install e.g. msmtp-mta or postfix)."
        return 1
    fi
    local rc=0
    {
        printf 'To: %s\n' "$MAIL_TO"
        [[ -n $MAIL_FROM ]] && printf 'From: %s\n' "$MAIL_FROM"
        printf 'Subject: %s\n' "$subject"
        printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n'
        printf 'Content-Transfer-Encoding: 8bit\n\n'
        cat
    } | "$sm" -t -oi || rc=$?
    if (( rc != 0 )); then
        log "Warning: sending the mail to $MAIL_TO failed (sendmail exit code $rc)."
        return 1
    fi
    log "Mail sent to $MAIL_TO: $subject"
}

# Mail after a run that failed or had warnings (called from on_exit)
notify() {
    local rc="$1" status w
    [[ -n $MAIL_TO ]] || return 0
    (( DRY_RUN || RESTIC_PASSTHRU || TEST_MAIL )) && return 0
    if (( rc != 0 )); then
        status="FAILED"
    elif (( ${#WARNINGS[@]} > 0 )); then
        status="WARNING"
    else
        return 0
    fi
    {
        echo "Backup $BACKUP_NAME on $(hostname -f 2>/dev/null || hostname): $status (exit code $rc)"
        echo
        echo "Configuration: $CONFIG"
        echo "Method:        $BACKUP_METHOD"
        echo "Target:        ${REMOTE_USER}@${REMOTE_HOST}"
        echo "Duration:      ${SECONDS}s"
        [[ -n $LAST_ERROR ]] && printf '\nError:\n  %s\n' "$LAST_ERROR"
        if (( ${#WARNINGS[@]} > 0 )); then
            printf '\nWarnings:\n'
            for w in "${WARNINGS[@]}"; do printf '  - %s\n' "$w"; done
        fi
        if [[ $LOG_FILE != /dev/null && -r $LOG_FILE ]]; then
            printf '\n--- Log of this run (last 200 lines, full log: %s) ---\n' "$LOG_FILE"
            tail -c "+$((LOG_START + 1))" -- "$LOG_FILE" | tail -n 200
        fi
    } | send_mail "[backup] $status: $BACKUP_NAME ($(date +%F))"
}

# =============================================================================
# Hooks
# =============================================================================

# Runs the executable files in <HOOKS_DIR>/<PHASE>.d in lexical order, output
# goes to the log. Phase "pre" stops at the first failing hook, phase "post"
# runs all of them. Returns 1 if a hook failed. A dry run only lists them.
# Usage: run_hooks pre|post
run_hooks() {
    local phase="$1" dir="${HOOKS_DIR%/}/$1.d"
    local hook name rc owner perms failed=0
    local -a hooks=()
    [[ -d $dir ]] || return 0

    for hook in "$dir"/*; do               # hidden files are not matched
        [[ -f $hook ]] || continue
        name="${hook##*/}"
        case $name in *~|*.bak|*.disabled|*.dpkg-*|*.swp) continue ;; esac
        if [[ ! -x $hook ]]; then
            log "Hook $phase.d/$name skipped (not executable)."
            continue
        fi
        hooks+=("$hook")
    done
    (( ${#hooks[@]} > 0 )) || return 0

    export BACKUP_PHASE="$phase" BACKUP_NAME BACKUP_METHOD
    export BACKUP_CONFIG="$CONFIG" BACKUP_LOG_FILE="$LOG_FILE"

    for hook in "${hooks[@]}"; do
        name="$phase.d/${hook##*/}"
        if (( DRY_RUN )); then
            log "Dry run: would run hook $name"
            continue
        fi
        # Hooks run as root: refuse files others could have changed
        if (( EUID == 0 )); then
            read -r owner perms < <(stat -c '%u %a' -- "$hook")
            if (( owner != 0 || (8#$perms & 8#022) )); then
                log "ERROR: hook $name is not owned by root or writable by group/others – not run."
                failed=1
                [[ $phase == pre ]] && break
                continue
            fi
        fi
        log "Running hook $name ..."
        set +e
        if (( HOOK_TIMEOUT > 0 )); then
            timeout -k 30 "$HOOK_TIMEOUT" "$hook" </dev/null 2>&1 | tee -a "$LOG_FILE"
        else
            "$hook" </dev/null 2>&1 | tee -a "$LOG_FILE"
        fi
        rc=${PIPESTATUS[0]}
        set -e
        case $rc in
            0)       log "Hook $name done." ;;
            124|137) log "ERROR: hook $name timed out after ${HOOK_TIMEOUT}s."; failed=1 ;;
            *)       log "ERROR: hook $name failed (exit code $rc)."; failed=1 ;;
        esac
        (( failed )) && [[ $phase == pre ]] && break
    done
    return "$failed"
}

# Creates <HOOKS_DIR>/pre.d and post.d if missing (not in a dry run). Failing
# to create them is no error – without folders there are simply no hooks.
ensure_hook_dirs() {
    local d missing=()
    (( DRY_RUN )) && return 0
    for d in "${HOOKS_DIR%/}/pre.d" "${HOOKS_DIR%/}/post.d"; do
        [[ -d $d ]] || missing+=("$d")
    done
    (( ${#missing[@]} > 0 )) || return 0
    if mkdir -p -m 755 -- "${missing[@]}" 2>/dev/null; then
        log "Created hook folders: ${missing[*]}"
    else
        log "Note: could not create hook folders under $HOOKS_DIR – running without hooks."
    fi
}

# EXIT trap: runs the post hooks (if the pre phase was reached), sends the
# notification mail and cleans up. A failing post hook turns a successful run
# into exit code 1.
on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if (( POST_HOOKS_PENDING )); then
        POST_HOOKS_PENDING=0
        export BACKUP_EXIT_CODE="$rc" BACKUP_RESULT="success"
        (( rc == 0 )) || BACKUP_RESULT="failure"
        if ! run_hooks post; then
            LAST_ERROR="${LAST_ERROR:+$LAST_ERROR; }A post-backup hook failed – check the services it should have restored!"
            log "ERROR: a post-backup hook failed – check the services it should have restored!"
            (( rc == 0 )) && rc=1
        fi
        set +e   # run_hooks switches errexit back on
    fi
    notify "$rc"
    [[ -n $STAGE ]] && rm -rf "$STAGE"
    exit "$rc"
}

# --- Arguments ---------------------------------------------------------------

while (( $# )); do
    case "$1" in
        -c) CONFIG="${2:?-c requires a file name}"; shift 2 ;;
        -n) DRY_RUN=1; shift ;;
        -v|--progress) PROGRESS=1; shift ;;
        --test-mail) TEST_MAIL=1; shift ;;
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
    if mkdir -p "$dir/hooks/pre.d" "$dir/hooks/post.d" 2>/dev/null; then
        echo "Hook folders: $dir/hooks/pre.d and $dir/hooks/post.d"
    fi
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
RESTIC_FORGET_OPTS=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)
HOOKS_DIR="$(dirname -- "$CONFIG")/hooks"
HOOK_TIMEOUT=3600
MAIL_TO=""; MAIL_FROM=""; MIN_FREE_PERCENT=5

# shellcheck source=/dev/null
source "$CONFIG"

if ! touch "$LOG_FILE" 2>/dev/null; then
    (( RESTIC_PASSTHRU )) || echo "Warning: log file $LOG_FILE is not writable, logging to the console only." >&2
    LOG_FILE="/dev/null"
fi
# Start of this run in the log, for the excerpt in the notification mail
LOG_START=$(stat -c %s -- "$LOG_FILE" 2>/dev/null || echo 0)

# From here on errors are reported by mail; the post hooks run once the pre
# phase has been reached. The signal traps exit, which triggers the EXIT trap.
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $BACKUP_METHOD == rsync || $BACKUP_METHOD == restic ]] \
                               || die "BACKUP_METHOD must be \"rsync\" or \"restic\" (is \"$BACKUP_METHOD\")"
[[ -n $REMOTE_USER ]]          || die "REMOTE_USER is missing in $CONFIG"
[[ -n $REMOTE_HOST ]]          || die "REMOTE_HOST is missing in $CONFIG"
[[ -n $BACKUP_NAME ]]          || die "BACKUP_NAME is missing in $CONFIG"
(( ${#SOURCES[@]} > 0 ))       || die "SOURCES is empty"
[[ $KEEP_DAYS =~ ^[0-9]+$ ]]   || die "KEEP_DAYS must be an integer"
[[ $HOOK_TIMEOUT =~ ^[0-9]+$ ]] || die "HOOK_TIMEOUT must be an integer"
[[ $MIN_FREE_PERCENT =~ ^[0-9]+$ ]] && (( MIN_FREE_PERCENT <= 100 )) \
                               || die "MIN_FREE_PERCENT must be an integer from 0 to 100"
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
        if (( PROGRESS )); then
            # restic only draws its progress bar when stdout is a terminal,
            # so stdout goes there directly; errors are still logged.
            restic "${RESTIC_ARGS[@]}" "${args[@]}" "$src" 2> >(tee -a "$LOG_FILE" >&2)
            rc=$?
        else
            restic "${RESTIC_ARGS[@]}" "${args[@]}" "$src" 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
        fi
        set -e
        case $rc in
            0) log "[$n/${#SOURCES[@]}] $src done." ;;
            3) log "[$n/${#SOURCES[@]}] $src done."
               warn "$src: some files could not be read (restic exit code 3)." ;;
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
        (( rc == 0 )) || warn "Removing old snapshots failed (restic exit code $rc)."
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

    STAGE="$(mktemp -d)"   # removed by on_exit
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
        if (( PROGRESS )); then
            # Live progress on the terminal (fd 3); the log only keeps the
            # last state of each \r-updated progress line.
            rsync "${RSYNC_ARGS[@]}" --info=progress2 --no-inc-recursive \
                "$src" "${REMOTE}:${DEST}/" 2>&1 \
                | tee /dev/fd/3 | sed -u 's/.*\r//' >> "$LOG_FILE"
        else
            rsync "${RSYNC_ARGS[@]}" "$src" "${REMOTE}:${DEST}/" 2>&1 | tee -a "$LOG_FILE"
        fi
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
                || warn "Old backups could not be removed completely."
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
    trap - EXIT HUP INT TERM
    exec restic "${RESTIC_ARGS[@]}" "${RESTIC_PASSTHRU_ARGS[@]}"
fi

if (( TEST_MAIL )); then
    [[ -n $MAIL_TO ]] || die "MAIL_TO is empty in $CONFIG"
    echo "Test mail from backup.sh $VERSION ($CONFIG) on $(hostname -f 2>/dev/null || hostname)." \
        | send_mail "[backup] Test: $BACKUP_NAME" || exit 1
    exit 0
fi

[[ $BACKUP_METHOD == restic ]] && restic_setup

# Progress display only makes sense on a terminal (not under systemd/cron)
if (( PROGRESS )) && [[ ! -t 1 ]]; then
    log "Note: -v needs a terminal – progress display disabled."
    PROGRESS=0
fi
exec 3>&1   # console, used by the progress display

# Only one instance per configuration at a time. The lock is held on the
# configuration file itself (opened read-only), so no lock file is needed –
# a lock file in /tmp breaks when another user created it (fs.protected_regular).
exec 9<"$CONFIG"
flock -n 9 || die "A backup with $CONFIG is already running."

check_free_space

# From here on the post hooks always run, also on errors and signals
POST_HOOKS_PENDING=1
ensure_hook_dirs
run_hooks pre || die "A pre-backup hook failed – backup aborted (post-backup hooks still run)."

case $BACKUP_METHOD in
    rsync)  backup_rsync ;;
    restic) backup_restic ;;
esac
