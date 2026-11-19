# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate: backup helpers for recipe hooks (usually pre_update).
#
#   backup_sqlite DB [NAME]               consistent copy (sqlite3 .backup),
#                                         integrity-checked
#   backup_pg CONTAINER [DBUSER] [NAME]   pg_dumpall inside the container,
#                                         gzipped (DBUSER defaults to postgres)
#
# A backup goes to BACKUP_DIR (default: the app's state directory/backups,
# made 0700) as NAME-<version>-<YYYYmmddHHMMSS>.<ext>, mode 0600; <version>
# is OLD_VERSION with anything but letters, digits, . and _ turned into _,
# so the shape is exact. It is written as .part and renamed only once
# complete. The newest BACKUP_KEEP of that exact shape per NAME are kept.
# A helper that fails returns 1, which fails the hook, so the update stops
# before anything changed.

# backup_path NAME EXT: create BACKUP_DIR, print the new backup's path.
backup_path() {
    local dir="${BACKUP_DIR:-$STATE_DIR/backups}"
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || { log err msg="backup name must be letters, digits, . _ -" name="$1"; return 1; }
    [[ "$dir" == /* ]] || { log err msg="BACKUP_DIR must be an absolute path" dir="$dir"; return 1; }
    # sqlite3 reads the path inside '...' quotes
    [[ "$dir" != *"'"* ]] || { log err msg="BACKUP_DIR must not contain a quote" dir="$dir"; return 1; }
    # Backups hold the app's secrets: private even when the dir already existed.
    { mkdir -p -- "$dir" && chmod 0700 -- "$dir"; } || { log err msg="could not create BACKUP_DIR" dir="$dir"; return 1; }
    local v="${OLD_VERSION:-unknown}" out
    v="${v//[^A-Za-z0-9._]/_}"
    out="$dir/$1-$v-$(date +%Y%m%d%H%M%S).$2"
    # One per second: never overwrite a backup taken in the same second.
    while [[ -e "$out" ]]; do sleep 1; out="$dir/$1-$v-$(date +%Y%m%d%H%M%S).$2"; done
    printf '%s' "$out"
}

# backup_prune NAME EXT: keep the newest BACKUP_KEEP backups of NAME. Only
# files of the exact shape count: NAME "db" never touches "db-old-..." files.
backup_prune() {
    local dir="${BACKUP_DIR:-$STATE_DIR/backups}" f n=0
    # NAME and EXT with their dots escaped; the version part has no '-'.
    local re="^${1//./\\.}-[A-Za-z0-9._]+-[0-9]{14}\\.${2//./\\.}\$"
    while read -r f; do
        [[ "${f##*/}" =~ $re ]] || continue
        n=$((n + 1))
        (( n <= BACKUP_KEEP )) || { rm -f -- "$f"; log info event=backup-pruned file="$f"; }
    done < <(find "$dir" -maxdepth 1 -type f -name "$1-*.$2" -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
}

backup_sqlite() {
    local db="$1" name="${2:-}" out
    [[ -n "$name" ]] || { name="${db##*/}"; name="${name%.*}"; }
    if [[ ! -e "$db" ]]; then
        # A fresh install has no database yet; a wrong path shows up here.
        log warning msg="backup skipped: database does not exist" db="$db"
        return 0
    fi
    [[ -f "$db" ]] || { log err msg="backup_sqlite: not a regular file" db="$db"; return 1; }
    command -v sqlite3 >/dev/null 2>&1 || { log err msg="backup_sqlite needs sqlite3"; return 1; }
    out="$(backup_path "$name" sqlite3)" || return 1
    if sqlite3 "$db" ".backup '$out.part'" \
        && [[ "$(sqlite3 "$out.part" 'PRAGMA integrity_check;')" == ok ]] \
        && chmod 0600 -- "$out.part" && mv -f -- "$out.part" "$out"; then
        log info event=backup file="$out"
        backup_prune "$name" sqlite3
    else
        rm -f -- "$out.part"
        log err msg="sqlite backup failed" db="$db"
        return 1
    fi
}

backup_pg() {
    local ctr="$1" user="${2:-postgres}" name="${3:-$1}" out
    out="$(backup_path "$name" sql.gz)" || return 1
    # pipefail: a failing pg_dumpall fails the pipe even though gzip succeeds.
    if podman_as_owner exec "$ctr" pg_dumpall --clean --if-exists -U "$user" | gzip > "$out.part" \
        && gzip -t -- "$out.part" \
        && [[ -n "$(gzip -dc -- "$out.part" | head -c 1)" ]] \
        && chmod 0600 -- "$out.part" && mv -f -- "$out.part" "$out"; then
        log info event=backup file="$out"
        backup_prune "$name" sql.gz
    else
        rm -f -- "$out.part"
        log err msg="postgres backup failed" container="$ctr"
        return 1
    fi
}
