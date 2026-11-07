#!/bin/bash
#
# nextcloud-backup.sh – Nextcloud backup around backup.sh
#
# 1. detects the Nextcloud installation, its user, the PHP version in use and
#    the database from the Nextcloud configuration,
# 2. enables maintenance mode and dumps the database,
# 3. runs backup.sh (same directory) with all given options,
# 4. ALWAYS ends maintenance mode afterwards – also after errors, Ctrl+C or
#    "systemctl stop".
#
# backup.sh mails its own failures. This script mails (to MAIL_TO of the
# backup configuration) what happens around it: failures before the backup
# (e.g. the dump), a maintenance mode that could not be ended, and warnings.
#
# Usage: nextcloud-backup.sh [--check] [backup.sh options]
#   --check   only show what is detected, change nothing
#   -n        dry run: no maintenance mode, no dump, "backup.sh -n"
#   -c FILE   backup configuration (as for backup.sh)
#
# Overrides (optional) in nextcloud.conf next to the backup configuration
# (default /etc/backup/nextcloud.conf), sourced as Bash:
#   NEXTCLOUD_DIR="/var/www/nextcloud"
#   NEXTCLOUD_PHP="/usr/bin/php8.3"
#   NEXTCLOUD_DUMP=1                          # 0 = maintenance mode only
#   NEXTCLOUD_DUMP_DIR="/var/backups/nextcloud"
#
set -euo pipefail

# cron starts jobs with PATH=/usr/bin:/bin – add the sbin directories so that
# runuser, sendmail etc. are found there too
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    [[ ":$PATH:" == *":$d:"* ]] || PATH="$PATH:$d"
done
export PATH

readonly SELF="$(realpath -- "$0")"
BACKUP_SH="${BACKUP_SH:-$(dirname -- "$SELF")/backup.sh}"

NEXTCLOUD_DIR=""
NEXTCLOUD_PHP=""
NEXTCLOUD_DUMP=1
NEXTCLOUD_DUMP_DIR="/var/backups/nextcloud"

CHECK=0
DRY_RUN=0
CONFIG="${BACKUP_CONF:-/etc/backup/backup.conf}"
BACKUP_ARGS=()

MAINT_PENDING=0     # 1 = maintenance mode must be ended on exit
BACKUP_RAN=0        # 1 = backup.sh ran (it reports its own failures)
OFF_FAILED=0
LAST_ERROR=""
WARNINGS=()
LINES=()            # this script's log lines, for the mail

# --- Arguments ---------------------------------------------------------------

while (( $# )); do
    case $1 in
        --check) CHECK=1; shift ;;
        -c)      CONFIG="${2:?-c requires a file name}"; BACKUP_ARGS+=("$1" "$2"); shift 2 ;;
        -n)      DRY_RUN=1; BACKUP_ARGS+=("$1"); shift ;;
        -h|--help|-V|--version|--init-config|--test-mail|--restic)
                 # Not a backup run: hand over to backup.sh unchanged
                 exec "$BACKUP_SH" "${BACKUP_ARGS[@]}" "$@" ;;
        *)       BACKUP_ARGS+=("$1"); shift ;;
    esac
done

# --- Settings from the backup configuration ----------------------------------

[[ -x $BACKUP_SH ]] || { echo "Error: $BACKUP_SH not found or not executable." >&2; exit 1; }
[[ -r $CONFIG ]]    || { echo "Error: configuration not readable: $CONFIG" >&2; exit 1; }

MAIL_TO="" MAIL_FROM="" LOG_FILE="/dev/null" BACKUP_NAME="" SOURCES=()
config_values="$(bash -e -c '
    MAIL_TO=""; MAIL_FROM=""; LOG_FILE="/dev/null"; BACKUP_NAME="$(hostname -s)"; SOURCES=()
    source "$1" >/dev/null 2>&1
    declare -p MAIL_TO MAIL_FROM LOG_FILE BACKUP_NAME SOURCES' _ "$CONFIG")" || {
    echo "Error: could not load configuration: $CONFIG" >&2
    exit 1
}
eval "$config_values"
unset config_values
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

CONF_FILE="$(dirname -- "$CONFIG")/nextcloud.conf"

# --- Logging and mail --------------------------------------------------------

log() {
    local line
    line="$(date '+%F %T') Nextcloud: $*"
    LINES+=("$line")
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}
die()  { LAST_ERROR="$*"; log "ERROR: $*"; exit 1; }
warn() { WARNINGS+=("$*"); log "Warning: $*"; }

send_mail() {
    local subject="$1" sm rc=0
    [[ -n $MAIL_TO ]] || return 0
    sm="$(command -v sendmail 2>/dev/null || true)"
    [[ -z $sm && -x /usr/sbin/sendmail ]] && sm=/usr/sbin/sendmail
    if [[ -z $sm ]]; then
        log "Warning: cannot send mail – no sendmail found."
        return 1
    fi
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

notify() {
    local rc="$1" status w
    (( DRY_RUN || CHECK )) && return 0
    if (( OFF_FAILED )); then
        status="FAILED – Nextcloud still in maintenance mode"
    elif (( rc != 0 && ! BACKUP_RAN )); then
        status="FAILED before the backup"
    elif (( ${#WARNINGS[@]} > 0 )); then
        status="WARNING"
    else
        return 0
    fi
    {
        echo "Nextcloud backup $BACKUP_NAME on $(hostname -f 2>/dev/null || hostname): $status (exit code $rc)"
        echo
        echo "Configuration: $CONFIG"
        echo "Nextcloud:     ${NEXTCLOUD_DIR:-?}"
        [[ -n $LAST_ERROR ]] && printf '\nError:\n  %s\n' "$LAST_ERROR"
        if (( ${#WARNINGS[@]} > 0 )); then
            printf '\nWarnings:\n'
            for w in "${WARNINGS[@]}"; do printf '  - %s\n' "$w"; done
        fi
        printf '\n--- Log of %s ---\n' "${SELF##*/}"
        printf '%s\n' "${LINES[@]}"
    } | send_mail "[backup] $status: $BACKUP_NAME ($(date +%F))"
}

# EXIT trap: always end maintenance mode, then mail if needed
on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if (( MAINT_PENDING )); then
        MAINT_PENDING=0
        if occ maintenance:mode --off >/dev/null 2>&1 \
           && [[ $(sysconf maintenance) != true ]]; then
            log "maintenance mode off."
        else
            OFF_FAILED=1
            LAST_ERROR="${LAST_ERROR:+$LAST_ERROR; }Could not end maintenance mode – Nextcloud is still offline! Run: occ maintenance:mode --off"
            log "ERROR: could not end maintenance mode – Nextcloud is still offline!"
            (( rc == 0 )) && rc=1
        fi
    fi
    notify "$rc"
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Only one run at a time (backup.sh itself locks its configuration file)
exec 8<"$SELF"
flock -n 8 || die "another ${SELF##*/} is already running."

# --- Overrides ---------------------------------------------------------------

if [[ -e $CONF_FILE ]]; then
    # Sourced as root: refuse a file others could have changed
    read -r owner perms < <(stat -L -c '%u %a' -- "$CONF_FILE")
    if (( EUID == 0 )) && (( owner != 0 || (8#$perms & 8#022) )); then
        die "$CONF_FILE is not owned by root or writable by group/others."
    fi
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# --- Installation directory --------------------------------------------------

find_nextcloud_dir() {
    local -a found=()
    local occ d
    while IFS= read -r occ; do
        d="$(dirname -- "$occ")"
        [[ -f $d/config/config.php && -f $d/version.php ]] || continue
        d="$(realpath -- "$d")"
        [[ " ${found[*]} " == *" $d "* ]] || found+=("$d")
    done < <(find /var/www /srv /opt /usr/share/nextcloud /usr/local/www \
                  -maxdepth 4 -type f -name occ 2>/dev/null | sort)

    case ${#found[@]} in
        1) NEXTCLOUD_DIR="${found[0]}" ;;
        0) local hint=""
           command -v nextcloud.occ >/dev/null 2>&1 \
               && hint=" A snap installation was found; it is not supported (use nextcloud.export)."
           die "no Nextcloud installation found under /var/www, /srv, /opt.${hint} Set NEXTCLOUD_DIR in $CONF_FILE." ;;
        *) die "several Nextcloud installations found (${found[*]}). Set NEXTCLOUD_DIR in $CONF_FILE." ;;
    esac
}

[[ -n $NEXTCLOUD_DIR ]] || find_nextcloud_dir
[[ -f $NEXTCLOUD_DIR/occ && -f $NEXTCLOUD_DIR/config/config.php ]] \
    || die "$NEXTCLOUD_DIR is not a Nextcloud installation (occ or config/config.php missing)."

NC_USER="$(stat -c %U -- "$NEXTCLOUD_DIR/config/config.php")"
[[ $NC_USER != root ]] || die "config/config.php is owned by root – cannot determine the web server user."

# --- PHP version -------------------------------------------------------------

# Prints the PHP versions in use by the web server, best guess first.
php_versions_in_use() {
    local -a running=() referenced=()
    local v

    # php-fpm master processes: "php-fpm: master process (/etc/php/8.3/fpm/php-fpm.conf)"
    mapfile -t running < <(ps -eo args= 2>/dev/null \
        | sed -nE 's#^php-fpm[0-9.]*: master process \(/etc/php/([0-9]+\.[0-9]+)/fpm/.*#\1#p' \
        | sort -uV)
    # Apache with mod_php
    if [[ -d /etc/apache2/mods-enabled ]]; then
        while IFS= read -r v; do running+=("$v"); done < <(
            find /etc/apache2/mods-enabled -maxdepth 1 -name 'php*.load' -printf '%f\n' 2>/dev/null \
            | sed -nE 's/^php([0-9]+\.[0-9]+)\.load$/\1/p')
    fi

    # FPM sockets referenced in the web server configuration, first in the
    # files that mention the Nextcloud directory
    mapfile -t referenced < <(
        { grep -rlsF -- "$NEXTCLOUD_DIR" /etc/nginx /etc/apache2 2>/dev/null \
              | xargs -r grep -hoE 'php[0-9]+\.[0-9]+-fpm' 2>/dev/null
          grep -rhoE 'php[0-9]+\.[0-9]+-fpm' /etc/nginx /etc/apache2 2>/dev/null
        } | sed -E 's/^php([0-9.]+)-fpm$/\1/' | awk '!seen[$0]++')

    # Versions both running and referenced first, then the other running ones
    # (newest first), then the other referenced ones
    {
        for v in "${referenced[@]}"; do
            [[ " ${running[*]} " == *" $v "* ]] && echo "$v"
        done
        printf '%s\n' "${running[@]}" | sort -rV
        printf '%s\n' "${referenced[@]}"
    } | awk 'NF && !seen[$0]++'
}

# Runs occ as the Nextcloud user with the given PHP binary.
# Usage: occ_with PHP ARGS...
occ_with() {
    local php="$1"; shift
    local -a cmd=("$php" -d apc.enable_cli=1 "$NEXTCLOUD_DIR/occ" --no-interaction "$@")
    if [[ $(id -un) == "$NC_USER" ]]; then
        (cd "$NEXTCLOUD_DIR" && "${cmd[@]}")
    else
        (cd "$NEXTCLOUD_DIR" && runuser -u "$NC_USER" -- "${cmd[@]}")
    fi
}

# Sets NC_PHP to the first PHP binary that can run this Nextcloud's occ
detect_php() {
    local -a candidates=()
    local v bin
    if [[ -n $NEXTCLOUD_PHP ]]; then
        candidates=("$NEXTCLOUD_PHP")
    else
        while IFS= read -r v; do
            bin="$(command -v "php$v" 2>/dev/null || true)"
            [[ -n $bin ]] && candidates+=("$bin")
        done < <(php_versions_in_use)
        # Fallback: default php, then every installed version, newest first
        bin="$(command -v php 2>/dev/null || true)"
        [[ -n $bin ]] && candidates+=("$bin")
        while IFS= read -r bin; do candidates+=("$bin"); done < <(
            compgen -c php | grep -E '^php[0-9]+\.[0-9]+$' | sort -urV \
            | while IFS= read -r v; do command -v "$v"; done)
    fi

    local -A tried=()
    for bin in "${candidates[@]}"; do
        [[ -n ${tried[$bin]:-} ]] && continue
        tried[$bin]=1
        [[ -x $bin ]] || continue
        if occ_with "$bin" status >/dev/null 2>&1; then
            NC_PHP="$bin"
            return 0
        fi
    done
    local list="${!tried[*]}"
    die "no PHP binary can run occ (tried: ${list:-none}). Set NEXTCLOUD_PHP in $CONF_FILE."
}

NC_PHP=""
detect_php
occ() { occ_with "$NC_PHP" "$@"; }

# Value from the (merged) system configuration, empty if unset
sysconf() { occ config:system:get "$1" 2>/dev/null || true; }

NC_VERSION="$(sysconf version)"
DB_TYPE="$(sysconf dbtype)"
DATA_DIR="$(sysconf datadirectory)"
MAINTENANCE="$(sysconf maintenance)"

log "$NEXTCLOUD_DIR (version ${NC_VERSION:-?}, user $NC_USER, $("$NC_PHP" -r 'echo "PHP ", PHP_VERSION;' 2>/dev/null || echo "$NC_PHP"), database ${DB_TYPE:-?})"

# --- Are the relevant folders backed up? -------------------------------------

need=("$NEXTCLOUD_DIR/config")
[[ -n $DATA_DIR ]] && need+=("$DATA_DIR")
(( NEXTCLOUD_DUMP )) && need+=("$NEXTCLOUD_DUMP_DIR")
for path in "${need[@]}"; do
    covered=0
    for src in "${SOURCES[@]}"; do
        src="${src%/}"
        if [[ -z $src || $path == "$src" || $path == "$src"/* ]]; then covered=1; break; fi
    done
    (( covered )) || warn "$path is not in SOURCES of $CONFIG – it will not be backed up."
done

if (( CHECK )); then
    log "maintenance mode is currently ${MAINTENANCE:-false}; data directory ${DATA_DIR:-?}."
    if (( NEXTCLOUD_DUMP )); then
        log "check only – a real run would enable maintenance mode, dump the database to $NEXTCLOUD_DUMP_DIR and run $BACKUP_SH."
    else
        log "check only – a real run would enable maintenance mode and run $BACKUP_SH (database dump disabled)."
    fi
    exit 0
fi

# --- Maintenance mode and dump -----------------------------------------------

dump_database() {
    local db_name db_host db_port db_user db_pass db_socket="" dump tmp started=$SECONDS
    db_name="$(sysconf dbname)"
    db_host="$(sysconf dbhost)"
    db_port="$(sysconf dbport)"
    db_user="$(sysconf dbuser)"
    db_pass="$(sysconf dbpassword)"

    # dbhost: "host", "host:port", "host:/socket", "[::1]:port", "/socket"
    case $db_host in
        /*)      db_socket="$db_host"; db_host="" ;;
        *:/*)    db_socket="${db_host#*:}"; db_host="${db_host%%:*}" ;;
        \[*\]:*) db_port="${db_host##*:}"; db_host="${db_host%:*}"; db_host="${db_host#[}"; db_host="${db_host%]}" ;;
        \[*\])   db_host="${db_host#[}"; db_host="${db_host%]}" ;;
        *:*)     db_port="${db_host##*:}"; db_host="${db_host%%:*}" ;;
    esac

    mkdir -p -m 700 "$NEXTCLOUD_DUMP_DIR"
    case $DB_TYPE in
        mysql)
            local dump_cmd defaults
            dump_cmd="$(command -v mariadb-dump || command -v mysqldump || true)"
            [[ -n $dump_cmd ]] || die "neither mariadb-dump nor mysqldump found (package mariadb-client or mysql-client)."
            # Credentials via a temporary option file, never on the command line
            defaults="$(umask 077; mktemp)"
            esc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
            {
                echo "[client]"
                echo "user=\"$(esc "$db_user")\""
                echo "password=\"$(esc "$db_pass")\""
                [[ -n $db_host ]]   && echo "host=\"$(esc "$db_host")\""
                [[ -n $db_port ]]   && echo "port=$db_port"
                [[ -n $db_socket ]] && echo "socket=\"$(esc "$db_socket")\""
            } > "$defaults"
            dump="$NEXTCLOUD_DUMP_DIR/nextcloud-db.sql.gz"; tmp="$dump.tmp"
            if ! (umask 077; "$dump_cmd" --defaults-extra-file="$defaults" --single-transaction --quick \
                    --default-character-set=utf8mb4 --no-tablespaces --routines --events \
                    "$db_name" | gzip > "$tmp"); then
                rm -f -- "$defaults" "$tmp"
                die "database dump failed (${dump_cmd##*/})."
            fi
            rm -f -- "$defaults"
            ;;
        pgsql)
            command -v pg_dump >/dev/null || die "pg_dump not found (package postgresql-client)."
            local -a args=(--no-password --dbname="$db_name" --username="$db_user")
            [[ -n $db_host$db_socket ]] && args+=(--host="${db_socket:-$db_host}")
            [[ -n $db_port ]] && args+=(--port="$db_port")
            dump="$NEXTCLOUD_DUMP_DIR/nextcloud-db.sql.gz"; tmp="$dump.tmp"
            if ! (umask 077; PGPASSWORD="$db_pass" pg_dump "${args[@]}" | gzip > "$tmp"); then
                rm -f -- "$tmp"
                die "database dump failed (pg_dump)."
            fi
            ;;
        sqlite|sqlite3)
            local db="${DATA_DIR%/}/${db_name:-owncloud}.db"
            [[ -f $db ]] || die "SQLite database $db not found."
            dump="$NEXTCLOUD_DUMP_DIR/nextcloud-db.sqlite"; tmp="$dump.tmp"
            command -v sqlite3 >/dev/null || die "sqlite3 not found (package sqlite3); a plain copy is unsafe with WAL databases."
            # Quote the shell's .backup argument, including embedded quotes.
            local sqlite_target="${tmp//\\/\\\\}"
            sqlite_target="${sqlite_target//\"/\\\"}"
            (umask 077; sqlite3 "$db" ".backup \"$sqlite_target\"") \
                || { rm -f -- "$tmp"; die "SQLite backup failed."; }
            ;;
        *)
            die "unsupported database type '${DB_TYPE:-empty}'. Set NEXTCLOUD_DUMP=0 in $CONF_FILE to skip the dump."
            ;;
    esac

    [[ -s $tmp ]] || { rm -f -- "$tmp"; die "database dump is empty."; }
    mv -f -- "$tmp" "$dump"     # a failed dump never replaces the last good one
    log "database dumped to $dump ($(du -h -- "$dump" | cut -f1), $((SECONDS - started))s)."
}

if (( DRY_RUN )); then
    log "dry run – no maintenance mode, no database dump."
else
    MAINT_PENDING=1     # from here on maintenance mode is always ended on exit
    if [[ $MAINTENANCE == true ]]; then
        log "maintenance mode was already on – it will be switched off after the backup."
    else
        occ maintenance:mode --on >/dev/null || die "could not enable maintenance mode."
        log "maintenance mode on."
    fi
    if (( NEXTCLOUD_DUMP )); then
        dump_database
    else
        log "database dump disabled."
    fi
fi

# --- Backup ------------------------------------------------------------------

BACKUP_RAN=1
rc=0
"$BACKUP_SH" "${BACKUP_ARGS[@]}" || rc=$?
exit "$rc"
