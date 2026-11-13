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
#   detect          print the installed version if the layout can tell
#   stage           make VERSION ready to flip to; nothing live changes
#   flip            make VERSION live. 0 = done, 1 = nothing changed,
#                   2 = changed and could not be undone (caller rolls back)
#   revert VER      make VER (already staged once) live again
#   prune           drop old versions beyond KEEP
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

relabel() {
    selinux_on || return 0
    command -v restorecon >/dev/null 2>&1 || return 0
    restorecon -R "$@" 2>/dev/null || log warning msg="restorecon failed" path="$*"
}

# extract_to ARCHIVE DIR STRIP
extract_to() {
    local f="$1" dir="$2" strip="$3" kind="$EXTRACT"
    mkdir -p "$dir"
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
    local -a st=()
    (( strip > 0 )) && st=(--strip-components="$strip")
    case "$kind" in
        tgz)  tar -xzf "$f" -C "$dir" "${st[@]+"${st[@]}"}" ;;
        txz)  tar -xJf "$f" -C "$dir" "${st[@]+"${st[@]}"}" ;;
        tbz2) tar -xjf "$f" -C "$dir" "${st[@]+"${st[@]}"}" ;;
        tzst) tar --zstd -xf "$f" -C "$dir" "${st[@]+"${st[@]}"}" ;;
        tar)  tar -xf "$f" -C "$dir" "${st[@]+"${st[@]}"}" ;;
        zip)
            command -v unzip >/dev/null 2>&1 || { log err msg="zip asset needs unzip"; return 1; }
            (( strip == 0 )) || { log err msg="STRIP_COMPONENTS is not supported for zip"; return 1; }
            unzip -q "$f" -d "$dir" ;;
        xz)   xz -dc "$f" > "$dir/$(basename "${f%.xz}")" ;;
        gz)   gzip -dc "$f" > "$dir/$(basename "${f%.gz}")" ;;
        bz2)  bzip2 -dc "$f" > "$dir/$(basename "${f%.bz2}")" ;;
        none) cp -p "$f" "$dir/" ;;
        *)    log err msg="unknown EXTRACT" value="$kind"; return 1 ;;
    esac
}

# Refuse archives that try to escape (absolute paths, ..) before extracting.
archive_is_sane() {
    local f="$1" bad
    case "$f" in
        *.tar*|*.tgz|*.txz|*.tbz2)
            bad="$(tar -tf "$f" 2>/dev/null | grep -E '(^/|(^|/)\.\.(/|$))' | head -n1 || true)"
            [[ -z "$bad" ]] || { log err msg="archive contains unsafe path" path="$bad"; return 1; }
            ;;
    esac
}

# Keep the newest KEEP version directories; never the current or previous one.
prune_dirs() {
    local base="$1" keep_cur keep_prev d
    [[ -d "$base" ]] || return 0
    keep_cur="$VERSION"; keep_prev="$OLD_VERSION"
    local -a vers=()
    mapfile -t vers < <(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V)
    local n=${#vers[@]} i
    for (( i = 0; i < n - KEEP; i++ )); do
        d="${vers[$i]}"
        [[ "$d" == "$keep_cur" || "$d" == "$keep_prev" ]] && continue
        log info event=pruned dir="$base/$d"
        rm -rf -- "${base:?}/$d"
    done
}
