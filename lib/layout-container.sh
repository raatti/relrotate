# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate layout adapter: each quadlet's Image= tag is bumped. All images
# are pulled before any quadlet changes and the set is rolled back together.
# CONTAINERS=('quadlet-path|image-template' ...); QUADLET+IMAGE is the
# one-entry form.

layout_container_validate() {
    if (( ${#CONTAINERS[@]} == 0 )); then
        [[ -n "$QUADLET" && -n "$IMAGE" ]] || die 2 "$APP: container layout needs QUADLET+IMAGE or CONTAINERS=()"
        CONTAINERS=("$QUADLET|$IMAGE")
    fi
    local entry
    for entry in "${CONTAINERS[@]}"; do
        [[ "$entry" == *"|"* ]] || die 2 "$APP: CONTAINERS entries must be 'quadlet-path|image-template'"
    done
}

# The images are pulled in stage; there is no asset to download.
layout_container_needs_download() { return 1; }

# The version is read from the first quadlet's Image= tag.
layout_container_detect() {
    local q="${CONTAINERS[0]%%|*}" img tag
    [[ -r "$q" ]] || return 1
    img="$(sed -n 's/^Image=[[:space:]]*//p' "$q" | head -n1)"
    tag="${img##*/}"; tag="${tag#*:}"; tag="${tag%%@*}"
    [[ -n "$tag" && "$tag" != "${img##*/}" ]] || return 1
    printf '%s' "${tag#"$TAG_PREFIX"}"
}

podman_as_owner() {
    if [[ -n "$QUADLET_USER" ]]; then
        # cd somewhere the user can read; podman dislikes an unreadable cwd
        (cd / && runuser -u "$QUADLET_USER" -- "$PODMAN" "$@")
    else
        "$PODMAN" "$@"
    fi
}

# CONTAINERS=('quadlet-path|image-template' ...); QUADLET+IMAGE is the one-entry form.
container_bak() { printf '%s/quadlet.%s.%s.bak' "$STATE_DIR" "$1" "$(basename "$2")"; }

layout_container_stage() {
    local entry q image
    # Pull everything first: a missing image aborts before any quadlet changes.
    for entry in "${CONTAINERS[@]}"; do
        q="${entry%%|*}"; image="$(expand "${entry#*|}")"
        [[ -w "$q" ]] || { log err msg="quadlet not writable" quadlet="$q"; return 1; }
        log info event=pull image="$image"
        podman_as_owner pull --quiet "$image" >/dev/null || { log err msg="image pull failed" image="$image"; return 1; }
    done
    for entry in "${CONTAINERS[@]}"; do
        q="${entry%%|*}"
        cp -p "$q" "$(container_bak "$OLD_VERSION" "$q")" || return 1
    done
    # shellcheck disable=SC2034  # read by recipe hooks
    RELEASE_DIR=""
    log info event=staged containers="${#CONTAINERS[@]}"
}

layout_container_flip() { flip_containers; }

layout_container_revert() {
    local to="$1" entry q bak rc=0
    for entry in "${CONTAINERS[@]}"; do
        q="${entry%%|*}"; bak="$(container_bak "$to" "$q")"
        if [[ -f "$bak" ]]; then
            cp -p "$bak" "$q" || rc=1
            relabel "$q"
            log info event=flipped quadlet="$q" restored="$bak"
        else
            # No backup (e.g. manual rollback much later): rebuild the old tag.
            # A manual rollback has not fetched the release list, so fall
            # back to TAG_PREFIX + version, which is what nearly every tag is.
            # shellcheck disable=SC2034  # read by expand() via dynamic scope
            local VERSION="$to" TAG
            # shellcheck disable=SC2034
            TAG="$(tag_for_version "$to")"; TAG="${TAG:-$TAG_PREFIX$to}"
            rewrite_image "$q" "$(expand "${entry#*|}")" || rc=1
        fi
    done
    systemctl_for_app daemon-reload || rc=1
    return "$rc"
}

# Only the OLD_VERSION quadlet backups are needed (rollback goes back one
# version). Images are left for podman / the admin to prune.
layout_container_prune() {
    local f
    for f in "$STATE_DIR"/quadlet.*.bak; do
        [[ "$f" == "$STATE_DIR/quadlet.$OLD_VERSION."* ]] || rm -f -- "$f"
    done
}

# rewrite_image QUADLET IMAGE  (no daemon-reload); QUADLET is untouched on failure.
rewrite_image() {
    local q="$1" image="$2" tmp="$1.relrotate-new"
    grep -q '^Image=' "$q" || { log err msg="no Image= line in quadlet" quadlet="$q"; return 1; }
    { sed "s|^Image=.*|Image=$image|" "$q" > "$tmp" \
        && { chown --reference="$q" "$tmp" 2>/dev/null || true; } \
        && chmod --reference="$q" "$tmp" \
        && mv -f "$tmp" "$q"; } || { rm -f "$tmp"; return 1; }
    relabel "$q"
    log info event=flipped quadlet="$q" image="$image"
}

# Returns 1 if nothing changed, 2 if quadlets changed and could not be put
# back (caller must roll back).
flip_containers() {
    local entry
    for entry in "${CONTAINERS[@]}"; do
        if ! rewrite_image "${entry%%|*}" "$(expand "${entry#*|}")"; then
            restore_quadlets; return
        fi
    done
    systemctl_for_app daemon-reload && return 0
    log err msg="daemon-reload failed, restoring previous quadlets"
    restore_quadlets
}

# Put every quadlet back from the OLD_VERSION backup made in stage.
# Returns 1 when that worked (nothing changed), 2 when it did not.
restore_quadlets() {
    local entry q
    for entry in "${CONTAINERS[@]}"; do
        q="${entry%%|*}"
        if ! cp -p "$(container_bak "$OLD_VERSION" "$q")" "$q"; then
            log err msg="could not restore quadlet" quadlet="$q"; return 2
        fi
        relabel "$q"
    done
    if ! systemctl_for_app daemon-reload; then
        log err msg="daemon-reload failed after restoring quadlets"; return 2
    fi
    return 1
}
