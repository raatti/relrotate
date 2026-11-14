# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate layout adapter: TARGET is a symlink -> RELEASES_DIR/<version>/

layout_symlink_validate() {
    [[ -n "$ASSET" ]] || die 2 "$APP: ASSET is not set"
    [[ -n "$TARGET" ]] || die 2 "$APP: TARGET is not set"
    [[ -n "$VERIFY" ]] || die 2 "$APP: VERIFY is not set (use VERIFY=none to opt out explicitly)"
    [[ -n "$RELEASES_DIR" ]] || RELEASES_DIR="${TARGET}-releases"
}

layout_symlink_needs_download() { return 0; }

layout_symlink_detect() {
    [[ -L "$TARGET" ]] || return 1
    basename "$(readlink "$TARGET")"
}

layout_symlink_stage() {
    if [[ -e "$TARGET" && ! -L "$TARGET" ]]; then
        log err msg="TARGET exists and is not a symlink; move it to RELEASES_DIR/<version> and symlink it first" target="$TARGET"
        return 1
    fi
    mkdir -p "$RELEASES_DIR"
    RELEASE_DIR="$RELEASES_DIR/$VERSION"
    # After a failed rollback the new release stays live while state still
    # names the old one; restaging it would rm -rf the tree being served.
    if [[ "$(readlink -f "$TARGET")" == "$(readlink -f "$RELEASE_DIR")" ]]; then
        log err event=state-behind live="$VERSION" recorded="$OLD_VERSION"
        state_set last-result "refused: $VERSION already live, state says $OLD_VERSION"
        notify "$VERSION is already live, state says $OLD_VERSION" \
            "relrotate update $APP: $TARGET already points at $RELEASE_DIR, but the recorded version is $OLD_VERSION (an earlier rollback probably failed). Nothing was changed. Check that $VERSION works, then run: relrotate adopt $APP $VERSION"
        exit 1
    fi
    local tmp="$RELEASE_DIR.relrotate-new"
    rm -rf -- "$tmp"
    archive_is_sane "$DOWNLOAD" || return 1
    extract_to "$DOWNLOAD" "$tmp" "${STRIP_COMPONENTS:-1}" || return 1

    local pair rel src
    for pair in "${LINKS[@]+"${LINKS[@]}"}"; do
        rel="${pair%%:*}"; src="${pair#*:}"
        rm -rf -- "${tmp:?}/$rel"
        mkdir -p "$(dirname "$tmp/$rel")"
        ln -s "$src" "$tmp/$rel" || return 1
        log debug msg="linked" path="$rel" to="$src"
    done
    for pair in "${COPY[@]+"${COPY[@]}"}"; do
        rel="${pair%%:*}"; src="${pair#*:}"
        mkdir -p "$(dirname "$tmp/$rel")"
        cp -a "$src" "$tmp/$rel" || return 1
        log debug msg="copied" path="$rel" from="$src"
    done

    if [[ -n "$OWNER" ]]; then chown -R --no-dereference "$OWNER" "$tmp" || return 1; fi
    rm -rf -- "$RELEASE_DIR"
    mv -T "$tmp" "$RELEASE_DIR" || return 1
    relabel "$RELEASE_DIR"
    log info event=staged dir="$RELEASE_DIR"
}

layout_symlink_flip() { flip_symlink "$RELEASES_DIR/$VERSION"; }

layout_symlink_revert() {
    local to="$1"
    [[ -d "$RELEASES_DIR/$to" ]] || { log err msg="previous release dir missing" dir="$RELEASES_DIR/$to"; return 1; }
    flip_symlink "$RELEASES_DIR/$to"
}

layout_symlink_prune() { prune_dirs "$RELEASES_DIR"; }

flip_symlink() {
    local dest="$1"
    ln -sfn "$dest" "$TARGET.relrotate-new" || return 1
    mv -Tf "$TARGET.relrotate-new" "$TARGET" || return 1
    relabel "$TARGET"
    log info event=flipped target="$TARGET" to="$dest"
}
