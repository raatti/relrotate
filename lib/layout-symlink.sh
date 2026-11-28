# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate layout adapter: TARGET is a symlink -> RELEASES_DIR/<version>/

layout_symlink_validate() {
    [[ -n "$ASSET" ]] || die 2 "$APP: ASSET is not set"
    [[ -n "$TARGET" ]] || die 2 "$APP: TARGET is not set"
    verify_validate
    [[ -n "$RELEASES_DIR" ]] || RELEASES_DIR="${TARGET}-releases"
}

layout_symlink_needs_download() { return 0; }

# Half-extracted releases of a run that was killed.
layout_symlink_sweep() {
    [[ -d "$RELEASES_DIR" ]] || return 0
    find "$RELEASES_DIR/" -maxdepth 1 -name '*.relrotate-new' -exec rm -rf -- {} + || true
}

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
    # State behind the live release (a failed rollback on 0.2.0, a crash, a
    # hand fix): restaging it would rm -rf the tree being served.
    if [[ "$(readlink -f "$TARGET")" == "$(readlink -f "$RELEASE_DIR")" ]]; then
        return 3   # already live: the transaction records it (see layout.sh)
    fi
    local tmp="$RELEASE_DIR.relrotate-new"
    rm -rf -- "$tmp"
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

layout_symlink_doctor() { doctor_target_dir; }

# maintenance_page_up: point TARGET at RELEASES_DIR/.maintenance, a page
# saying a manual update is needed (ON_SECURITY_FAILURE=maintenance, #131).
# Not a version name, so prune never touches it.
maintenance_page_up() {
    local dir="$RELEASES_DIR/.maintenance"
    mkdir -p "$dir" || return 1
    cat > "$dir/index.html" <<'EOF' || return 1
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Down for maintenance</title></head>
<body><h1>Down for maintenance</h1>
<p>A security update needs manual attention. This service is back as soon as
an administrator has finished it.</p></body></html>
EOF
    chmod 0755 "$dir" && chmod 0644 "$dir/index.html" || return 1
    if [[ -n "$OWNER" ]]; then chown -R --no-dereference "$OWNER" "$dir" || return 1; fi
    relabel "$dir"
    flip_symlink "$dir"
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
