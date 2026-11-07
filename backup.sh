#!/usr/bin/env bash
#
# backup.sh – Daily backup with restic to a remote server via SFTP.
#
# Encrypted, deduplicated, compressed snapshots in a restic repository
# (default restic-<BACKUP_NAME> in the home of the SSH user), one snapshot
# per source, staggered retention via "restic forget --prune".
#
# Local actions in wrappers/pre and wrappers/post run around the backup.
#
# Mail (MAIL_TO): on failure, on warnings, and when the target has less than
# MIN_FREE_PERCENT free space before the backup.
#
set -euo pipefail
umask 077

# cron starts jobs with PATH=/usr/bin:/bin – add the sbin directories so that
# runuser, sendmail etc. are found there too
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    [[ ":$PATH:" == *":$d:"* ]] || PATH="$PATH:$d"
done
export PATH

readonly VERSION="5.2.0"
readonly SCRIPT_DIR="$(dirname -- "$(realpath -- "$0")")"
# Kept outside the script directory, so the repository can be updated or
# re-cloned at any time without touching the configuration.
readonly DEFAULT_CONFIG="/etc/backup/backup.conf"

CONFIG="${BACKUP_CONF:-$DEFAULT_CONFIG}"
DRY_RUN=0
PROGRESS=0
INIT_CONFIG=0
INIT_TARGET=""
RESTIC_PASSTHRU=0
RESTIC_PASSTHRU_ARGS=()
LOG_FILE="/dev/null"
TEST_MAIL=0
LAST_ERROR=""
WARNINGS=()
readonly RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
LOG_PHASE=setup
LOG_READY=0
LOG_WRITE_WARNED=0
RUN_STARTED=0
SOURCES_OK=0
SOURCES_FAILED=0
POST_PENDING=0

# --- Helpers -----------------------------------------------------------------

log_level() {
    local level="$1" message line
    shift
    # Prefix every line, including multiline errors and child process output.
    while IFS= read -r message || [[ -n $message ]]; do
        line="$(date '+%Y-%m-%dT%H:%M:%S%:z') $level [$RUN_ID] $LOG_PHASE: $message"
        printf '%s\n' "$line"
        if (( LOG_READY )) && [[ $LOG_FILE != /dev/null ]]; then
            if ! { printf '%s\n' "$line" >> "$LOG_FILE"; } 2>/dev/null; then
                if (( ! LOG_WRITE_WARNED )); then
                    printf '%s WARN [%s] %s: Cannot write log file %s; continuing on console.\n' \
                        "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$RUN_ID" "$LOG_PHASE" "$LOG_FILE" >&2
                    LOG_WRITE_WARNED=1
                fi
            fi
        fi
    done <<< "$*"
}

log() { log_level INFO "$*"; }
die() { LAST_ERROR="$*"; log_level ERROR "$*"; exit 1; }
warn() { WARNINGS+=("$*"); log_level WARN "Warning: $*"; }

log_output() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        log_level OUTPUT "$line"
    done
}

setup_logging() {
    local requested="$LOG_FILE" dir
    [[ $LOG_FILE == /dev/null ]] && { LOG_READY=1; return 0; }
    dir="$(dirname -- "$LOG_FILE")"
    # Apply restrictive permissions to new directories/files only.
    if (umask 077; mkdir -p -- "$dir" && touch -- "$LOG_FILE") 2>/dev/null \
       && [[ -f $LOG_FILE && -w $LOG_FILE ]]; then
        LOG_READY=1
    else
        LOG_FILE=/dev/null
        LOG_READY=1
        warn "Log file $requested is not writable; logging to the console only."
    fi
}

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
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" 2>&1 | log_output; then
        log "Installation failed, updating package lists and retrying ..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | log_output || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" 2>&1 | log_output \
            || die "Could not install package $pkg. Please install it manually: sudo apt install $pkg"
    fi
    command -v "$cmd" >/dev/null || die "$cmd still not found after installing $pkg."
    log "Package $pkg installed."
}

usage() {
    cat <<EOF
Usage: ${0##*/} [-c FILE] [-n] [-v] [-h] [-V] [--init-config [FILE]]
       ${0##*/} [-c FILE] --test-mail
       ${0##*/} [-c FILE] --restic RESTIC-ARGS...

  -c FILE                configuration file (default: $DEFAULT_CONFIG,
                         alternatively via environment variable BACKUP_CONF)
  -n                     dry run (nothing is changed)
  -v, --progress         show a live progress display (terminal only;
                         the log gets the final state, not every update)
  --init-config [FILE]   write a sample configuration and exit
  --test-mail            send a test mail to MAIL_TO and exit
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

# --- Target server: Hetzner Storage Box ---
REMOTE_USER="u712238"           # Storage Box user
REMOTE_HOST="${REMOTE_USER}.your-storagebox.de"
SSH_PORT=23                     # Storage Box SSH/SFTP port
SSH_KEY="/root/.ssh/backup_ed25519"   # empty = ssh default key (path without spaces)

# --- Name of this machine (restic host name of its snapshots) ---
BACKUP_NAME="$(hostname -s)"

# --- restic repository ---
# Path on the target, relative = relative to the Storage Box home. One
# repository per machine by default; several machines may share one
# repository (same password) to deduplicate across them.
RESTIC_REPO_PATH="restic-${BACKUP_NAME}"

# Repository password. WITHOUT IT THE BACKUPS ARE LOST – keep a copy elsewhere.
# Create it with:
#   sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /etc/backup/restic.pass'
RESTIC_PASSWORD_FILE="/etc/backup/restic.pass"

# --- Directories to back up (absolute paths) ---
SOURCES=(
    "/etc"
    "/home"
    "/opt"
    "/root"
)

# --- Excludes (restic patterns; a name without "/" matches anywhere) ---
EXCLUDES=(
    ".cache"
    "*.tmp"
    "node_modules"
)

# --- Retention ---
# Staggered: last 7 days daily, last 5 weeks weekly, last 12 months monthly
# (about one year of history). Any "restic forget" policy works, e.g.
# (--keep-within 30d). Empty () = never delete.
RESTIC_FORGET_OPTS=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)

# --- Local actions (executable scripts, sorted by filename) ---
# Default: wrappers/ next to backup.sh. Empty = disable local actions.
# WRAPPERS_DIR="/etc/backup/wrappers"

# --- Log file ---
LOG_FILE="/var/log/backup/backup.log"

# --- Notifications ---
# Mail to MAIL_TO (comma-separated) when the backup fails or has warnings,
# e.g. less than MIN_FREE_PERCENT free space on the target before the backup.
# Needs a working "sendmail" (e.g. package msmtp-mta, nullmailer or postfix).
# Test with: backup.sh --test-mail
MAIL_TO=""                      # empty = no mails
MAIL_FROM=""                    # empty = default of the mail system
MIN_FREE_PERCENT=5              # 0 = do not check

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
        log_level WARN "Warning: cannot send mail – no sendmail found (install e.g. msmtp-mta or postfix)."
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
        log_level WARN "Warning: sending the mail to $MAIL_TO failed (sendmail exit code $rc)."
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
        echo "Repository:    ${RESTIC_REPOSITORY:-?}"
        echo "Duration:      ${SECONDS}s"
        echo "Run ID:        $RUN_ID"
        [[ -n $LAST_ERROR ]] && printf '\nError:\n  %s\n' "$LAST_ERROR"
        if (( ${#WARNINGS[@]} > 0 )); then
            printf '\nWarnings:\n'
            for w in "${WARNINGS[@]}"; do printf '  - %s\n' "$w"; done
        fi
        if [[ $LOG_FILE != /dev/null && -r $LOG_FILE ]]; then
            printf '\n--- Log of this run (last 200 lines, full log: %s) ---\n' "$LOG_FILE"
            { grep -F -- "[$RUN_ID]" "$LOG_FILE" || true; } | tail -n 200
        fi
    } | send_mail "[backup] $status: $BACKUP_NAME ($(date +%F))"
}

# EXIT trap: sends the notification mail if the run failed or had warnings
on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if (( POST_PENDING )); then
        POST_PENDING=0
        local post_rc=0
        run_actions post "$rc" || post_rc=$?
        (( rc == 0 && post_rc != 0 )) && rc=$post_rc
    fi
    if (( RUN_STARTED )); then
        local status=OK level=INFO
        LOG_PHASE=summary
        if (( rc != 0 )); then
            status=FAILED; level=ERROR
        elif (( ${#WARNINGS[@]} > 0 )); then
            status=WARNING; level=WARN
        fi
        log_level "$level" "finished status=$status duration=${SECONDS}s sources_ok=$SOURCES_OK sources_failed=$SOURCES_FAILED warnings=${#WARNINGS[@]} exit=$rc dry_run=$DRY_RUN"
    fi
    LOG_PHASE=notify
    notify "$rc"
    exit "$rc"
}

# Execute child processes rather than sourcing user code into this shell.
# Each phase uses a stable C-locale filename order; use 10-, 20-, ... prefixes.
run_actions() {
    local phase="$1" status="${2:-0}" script rc enable_cmd started failed=0
    LOG_PHASE="$phase"
    [[ -n $WRAPPERS_DIR && -d $WRAPPERS_DIR/$phase ]] || return 0
    while IFS= read -r -d '' script; do
        [[ -f $script ]] || continue
        if [[ ! -x $script ]]; then
            printf -v enable_cmd 'chmod +x -- %q' "$script"
            warn "Skipping $phase action: $script is not executable. Enable it with: $enable_cmd"
            continue
        fi
        started=$SECONDS
        log "Running $phase action: $script"
        if BACKUP_EXIT_CODE="$status" BACKUP_CONFIG="$CONFIG" BACKUP_NAME="$BACKUP_NAME" \
            "$script" 2>&1 | log_output; then
            rc=0
        else
            local -a action_status=("${PIPESTATUS[@]}")
            rc=${action_status[0]}
            (( rc == 0 )) && rc=${action_status[1]}
        fi
        local level=INFO
        (( rc != 0 )) && level=ERROR
        log_level "$level" "Finished $phase action: $script duration=$((SECONDS - started))s exit=$rc"
        if (( rc != 0 )); then
            LAST_ERROR="${LAST_ERROR:+$LAST_ERROR; }$phase action failed: $script (exit code $rc)"
            log_level ERROR "$phase action failed: $script (exit code $rc)"
            failed=1
            [[ $phase == pre ]] && return 1
        fi
    done < <(printf '%s\0' "$WRAPPERS_DIR/$phase/"* | LC_ALL=C sort -z)
    return "$failed"
}

# Check every action before preparation so an unsafe post action cannot leave
# an application stopped. Configuration and scripts are trusted local code.
validate_actions() {
    local phase script owner perms
    [[ -n $WRAPPERS_DIR ]] || return 0
    for phase in pre post; do
        for script in "$WRAPPERS_DIR/$phase/"*; do
            [[ -f $script && -x $script ]] || continue
            read -r owner perms < <(stat -L -c '%u %a' -- "$script")
            if (( EUID == 0 && (owner != 0 || (8#$perms & 8#022)) )); then
                die "Action must be owned by root and not writable by group/others: $script"
            fi
        done
    done
}

# Hooks were removed in 5.0.0. Installed ones would silently no longer run
# (e.g. no database dump), so point them out.
check_old_hooks() {
    local dir f
    dir="$(dirname -- "$CONFIG")/hooks"
    for f in "$dir"/pre.d/* "$dir"/post.d/*; do
        if [[ -f $f ]]; then
            warn "Hooks are no longer supported since 5.0.0 – $dir is NOT run. Move executable actions to $WRAPPERS_DIR/pre and $WRAPPERS_DIR/post; then delete $dir."
            return 0
        fi
    done
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
            echo "Error: --restore-perms was removed together with the rsync method in 4.0.0." >&2
            echo "Restore a saved .backup-perms.facl.gz with: cd TARGET_ROOT && zcat FILE | sudo setfacl --restore=-" >&2
            exit 2 ;;
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

# --- Load configuration ------------------------------------------------------

[[ -r $CONFIG ]] || die "Configuration not readable: $CONFIG (create it with --init-config)"

BACKUP_METHOD="restic"   # only for old configurations, see below
REMOTE_USER=""; REMOTE_HOST=""; SSH_PORT=22; SSH_KEY=""
REMOTE_BASE=""; BACKUP_NAME="$(hostname -s)"
SOURCES=(); EXCLUDES=()
WRAPPERS_DIR="$SCRIPT_DIR/wrappers"
LOG_FILE="/var/log/backup/backup.log"
RESTIC_REPO_PATH=""
RESTIC_PASSWORD_FILE="/etc/backup/restic.pass"
RESTIC_FORGET_OPTS=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)
MAIL_TO=""; MAIL_FROM=""; MIN_FREE_PERCENT=5

# shellcheck source=/dev/null
source "$CONFIG"

# Keep administrative command output clean and avoid creating backup logs.
if (( ! RESTIC_PASSTHRU && ! TEST_MAIL )); then
    LOG_FILE="${LOG_FILE:-/var/log/backup/backup.log}"
    setup_logging
    RUN_STARTED=1
    log "started backup=$BACKUP_NAME config=$CONFIG sources=${#SOURCES[@]} version=$VERSION dry_run=$DRY_RUN"
    for src in "${SOURCES[@]}"; do log "source=$src"; done
fi

# From here on errors are reported by mail. The signal traps exit, which
# triggers the EXIT trap.
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $BACKUP_METHOD == restic ]] || die "BACKUP_METHOD=\"$BACKUP_METHOD\" is no longer supported – since 4.0.0 \
only restic is available. Remove BACKUP_METHOD from $CONFIG and set up restic (see README)."
[[ -n $REMOTE_USER ]]          || die "REMOTE_USER is missing in $CONFIG"
[[ -n $REMOTE_HOST ]]          || die "REMOTE_HOST is missing in $CONFIG"
[[ -n $BACKUP_NAME ]]          || die "BACKUP_NAME is missing in $CONFIG"
[[ $MIN_FREE_PERCENT =~ ^[0-9]+$ ]] && (( MIN_FREE_PERCENT <= 100 )) \
                               || die "MIN_FREE_PERCENT must be an integer from 0 to 100"
# --- SSH basics --------------------------------------------------------------
#
# NO shell commands are run on the target – only SFTP.
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
    # REMOTE_BASE is only still honoured for configurations from before 4.0.0
    [[ -n $RESTIC_REPO_PATH ]] || RESTIC_REPO_PATH="${REMOTE_BASE:+${REMOTE_BASE%/}/}restic-${BACKUP_NAME}"
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
    LOG_PHASE=backup
    log "Repository: $RESTIC_REPOSITORY"
    (( DRY_RUN )) && log "DRY RUN – nothing will be changed."

    if ! restic_repo_exists; then
        if (( DRY_RUN )); then
            log "Repository does not exist yet – a real run would initialize it."
            log "Dry run finished (${SECONDS}s)."
            exit 0
        fi
        log "Repository does not exist yet – initializing ..."
        set +e
        restic "${RESTIC_ARGS[@]}" init 2>&1 | log_output
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
    local n=0 incomplete=0 src
    for src in "${SOURCES[@]}"; do
        n=$((n + 1))
        log "[$n/${#SOURCES[@]}] Backing up $src ..."
        set +e
        if (( PROGRESS )); then
            # restic only draws its progress bar when stdout is a terminal,
            # so stdout goes there directly; errors are still logged.
            restic "${RESTIC_ARGS[@]}" "${args[@]}" "$src" 2> >(log_output >&2)
            rc=$?
        else
            restic "${RESTIC_ARGS[@]}" "${args[@]}" "$src" 2>&1 | log_output
            rc=${PIPESTATUS[0]}
        fi
        set -e
        case $rc in
            0) SOURCES_OK=$((SOURCES_OK + 1))
               log "[$n/${#SOURCES[@]}] $src done." ;;
            3) incomplete=1
               SOURCES_OK=$((SOURCES_OK + 1))
               log "[$n/${#SOURCES[@]}] $src done."
               warn "$src: some files could not be read (restic exit code 3)." ;;
            *) SOURCES_FAILED=$((SOURCES_FAILED + 1))
               log_level ERROR "[$n/${#SOURCES[@]}] ERROR for $src (restic exit code $rc)."
               failed+=("$src") ;;
        esac
    done

    (( ${#failed[@]} == 0 )) \
        || die "Backup $TODAY is INCOMPLETE – failed: ${failed[*]}"

    LOG_PHASE=retention
    # Retention: only snapshots of this host; prune removes unreferenced data
    if (( incomplete )); then
        warn "Retention skipped because files could not be read; keeping previous snapshots."
    elif (( ${#RESTIC_FORGET_OPTS[@]} > 0 )); then
        log "Removing old snapshots (${RESTIC_FORGET_OPTS[*]}) ..."
        local -a fargs=(forget --host "$BACKUP_NAME" --prune "${RESTIC_FORGET_OPTS[@]}")
        (( DRY_RUN )) && fargs+=(--dry-run)
        set +e
        restic "${RESTIC_ARGS[@]}" "${fargs[@]}" 2>&1 | log_output
        rc=${PIPESTATUS[0]}
        set -e
        (( rc == 0 )) || warn "Removing old snapshots failed (restic exit code $rc)."
    fi
}

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

restic_setup

# Progress display only makes sense on a terminal (not under systemd/cron)
if (( PROGRESS )) && [[ ! -t 1 ]]; then
    log "Note: -v needs a terminal – progress display disabled."
    PROGRESS=0
fi

# Only one instance per configuration at a time. The lock is held on the
# configuration file itself (opened read-only), so no lock file is needed –
# a lock file in /tmp breaks when another user created it (fs.protected_regular).
exec 9<"$CONFIG"
flock -n 9 || die "A backup with $CONFIG is already running."

LOG_PHASE=checks
check_old_hooks
check_free_space

if (( ! DRY_RUN )); then
    validate_actions
    POST_PENDING=1
    run_actions pre || exit 1
fi

# Pre actions may create sources such as the database dump directory.
LOG_PHASE=checks
(( ${#SOURCES[@]} > 0 )) || die "SOURCES is empty"
for src in "${SOURCES[@]}"; do
    [[ $src == /* ]] || die "Source must be an absolute path: $src"
    [[ -e $src ]] || die "Source does not exist: $src"
done
backup_restic
