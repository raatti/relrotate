# shellcheck shell=bash
# relrotate: logging, config, locking, mail, version helpers.

RELROTATE_DEBUG="${RELROTATE_DEBUG:-0}"
APP="${APP:-}"

# Commands are indirected so tests (and odd systems) can swap them.
SYSTEMCTL="${RELROTATE_SYSTEMCTL:-systemctl}"
# shellcheck disable=SC2034  # used in layout.sh
PODMAN="${RELROTATE_PODMAN:-podman}"
SENDMAIL="${RELROTATE_SENDMAIL:-}"
CURL="${RELROTATE_CURL:-curl}"

# Global settings (/etc/relrotate/relrotate.conf)
# shellcheck disable=SC2034  # set by relrotate.conf, read in source.sh/verify.sh
MAIL_TO="" MAIL_FROM="" GITHUB_TOKEN_FILE="" GITEA_TOKEN_FILE="" GITEA_TOKEN_HOSTS="" CURL_OPTS=()
# shellcheck disable=SC2034  # MIN_AGE_DAYS: recipe default, read in source.sh
NOTIFY=() NOTIFY_POLICY="each" MIN_AGE_DAYS=0

# One key=value line per event: easy to read in the journal, easy to parse in
# Loki (| logfmt). Goes to stderr; systemd puts it in the journal.
log() {
    local level="$1"; shift
    [[ "$level" == debug && "$RELROTATE_DEBUG" != 1 ]] && return 0
    local line="level=$level"
    [[ -n "$APP" ]] && line+=" app=$(logfmt_value "$APP")"
    local kv
    for kv in "$@"; do
        line+=" ${kv%%=*}=$(logfmt_value "${kv#*=}")"
    done
    printf 'relrotate %s\n' "$line" >&2
}

# One log value: backslashes, then newlines, are escaped so a value cannot
# forge a line and a literal "\n" stays distinguishable;
# values with spaces or quotes are quoted.
logfmt_value() {
    local v="$1"
    v="${v//\\/\\\\}"; v="${v//$'\n'/\\n}"; v="${v//$'\r'/\\r}"
    if [[ "$v" =~ [[:space:]\"] ]]; then v="${v//\"/\'}"; printf '"%s"' "$v"; else printf '%s' "$v"; fi
}

die() {
    local rc="$1"; shift
    log err msg="$*"
    exit "$rc"
}

load_global_conf() {
    local conf="$CONF_DIR/relrotate.conf"
    if [[ -r "$conf" ]]; then
        # shellcheck disable=SC1090
        . "$conf"
    fi
    case "$NOTIFY_POLICY" in each|failures|digest) ;; *) die 2 "NOTIFY_POLICY must be each|failures|digest" ;; esac
    local d
    for d in "${NOTIFY[@]+"${NOTIFY[@]}"}"; do
        [[ "$d" =~ ^(discord|telegram|ntfy|webhook):/ ]] \
            || die 2 "NOTIFY entries must be discord|telegram|ntfy|webhook:/absolute/file, not: $d"
    done
    if [[ -z "$SENDMAIL" ]]; then
        local s
        for s in /usr/sbin/sendmail /usr/lib/sendmail; do
            # if, not &&: as the function's last command a false test would
            # end the run (set -e) on a host with no MTA.
            if [[ -x "$s" ]]; then SENDMAIL="$s"; break; fi
        done
    fi
}

require_tools() {
    local t missing=()
    for t in curl jq sha256sum tar sort flock mktemp readlink timeout; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    (( ${#missing[@]} == 0 )) || die 2 "missing required tools: ${missing[*]}"
}

acquire_lock() {
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || die 1 "$APP: another relrotate run holds the lock"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l) echo armv7 ;;
        *) uname -m ;;
    esac
}

detect_distro() {
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id="$(. /etc/os-release; echo "${ID:-}")"
        # shellcheck disable=SC1091
        like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
    fi
    case " $id $like " in
        *" rhel "*|*" fedora "*|*" centos "*) echo rhel ;;
        *" debian "*|*" ubuntu "*) echo debian ;;
        *) echo other ;;
    esac
}

selinux_on() {
    command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled
}

# Expand ${VERSION} ${TAG} ${ARCH} ${MAJOR} ${MINOR} in a template string
# without eval. Recipes must single-quote templates.
# shellcheck disable=SC2016,SC2031  # literal ${...} patterns on purpose
expand() {
    local s="$1"
    local nv="${VERSION%%-*}"   # numeric part: MAJOR/MINOR ignore a prerelease suffix
    local major="${nv%%.*}" rest="${nv#*.}"
    local minor="${rest%%.*}"
    # Replacements are quoted: on bash 5.2 an unquoted & means the matched text.
    s="${s//'${VERSION}'/"$VERSION"}"
    s="${s//'${TAG}'/"${TAG:-}"}"
    s="${s//'${ARCH}'/"$ARCH"}"
    s="${s//'${MAJOR}'/"$major"}"
    s="${s//'${MINOR}'/"$minor"}"
    printf '%s' "$s"
}

# clean_version RAW: print RAW without surrounding whitespace and a leading
# v; fails unless what is left looks like a version: digits, up to three more
# .digits groups, then an optional suffix (-rc1, +b1, b6, .post1). Wider than
# source.sh on purpose: the installed value may come from any program.
clean_version() {
    local v="${1#"${1%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"; v="${v#v}"
    local lead="${v%%[!0-9.]*}"   # the numeric components; a long suffix (a date) is fine
    [[ "$v" =~ ^[0-9]+(\.[0-9]+){0,3}(([-+.][0-9A-Za-z]|[A-Za-z])([0-9A-Za-z._+-]*[0-9A-Za-z])?)?$ && ! "$lead" =~ [0-9]{10} ]] && printf '%s' "$v"
}

# Normalise to MAJOR.MINOR.PATCH (pads missing parts with 0, drops a
# -prerelease suffix; 10# keeps 08 from being read as octal). Components
# longer than 9 digits wrap: callers keep them out (source.sh, clean_version).
norm_version() {
    local v="${1%%-*}" a b c
    IFS=. read -r a b c _ <<<"$v"
    a="${a%%[!0-9]*}" b="${b%%[!0-9]*}" c="${c%%[!0-9]*}"   # 0b6 -> 0, 3+b1 -> 3
    printf '%d.%d.%d' "$((10#${a:-0}))" "$((10#${b:-0}))" "$((10#${c:-0}))"
}

# same_version A B: equal, whatever the spelling (1.9 = 1.9.0 = 01.9.0).
same_version() { [[ "$(canon_version "$1")" == "$(canon_version "$2")" ]]; }

# canon_version V: V as MAJOR.MINOR.PATCH plus its -suffix; what is not a
# version is left alone. Only for comparing: state and dirs keep V's spelling.
canon_version() {
    if [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-.*)?$ ]]; then printf '%s%s' "$(norm_version "$1")" "${BASH_REMATCH[2]}"
    else printf '%s' "$1"; fi
}

# version_gt A B: true if A > B. '-' becomes '~' for the comparison so that
# 1.3.0-rc1 sorts below 1.3.0.
version_gt() {
    local t='~' a b
    a="$(canon_version "$1")" b="$(canon_version "$2")"
    a="${a//-/$t}" b="${b//-/$t}"
    [[ "$a" != "$b" ]] && [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
}

same_major() { [[ "${1%%.*}" == "${2%%.*}" ]]; }
same_minor() {
    local a b
    a="$(norm_version "$1")"; b="$(norm_version "$2")"
    [[ "${a%.*}" == "${b%.*}" ]]
}

# allowed_by_policy CURRENT CANDIDATE
# Semver: below 1.0 a minor bump may break things, so for 0.x versions
# POLICY=minor only allows patches (0.19.0 -> 0.19.2, not 0.20.0).
allowed_by_policy() {
    case "$POLICY" in
        patch) same_minor "$1" "$2" ;;
        minor)
            if [[ "${1%%.*}" == 0 ]]; then same_minor "$1" "$2"; else same_major "$1" "$2"; fi ;;
        major) return 0 ;;
    esac
}

# hostname may be missing on a minimal host.
host_name() {
    hostname -f 2>/dev/null || hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown
}

# run_hook NAME: run a recipe hook with errexit, so its first failing step
# fails it; sets HOOK_RC (0 when the recipe has no such hook). Call it as a
# plain statement, never in if/||/&&: bash ignores errexit everywhere
# below a condition, subshells included.
run_hook() {
    HOOK_RC=0
    declare -F "$1" >/dev/null || return 0
    local probe
    set +e
    probe="$(set -e; false; echo leaked)"   # not in a condition: that would ignore -e here too
    if [[ -n "$probe" ]]; then
        set -e
        log err msg="internal error: hook called where errexit is ignored; counted as failed" hook="$1"
        HOOK_RC=70; return 0
    fi
    ( set -e; "$1" ) 9>&-
    HOOK_RC=$?
    set -e
    return 0
}

# SERVICE may list several units; they restart in the order given. Forward,
# the first failure stops: the later units keep running the old version and
# the revert is clean. restart_service all (the revert) tries every unit, so
# none is left stopped or on the wrong files; both fail when any unit failed.
restart_service() {
    [[ "$RESTART" == yes && -n "$SERVICE" ]] || return 0
    local unit rc=0
    for unit in $SERVICE; do
        log info event=restart service="$unit"
        systemctl_for_app restart "$unit" || { rc=1; [[ "${1:-}" == all ]] || return 1; }
    done
    return "$rc"
}

# Run systemctl as the quadlet owner for rootless containers, else as root.
# QUADLET_USER is container-only but read here: the service restart is shared
# by every layout, and a hook for it would cost more than this one test.
systemctl_for_app() {
    if [[ -n "${QUADLET_USER:-}" ]]; then
        "$SYSTEMCTL" --user -M "${QUADLET_USER}@" "$@"
    else
        "$SYSTEMCTL" "$@"
    fi
}

# run_healthcheck: sets HEALTHY to 1 or 0 and returns 0. Like run_hook, call
# it as a plain statement: the healthcheck hook runs with errexit.
run_healthcheck() {
    local i
    HEALTHY=0
    for (( i = 1; i <= HEALTH_RETRIES; i++ )); do
        health_once
        if (( HEALTH_OK )); then
            log info event=healthy attempt="$i"
            # shellcheck disable=SC2034  # read by the callers
            HEALTHY=1; return 0
        fi
        log debug msg="health check attempt $i failed"
        sleep "$HEALTH_DELAY"
    done
    log err event=unhealthy attempts="$HEALTH_RETRIES"
}

# health_once: one attempt; sets HEALTH_OK.
health_once() {
    HEALTH_OK=1
    if declare -F healthcheck >/dev/null; then
        run_hook healthcheck
        (( HOOK_RC == 0 )) || HEALTH_OK=0
    elif [[ -n "$HEALTH_URL" ]]; then
        "$CURL" -fsS -o /dev/null --max-time 10 -- "$HEALTH_URL" || HEALTH_OK=0
    elif [[ -n "$SERVICE" && "$RESTART" == yes ]]; then
        local unit
        for unit in $SERVICE; do
            systemctl_for_app is-active --quiet "$unit" || HEALTH_OK=0
        done
    fi
    return 0
}
