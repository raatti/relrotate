# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate layout adapter: each quadlet's Image= tag is bumped. All images
# are pulled before any quadlet changes and the set is rolled back together.
# CONTAINERS=('quadlet-path|image-template' ...); QUADLET+IMAGE is the
# one-entry form.
# Before an update the digest of each image the quadlets name is recorded
# next to the quadlet backup; a rollback points the tag back at that exact
# image (a tag may have been re-pushed). PIN_DIGEST=yes writes the new
# quadlets as Image=name:tag@sha256:..., so the backup itself is exact.

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

layout_container_doctor() {
    local entry q
    for entry in "${CONTAINERS[@]}"; do
        q="${entry%%|*}"
        if [[ -w "$q" ]]; then doctor_ok "quadlet $q writable"
        else doctor_bad "quadlet $q missing or not writable"; fi
    done
}

# The images are pulled in stage; there is no asset to download.
layout_container_needs_download() { return 1; }

layout_container_sweep() { :; }

# The version is read from the first quadlet's Image= tag.
layout_container_detect() {
    local q="${CONTAINERS[0]%%|*}" img tag
    [[ -r "$q" ]] || return 1
    img="$(quadlet_image "$q")"
    tag="${img##*/}"; tag="${tag#*:}"; tag="${tag%%@*}"
    [[ -n "$tag" && "$tag" != "${img##*/}" ]] || return 1
    local v; v="$(tag_version "$tag")"   # the recipe's tag scheme, as for releases
    [[ -n "$v" ]] || return 1
    printf '%s' "$v"
}

# as_owner CMD...: run CMD as the quadlet's owner. cd somewhere the user can
# read; podman dislikes an unreadable cwd.
as_owner() { (cd / && runuser -u "$QUADLET_USER" -- "$@" 9>&-); }

podman_as_owner() {
    if [[ -n "$QUADLET_USER" ]]; then as_owner "$PODMAN" "$@"; else "$PODMAN" "$@" 9>&-; fi
}

# A rootless quadlet sits in a directory its owner can write to. Root must
# not open, create or rename anything there: the owner could have pointed
# the name at any file on the system (a symlink). So with QUADLET_USER every
# read and write of the quadlet is done by that account, and root only
# works on copies in its own state directory.

# quadlet_src Q: the file to read Q from: Q itself, or for a rootless
# quadlet a fresh copy its owner's account made.
quadlet_src() {
    [[ -n "${QUADLET_USER:-}" ]] || { printf '%s' "$1"; return 0; }
    local c; c="$(printf '%s' "$1" | sha256sum)"; c="$STATE_DIR/quadlet.read.${c:0:12}"
    if as_owner cat -- "$1" > "$c.part" 2>/dev/null && mv -f "$c.part" "$c"; then printf '%s' "$c"
    else rm -f "$c.part"; return 1; fi
}

# quadlet_put Q SRC: make SRC the content of Q. Rootless: the owner's
# account writes it, through a temporary file that starts as a copy of Q, so
# the mode stays. Rootful: a plain copy, as before.
quadlet_put() {
    if [[ -n "${QUADLET_USER:-}" ]]; then
        # shellcheck disable=SC2016  # $1 belongs to the inner shell
        as_owner bash -c 'cp -p -- "$1" "$1.relrotate-new" && cat > "$1.relrotate-new" && mv -f -- "$1.relrotate-new" "$1"' \
            bash "$1" < "$2"
    else
        cp -p "$2" "$1" && relabel "$1"
    fi
}

# CONTAINERS=('quadlet-path|image-template' ...); QUADLET+IMAGE is the one-entry form.
# The backup name carries a checksum of the full path: two quadlets with the
# same basename in different dirs must not share a backup.
container_bak() {
    local sum; sum="$(printf '%s' "$2" | sha256sum)"; sum="${sum:0:12}"
    printf '%s/quadlet.%s.%s.%s.bak' "$STATE_DIR" "$1" "$sum" "$(basename "$2")"
}
# 0.2.0 named backups without the checksum; read those as a fallback.
container_bak_legacy() { printf '%s/quadlet.%s.%s.bak' "$STATE_DIR" "$1" "$(basename "$2")"; }
# The 0.2.0 name is used only when no other quadlet in the set has the same
# basename: such a set shared one legacy backup, so it fits only one of them.
container_bak_find() {
    local b entry n=0; b="$(container_bak "$1" "$2")"
    if [[ ! -f "$b" ]]; then
        for entry in "${CONTAINERS[@]}"; do
            [[ "$(basename "${entry%%|*}")" == "$(basename "$2")" ]] && n=$((n+1))
        done
        (( n > 1 )) || b="$(container_bak_legacy "$1" "$2")"
    fi
    printf '%s' "$b"
}

# quadlet_scan FILE read|write [IMAGE]: the one parser of the Image key, as
# systemd reads it: the last Image= inside [Container] (a single-value key
# takes its last assignment), blanks allowed around the =; comments and other
# sections do not count. read prints its value (trailing blanks and a CR
# dropped: systemd ignores them). write prints FILE with that line replaced by
# Image=IMAGE and returns 1 when there is none. Both return 3 for a line
# continued with a trailing backslash, which is not supported. IMAGE goes
# through the environment, so awk reads no escape in it.
quadlet_scan() {
    local files=("$1"); [[ "$2" != write ]] || files+=("$1")   # write: find the line, then print
    MODE="$2" IMG="${3:-}" awk '
        FNR == NR {
            if ($0 ~ /^[[:space:]]*\[/) { s = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s); in_c = (s == "Container") }
            else if (in_c && match($0, /^[[:space:]]*Image[[:space:]]*=[[:space:]]*/)) {
                last = FNR; val = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", val)
                cont = (val ~ /\\$/)
            }
            next
        }
        FNR == last { print "Image=" ENVIRON["IMG"]; next }
        { print }
        END {
            if (cont) exit 3
            if (ENVIRON["MODE"] == "read") { if (last) print val }
            else if (!last) exit 1
        }
    ' "${files[@]}"
}
# A continued line reads as no image (callers then say "unknown"); the reason is logged.
quadlet_image() {
    local rc=0 src
    src="$(quadlet_src "$1")" || return 0
    quadlet_scan "$src" read || rc=$?
    (( rc != 3 )) || log err msg="a continued Image= line (trailing backslash) is not supported; put it on one line" quadlet="$1"
    return 0
}
# image_repo REF: REF without its :tag (a registry :port stays).
image_repo() {
    local last="${1##*/}"
    if [[ "$last" == *:* ]]; then printf '%s' "${1%:*}"; else printf '%s' "$1"; fi
}
image_digest() { podman_as_owner image inspect --format '{{.Digest}}' "$1" 2>/dev/null; }
digest_file() { local b; b="$(container_bak "$1" "$2")"; printf '%s.digest' "${b%.bak}"; }

# image_tag REF: the :tag of REF without a digest; nothing when it has none
# (also for name@sha256:..., where the version on disk is unknowable).
image_tag() {
    local t="${1##*/}"
    t="${t%%@*}"
    [[ "$t" == *:* ]] || return 0
    printf '%s' "${t#*:}"
}

# quadlet_on_old_version IMAGE TEMPLATE: does the quadlet's Image= still name
# OLD_VERSION? A run killed after the flip leaves the quadlet on the new
# version while installed says OLD_VERSION. True also when the template has
# no version in it (:latest: the line is the same for every version).
quadlet_on_old_version() {
    local now new t old
    now="$(image_tag "$1")"
    [[ -n "$now" ]] || return 0
    new="$(expand "$2")"
    # shellcheck disable=SC2034  # read by expand() via dynamic scope
    local VERSION TAG
    # A manual rollback rebuilds the tag as TAG_PREFIX + version (see revert).
    for t in "$(tag_for_version "$OLD_VERSION")" "$TAG_PREFIX$OLD_VERSION"; do
        [[ -n "$t" ]] || continue
        VERSION="$OLD_VERSION" TAG="$t"
        old="$(expand "$2")"
        [[ "$old" != "$new" ]] || return 0
        [[ "$(image_tag "$old")" != "$now" ]] || return 0
    done
    same_version "${now#"$TAG_PREFIX"}" "$OLD_VERSION"
}

# PINNED: the digest-pinned image per container. OLDDIG: the digest of the
# image the quadlet named before the pull ("" when unknown). PULLED: the image
# pulled so far, per container.
PINNED=() OLDDIG=() PULLED=()
layout_container_stage() {
    local entry q image d old i
    PINNED=() OLDDIG=() PULLED=()
    # Before anything is pulled or backed up: a quadlet on another version
    # than recorded would overwrite the OLD_VERSION backup with its own file.
    for entry in "${CONTAINERS[@]}"; do
        q="${entry%%|*}"
        quadlet_on_old_version "$(quadlet_image "$q")" "${entry#*|}" && continue
        local found bak; found="$(image_tag "$(quadlet_image "$q")")"; bak="$(container_bak_find "$OLD_VERSION" "$q")"
        [[ -f "$bak" ]] || bak=""
        # rollback would go to "previous", not to the recorded version: advise adopt, or a manual restore.
        log err msg="quadlet Image= tag $found is not the recorded version $OLD_VERSION (an earlier run was probably killed after the flip); if $found runs fine: relrotate adopt $APP ${found#"$TAG_PREFIX"}; to go back to $OLD_VERSION restore $q ${bak:+from $bak }(or set its Image= to $OLD_VERSION) and restart the service" quadlet="$q"
        return 1
    done
    # The image running now, by digest, unless the quadlet already pins it;
    # read before any pull, which may move a tag that does not change (latest).
    for i in "${!CONTAINERS[@]}"; do
        q="${CONTAINERS[i]%%|*}"; old="$(quadlet_image "$q")"
        OLDDIG[i]=""
        if [[ -n "$old" && "$old" != *@* ]] && d="$(image_digest "$old")" && [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            OLDDIG[i]="$d"
        else
            log debug msg="no digest recorded for the current image" quadlet="$q" image="$old"
        fi
    done
    # Pull everything first: a missing image aborts before any quadlet changes.
    for i in "${!CONTAINERS[@]}"; do
        entry="${CONTAINERS[i]}"
        q="${entry%%|*}"; image="$(expand "${entry#*|}")"
        [[ -w "$q" ]] || { log err msg="quadlet not writable" quadlet="$q"; unmove_tags; return 1; }
        log info event=pull image="$image"
        podman_as_owner pull --quiet "$image" >/dev/null || { log err msg="image pull failed" image="$image"; unmove_tags; return 1; }
        PULLED[i]="$image"
        if [[ "$PIN_DIGEST" == yes ]]; then
            d="$(image_digest "$image")"
            [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { log err msg="no digest for pulled image" image="$image"; unmove_tags; return 1; }
            PINNED[i]="${image%@*}@$d"
        fi
    done
    for i in "${!CONTAINERS[@]}"; do
        q="${CONTAINERS[i]%%|*}"
        cp -p "$(quadlet_src "$q")" "$(container_bak "$OLD_VERSION" "$q")" || { unmove_tags; return 1; }
        rm -f -- "$(digest_file "$OLD_VERSION" "$q")"
        [[ -z "${OLDDIG[i]}" ]] || printf '%s\n' "${OLDDIG[i]}" > "$(digest_file "$OLD_VERSION" "$q")" || { unmove_tags; return 1; }
    done
    # shellcheck disable=SC2034  # read by recipe hooks
    RELEASE_DIR=""
    log info event=staged containers="${#CONTAINERS[@]}"
}

layout_container_flip() { flip_containers; }

# Returns 0 done, 1 nothing changed, 2 some quadlet was put back but the
# revert is incomplete (same contract as flip).
layout_container_revert() {
    local to="$1" entry q bak rc=0 changed=0
    for entry in "${CONTAINERS[@]}"; do
        q="${entry%%|*}"; bak="$(container_bak_find "$to" "$q")"
        if [[ -f "$bak" ]]; then
            if quadlet_put "$q" "$bak"; then
                changed=1
                log info event=flipped quadlet="$q" restored="$bak"
            else
                rc=1
            fi
        else
            # No backup (e.g. manual rollback much later): rebuild the old tag.
            # A manual rollback has not fetched the release list, so fall
            # back to TAG_PREFIX + version, which is what nearly every tag is.
            # shellcheck disable=SC2034  # read by expand() via dynamic scope
            local VERSION="$to" TAG
            # shellcheck disable=SC2034
            TAG="$(tag_for_version "$to")"; TAG="${TAG:-$TAG_PREFIX$to}"
            if rewrite_image "$q" "$(expand "${entry#*|}")"; then changed=1; else rc=1; fi
        fi
        restore_image_tag "$to" "$q"
    done
    systemctl_for_app daemon-reload || rc=1
    (( rc == 0 )) && return 0
    (( changed )) && return 2
    return 1
}

# restore_image_tag VER QUADLET: point the quadlet's (unpinned) tag back at
# the image recorded for VER, pulling it by digest if it is gone. A failure
# is a warning: the quadlet then runs whatever the tag names now.
restore_image_tag() {
    local df img d; df="$(digest_file "$1" "$2")"
    [[ -s "$df" ]] || return 0
    img="$(quadlet_image "$2")"
    [[ -n "$img" && "$img" != *@* ]] || return 0
    retag_image "$img" "$(cat "$df")"
}

# retag_image IMAGE DIGEST [LEVEL]: LEVEL is how a failure is logged.
retag_image() {
    local img="$1" d="$2" level="${3:-warning}" repo; repo="$(image_repo "$1")"
    if { podman_as_owner image exists "$repo@$d" || podman_as_owner pull --quiet "$repo@$d" >/dev/null; } \
        && podman_as_owner tag "$repo@$d" "$img"; then
        log info event=retagged image="$img" digest="$d"
    else
        log "$level" msg="could not point the tag back at the recorded image" image="$img" digest="$d"
    fi
}

# unmove_tags: after a failed stage or flip, the quadlets are as they were, but
# a pull may have moved a tag that is the same for every version (:latest) to
# the new image. Point each such tag back at the digest recorded before the
# pull. Version-named and pinned images are untouched by a pull: nothing to do.
unmove_tags() {
    local i q old
    for i in "${!PULLED[@]}"; do
        q="${CONTAINERS[i]%%|*}"; old="$(quadlet_image "$q")"
        [[ -n "${OLDDIG[i]}" && "$old" == "${PULLED[i]}" ]] || continue
        # err: the outcome says "nothing changed", but this tag now names the new image.
        retag_image "$old" "${OLDDIG[i]}" err
    done
}

# Only the OLD_VERSION quadlet backups are needed (rollback goes back one
# version). Images are left for podman / the admin to prune.
layout_container_prune() {
    local f
    for f in "$STATE_DIR"/quadlet.*.bak "$STATE_DIR"/quadlet.*.digest; do
        [[ "$f" == "$STATE_DIR/quadlet.$OLD_VERSION."* ]] || rm -f -- "$f"
    done
}

# rewrite_image QUADLET IMAGE  (no daemon-reload); QUADLET is untouched on failure.
# A symlinked quadlet is edited where it points: the link stays a link.
rewrite_image() {
    local q image="$2" src tmp rc=0
    if [[ -n "${QUADLET_USER:-}" ]]; then
        # Rootless: read the owner's copy, build the new text in the state
        # directory, let the owner's account put it in place.
        q="$1"
        src="$(quadlet_src "$q")" || { log err msg="could not read the quadlet" quadlet="$q"; return 1; }
        tmp="$src.new"
    else
        q="$(readlink -f -- "$1")" || q="$1"
        src="$q"; tmp="$q.relrotate-new"
    fi
    { : > "$tmp"; } 2>/dev/null || { log err msg="could not write the quadlet" quadlet="$q"; return 1; }
    quadlet_scan "$src" write "$image" > "$tmp" || rc=$?
    case "$rc" in
        0) ;;
        1) rm -f "$tmp"; log err msg="no Image= line in the [Container] section of the quadlet" quadlet="$q"; return 1 ;;
        3) rm -f "$tmp"; log err msg="a continued Image= line (trailing backslash) is not supported; put it on one line" quadlet="$q"; return 1 ;;
        *) rm -f "$tmp"; log err msg="could not read the quadlet" quadlet="$q"; return 1 ;;
    esac
    if [[ -n "${QUADLET_USER:-}" ]]; then
        quadlet_put "$q" "$tmp" || rc=1
        rm -f "$tmp"
        (( rc == 0 )) || { log err msg="could not write the quadlet" quadlet="$q"; return 1; }
    else
        { { chown --reference="$q" "$tmp" 2>/dev/null || true; } \
            && chmod --reference="$q" "$tmp" \
            && mv -f "$tmp" "$q"; } || { rm -f "$tmp"; log err msg="could not write the quadlet" quadlet="$q"; return 1; }
        relabel "$q"
    fi
    log info event=flipped quadlet="$q" image="$image"
}

# Returns 1 if nothing changed, 2 if quadlets changed and could not be put
# back (caller must roll back).
flip_containers() {
    local entry i
    for i in "${!CONTAINERS[@]}"; do
        entry="${CONTAINERS[i]}"
        if ! rewrite_image "${entry%%|*}" "${PINNED[i]:-$(expand "${entry#*|}")}"; then
            undo_flip; return
        fi
    done
    systemctl_for_app daemon-reload && return 0
    log err msg="daemon-reload failed, restoring previous quadlets"
    undo_flip
}

# restore_quadlets, then, when that worked (nothing changed), the moved tags.
undo_flip() {
    local rc=0
    restore_quadlets || rc=$?
    (( rc != 1 )) || unmove_tags
    return "$rc"
}

# Put every quadlet back from the OLD_VERSION backup made in stage.
# Returns 1 when that worked (nothing changed), 2 when it did not.
restore_quadlets() {
    local entry q
    for entry in "${CONTAINERS[@]}"; do
        q="${entry%%|*}"
        if ! quadlet_put "$q" "$(container_bak_find "$OLD_VERSION" "$q")"; then
            log err msg="could not restore quadlet" quadlet="$q"; return 2
        fi
    done
    if ! systemctl_for_app daemon-reload; then
        log err msg="daemon-reload failed after restoring quadlets"; return 2
    fi
    return 1
}
