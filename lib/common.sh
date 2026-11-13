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
MAIL_TO="" MAIL_FROM="" GITHUB_TOKEN_FILE="" GITEA_TOKEN_FILE="" CURL_OPTS=()

# One key=value line per event: easy to read in the journal, easy to parse in
# Loki (| logfmt). Goes to stderr; systemd puts it in the journal.
log() {
    local level="$1"; shift
    [[ "$level" == debug && "$RELROTATE_DEBUG" != 1 ]] && return 0
    local line="level=$level"
    [[ -n "$APP" ]] && line+=" app=$APP"
    local kv
    for kv in "$@"; do
        local k="${kv%%=*}" v="${kv#*=}"
        if [[ "$v" =~ [[:space:]\"] ]]; then
            v="${v//\"/\'}"; line+=" $k=\"$v\""
        else
            line+=" $k=$v"
        fi
    done
    printf 'relrotate %s\n' "$line" >&2
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
    if [[ -z "$SENDMAIL" ]]; then
        local s
        for s in /usr/sbin/sendmail /usr/lib/sendmail; do
            [[ -x "$s" ]] && { SENDMAIL="$s"; break; }
        done
    fi
}

require_tools() {
    local t missing=()
    for t in curl jq sha256sum tar sort flock mktemp readlink; do
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
    local major="${VERSION%%.*}" rest="${VERSION#*.}"
    local minor="${rest%%.*}"
    s="${s//'${VERSION}'/$VERSION}"
    s="${s//'${TAG}'/${TAG:-}}"
    s="${s//'${ARCH}'/$ARCH}"
    s="${s//'${MAJOR}'/$major}"
    s="${s//'${MINOR}'/$minor}"
    printf '%s' "$s"
}

# Normalise to MAJOR.MINOR.PATCH (pads missing parts with 0).
norm_version() {
    local v="$1" a b c
    IFS=. read -r a b c _ <<<"$v"
    printf '%d.%d.%d' "${a:-0}" "${b:-0}" "${c:-0}"
}

# version_gt A B: true if A > B
version_gt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
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

notify() {
    local subject="$1" body="$2"
    log info event=notify subject="$subject"
    [[ -n "$MAIL_TO" && -n "$SENDMAIL" ]] || { log debug msg="mail not configured, skipping"; return 0; }
    local host; host="$(hostname -f 2>/dev/null || hostname)"
    {
        [[ -n "$MAIL_FROM" ]] && printf 'From: %s\n' "$MAIL_FROM"
        printf 'To: %s\n' "$MAIL_TO"
        printf 'Subject: [relrotate] %s %s: %s\n' "$host" "$APP" "$subject"
        printf 'Content-Type: text/plain; charset=utf-8\n\n'
        printf '%s\n\n' "$body"
        printf -- '-- \nrelrotate status %s\n' "$APP"
    } | "$SENDMAIL" -t -oi || log warning msg="sending mail failed"
}

# SERVICE may list several units; they restart in the order given.
restart_service() {
    [[ "$RESTART" == yes && -n "$SERVICE" ]] || return 0
    local unit
    for unit in $SERVICE; do
        log info event=restart service="$unit"
        systemctl_for_app restart "$unit" || return 1
    done
}

# Run systemctl as the quadlet owner for rootless containers, else as root.
systemctl_for_app() {
    if [[ -n "${QUADLET_USER:-}" ]]; then
        "$SYSTEMCTL" --user -M "${QUADLET_USER}@" "$@"
    else
        "$SYSTEMCTL" "$@"
    fi
}

run_healthcheck() {
    local i
    for (( i = 1; i <= HEALTH_RETRIES; i++ )); do
        if health_once; then
            log info event=healthy attempt="$i"
            return 0
        fi
        log debug msg="health check attempt $i failed"
        sleep "$HEALTH_DELAY"
    done
    log err event=unhealthy attempts="$HEALTH_RETRIES"
    return 1
}

health_once() {
    if declare -F healthcheck >/dev/null; then
        healthcheck
    elif [[ -n "$HEALTH_URL" ]]; then
        "$CURL" -fsS -o /dev/null --max-time 10 "$HEALTH_URL"
    elif [[ -n "$SERVICE" && "$RESTART" == yes ]]; then
        local unit
        for unit in $SERVICE; do
            systemctl_for_app is-active --quiet "$unit" || return 1
        done
    else
        return 0
    fi
}
