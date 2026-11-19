# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate: install layouts.
#
# LAYOUT=symlink    TARGET is a symlink -> RELEASES_DIR/<version>/   (web apps)
# LAYOUT=binary     TARGET is a single executable; old ones kept in state dir
# LAYOUT=container  each quadlet's Image= tag is bumped; all images pulled before
#                   any quadlet changes, all rolled back together (CONTAINERS=())
#
# Each layout is an adapter in lib/layout-<name>.sh that defines
# layout_<name>_<op> for every op below. Callers use: layout <op> [args]
#
#   validate        check the recipe for this layout; die 2 on errors
#   needs_download  true if the release asset must be downloaded first
#   sweep           remove what a killed earlier run left behind; the app
#                   lock is held, so nothing else can own it
#   detect          print the installed version if the layout can tell
#   stage           make VERSION ready to flip to; nothing live changes.
#                   0 = staged, 1 = failed, 3 = VERSION is already live while
#                   state names OLD_VERSION (sets RELEASE_DIR first; the
#                   transaction records it with outcome_already_live)
#   flip            make VERSION live. 0 = done, 1 = nothing changed,
#                   2 = changed and could not be undone (caller rolls back)
#   revert VER      make VER (already staged once) live again; same codes as
#                   flip (2 is optional: an atomic revert never returns it)
#   prune           drop old versions beyond KEEP
#   doctor          check this layout's paths with doctor_ok/doctor_note/doctor_bad
#
# Inputs are the recipe variables plus VERSION, OLD_VERSION, TAG, WORK,
# DOWNLOAD and STATE_DIR. stage sets RELEASE_DIR for the post_extract hook.

# shellcheck disable=SC2034  # read by recipe hooks
RELEASE_DIR=""

# shellcheck source=lib/layout-symlink.sh
. "$LIB_DIR/layout-symlink.sh"
# shellcheck source=lib/layout-binary.sh
. "$LIB_DIR/layout-binary.sh"
# shellcheck source=lib/layout-container.sh
. "$LIB_DIR/layout-container.sh"

layout_known() { declare -F "layout_${LAYOUT}_validate" >/dev/null; }

layout() {
    local op="$1"; shift
    "layout_${LAYOUT}_$op" "$@"
}

# doctor_target_dir: the check shared by the layouts whose TARGET is a path.
doctor_target_dir() {
    local q; q="$(dirname "$TARGET")"
    if [[ -d "$q" && -w "$q" ]]; then doctor_ok "target dir $q writable"
    else doctor_bad "target dir $q missing or not writable"; fi
    if [[ -n "$RELEASES_DIR" ]] && [[ ! -d "$RELEASES_DIR" ]]; then
        doctor_note "RELEASES_DIR $RELEASES_DIR does not exist yet (created on the first update)"
    fi
}

relabel() {
    selinux_on || return 0
    command -v restorecon >/dev/null 2>&1 || return 0
    restorecon -R "$@" 2>/dev/null || log warning msg="restorecon failed" path="$*"
}

# extract_to ARCHIVE DIR STRIP
# Decides the format once, lists tar/zip members and refuses absolute or ..
# paths (and unreadable listings) before extracting anything; DIR must not
# exist yet. After extracting, symlinks leaving DIR refuse the archive.
extract_to() {
    local f="$1" dir="$2" strip="$3" kind="$EXTRACT"
    if [[ "$kind" == auto ]]; then
        case "$f" in
            *.tar.gz|*.tgz) kind=tgz ;;
            *.tar.xz|*.txz) kind=txz ;;
            *.tar.bz2|*.tbz2) kind=tbz2 ;;
            *.tar.zst) kind=tzst ;;
            *.tar) kind=tar ;;
            *.zip) kind=zip ;;
            *.xz) kind=xz ;;
            *.bz2) kind=bz2 ;;
            *.gz) kind=gz ;;
            *) kind=none ;;
        esac
    fi
    local -a z=()
    case "$kind" in
        tgz) z=(-z) ;; txz) z=(-J) ;; tbz2) z=(-j) ;; tzst) z=(--zstd) ;; tar) ;;
    esac
    # Member names: listed with the same format decision, tool errors go to
    # stderr (the journal), a failed listing refuses the archive.
    local listing bad
    case "$kind" in
        tgz|txz|tbz2|tzst|tar)
            listing="$(tar -t "${z[@]}" -f "$f")" \
                || { log err msg="cannot list archive" file="$f"; return 1; }
            # Verbose listing: the first character is the member type; only
            # file (-), directory, symlink and hardlink may be extracted.
            bad="$(tar -tv "${z[@]}" -f "$f" | grep -m1 -v '^[-dlh]' || true)"
            [[ -z "$bad" ]] || { log err msg="archive contains unsafe archive member (not a file, directory or link)" member="$bad"; return 1; } ;;
        zip)
            command -v unzip >/dev/null 2>&1 || { log err msg="zip asset needs unzip"; return 1; }
            listing="$(unzip -Z1 "$f")" \
                || { log err msg="cannot list archive" file="$f"; return 1; } ;;
    esac
    if [[ -n "${listing:-}" ]]; then
        bad="$(grep -E '(^/|(^|/)\.\.(/|$))' <<<"$listing" | head -n1 || true)"
        [[ -z "$bad" ]] || { log err msg="archive contains unsafe path" path="$bad"; return 1; }
    fi
    [[ ! -e "$dir" ]] || { log err msg="extract directory already exists" dir="$dir"; return 1; }
    mkdir -p "$dir"
    local -a st=()
    (( strip > 0 )) && st=(--strip-components="$strip")
    case "$kind" in
        tgz|txz|tbz2|tzst|tar) tar -x --no-same-owner --same-permissions "${z[@]}" -f "$f" -C "$dir" "${st[@]+"${st[@]}"}" ;;
        zip)
            (( strip == 0 )) || { log err msg="STRIP_COMPONENTS is not supported for zip"; return 1; }
            unzip -q "$f" -d "$dir" ;;
        xz)   xz -dc "$f" > "$dir/$(basename "${f%.xz}")" ;;
        gz)   gzip -dc "$f" > "$dir/$(basename "${f%.gz}")" ;;
        bz2)  bzip2 -dc "$f" > "$dir/$(basename "${f%.bz2}")" ;;
        none) cp -p "$f" "$dir/" ;;
        *)    log err msg="unknown EXTRACT" value="$kind"; return 1 ;;
    esac || { rm -rf -- "$dir"; return 1; }
    # Root keeps archive modes (-p above); setuid and setgid are not wanted.
    # chmod -R does not follow symlinks inside the tree; the top is the real path.
    chmod -R u-s,g-s -- "$(readlink -f "$dir")" || { rm -rf -- "$dir"; return 1; }
    # A refused tree is removed: it may sit next to served release dirs.
    links_stay_inside "$dir" || { rm -rf -- "$dir"; return 1; }
}

# links_stay_inside DIR: refuse symlinks in the freshly extracted DIR that are
# absolute or resolve outside it. Checked on disk, not in tar's text listing,
# so odd member names cannot fool it and tar and zip get the same rule.
# Nothing was written through such a link before this check: GNU tar and
# unzip first put a placeholder file where it goes, so a later member under
# it fails with "Not a directory". Hardlinks need no check: GNU tar strips a
# leading / and .. from link targets. tests/run.sh covers all three.
links_stay_inside() {
    local l t r root
    root="$(readlink -f "$1")"
    while IFS= read -r -d '' l; do
        t="$(readlink "$l")"
        # ${l%/*}, not $(dirname): a command substitution would drop a
        # trailing newline from the directory name and resolve elsewhere.
        r="$(readlink -m "${l%/*}/$t")"
        if [[ "$t" == /* || ( "$r" != "$root" && "$r" != "$root/"* ) ]]; then
            log err msg="archive contains unsafe symlink" link="${l#"$root"/}" target="$t"
            return 1
        fi
    done < <(find "$root" -type l -print0)
}

# Keep the newest KEEP version directories; never the current or previous one.
prune_dirs() {
    local base="$1" keep_cur keep_prev d
    [[ -d "$base" ]] || return 0
    keep_cur="$VERSION"; keep_prev="$OLD_VERSION"
    local -a vers=()
    # Same version shape as the release filter: suffixed (prerelease) names
    # only with ALLOW_PRERELEASE=yes, so a hand-made 1.2.3-bak is never
    # touched otherwise. '-' sorts as '~': 1.3.0-rc1 is older than 1.3.0.
    local re='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
    [[ "$ALLOW_PRERELEASE" == yes ]] && re='^[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.]+)?$'
    mapfile -t vers < <(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | grep -E "$re" | tr '-' '~' | sort -V | tr '~' '-')
    local n=${#vers[@]} i
    for (( i = 0; i < n - KEEP; i++ )); do
        d="${vers[$i]}"
        [[ "$d" == "$keep_cur" || "$d" == "$keep_prev" ]] && continue
        log info event=pruned dir="$base/$d"
        rm -rf -- "${base:?}/$d"
    done
}
