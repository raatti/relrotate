# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate layout adapter: TARGET is a single executable; every installed
# version is kept under STATE_DIR/bin/<version>/.

layout_binary_validate() {
    [[ -n "$ASSET" ]] || die 2 "$APP: ASSET is not set"
    [[ -n "$TARGET" ]] || die 2 "$APP: TARGET is not set"
    [[ -n "$VERIFY" ]] || die 2 "$APP: VERIFY is not set (use VERIFY=none to opt out explicitly)"
}

layout_binary_needs_download() { return 0; }

# A bare binary does not say its version; recipes use current_version().
layout_binary_detect() { return 1; }

bin_store() { printf '%s/bin/%s/%s' "$STATE_DIR" "$1" "$(basename "$TARGET")"; }

layout_binary_stage() {
    local x="$WORK/extract" member store
    archive_is_sane "$DOWNLOAD" || return 1
    extract_to "$DOWNLOAD" "$x" "${STRIP_COMPONENTS:-0}" || return 1
    if [[ -n "$ARCHIVE_MEMBER" ]]; then
        member="$x/$(expand "$ARCHIVE_MEMBER")"
    else
        local -a files=()
        mapfile -t files < <(find "$x" -type f)
        (( ${#files[@]} == 1 )) || { log err msg="archive has ${#files[@]} files; set ARCHIVE_MEMBER"; return 1; }
        member="${files[0]}"
    fi
    [[ -f "$member" ]] || { log err msg="binary not found in download" member="$member"; return 1; }

    store="$(bin_store "$VERSION")"
    mkdir -p "$(dirname "$store")"
    install -m "$MODE" "$member" "$store" || return 1

    # First run: keep the binary that is installed now, so rollback has
    # something to go back to.
    local prev; prev="$(bin_store "$OLD_VERSION")"
    if [[ -f "$TARGET" && ! -f "$prev" ]]; then
        mkdir -p "$(dirname "$prev")"
        cp -p "$TARGET" "$prev" || return 1
        log info event=kept-current version="$OLD_VERSION" path="$prev"
    fi
    # shellcheck disable=SC2034  # read by recipe hooks
    RELEASE_DIR="$(dirname "$store")"
    log info event=staged binary="$store"
}

layout_binary_flip() { flip_binary "$VERSION"; }
layout_binary_revert() { flip_binary "$1"; }
layout_binary_prune() { prune_dirs "$STATE_DIR/bin"; }

flip_binary() {
    local ver="$1" store
    store="$(bin_store "$ver")"
    [[ -f "$store" ]] || { log err msg="stored binary missing" path="$store"; return 1; }
    install -m "$MODE" "$store" "$TARGET.relrotate-new" || return 1
    if [[ -n "$OWNER" ]]; then chown "$OWNER" "$TARGET.relrotate-new" || return 1; fi
    relabel "$TARGET.relrotate-new"
    mv -f "$TARGET.relrotate-new" "$TARGET" || return 1
    relabel "$TARGET"
    log info event=flipped target="$TARGET" version="$ver"
}
