# shellcheck shell=bash
# shellcheck disable=SC2153,SC2034,SC2016  # recipe variables; templates are literal
# relrotate adopt <app> without a version: take over an install that is
# already there. With a recipe it reads and records the installed version.
# Without one it writes the recipe, from the shipped example or --source,
# and fills in what the host shows: a quadlet, the unit's ExecStart, paths.
# Only the recipe and relrotate's own state are written; old updaters are
# listed, never touched.

# Where to look (space-separated, globs allowed; overridable for tests).
ADOPT_QUADLET_DIRS="${RELROTATE_QUADLET_DIRS:-/etc/containers/systemd /root/.config/containers/systemd /home/*/.config/containers/systemd}"
ADOPT_UPDATER_DIRS="${RELROTATE_UPDATER_DIRS:-/etc/systemd/system /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly}"

# file_set FILE KEY VALUE: replace the first KEY= line of FILE, or add one.
# Written in place, so owner and mode stay.
file_set() {
    local new
    new="$(awk -v k="$2=" -v v="$3" 'index($0, k) == 1 && !done { print k v; done = 1; next } { print }
        END { if (!done) print k v }' "$1")" || return 1
    printf '%s\n' "$new" > "$1"
}

# A recipe is sourced as root: a value read from the host goes in only when
# it is made of plain characters, and then single-quoted.
adopt_plain() { [[ "$1" =~ ^[A-Za-z0-9._/:@+-]+$ ]]; }
adopt_set() {   # FILE KEY VALUE
    local plain="$3" t
    for t in '${TAG}' '${VERSION}' '${ARCH}'; do plain="${plain//"$t"/x}"; done   # our own templates
    adopt_plain "$plain" || { rm -f -- "$1"; die 2 "$APP: unusual characters in $2 ($3); write the recipe by hand"; }
    file_set "$1" "$2" "'$3'" || die 1 "cannot write $1"
}

# The app's quadlet: a regular file (no symlink) that belongs to the owner
# of its directory, so nobody else can plant one.
adopt_find_quadlet() {
    local d f
    # shellcheck disable=SC2086  # a list of globs
    for d in $ADOPT_QUADLET_DIRS; do
        f="$d/$APP.container"
        [[ -f "$f" && ! -L "$f" && "$(stat -c %u "$f")" == "$(stat -c %u "$d")" ]] && { printf '%s' "$f"; return 0; }
    done
    return 0
}

# The program the app's unit starts: the last ExecStart=, without its
# prefix characters. Nothing when there is no such unit, or when it starts a
# system program (podman, java, sh, env: a wrapper, not the app itself; a
# packaged binary is not relrotate's to replace either).
adopt_unit_exec() {
    local exe
    exe="$("$SYSTEMCTL" cat "$APP.service" 2>/dev/null \
        | sed -n 's/^ExecStart=[-@:+!]*\([^[:space:]]*\).*/\1/p' | tail -n1 || true)"
    [[ "$exe" == /* ]] || return 0
    if [[ "$(readlink -f "$exe")" =~ ^/(usr/)?(s?bin|lib[0-9]*|libexec)/ ]]; then
        echo "$APP: $APP.service starts $exe, a system program: not taken as the app" >&2
        return 0
    fi
    printf '%s' "$exe"
}

# adopt_symlinked_dir PATH: the nearest directory above PATH that is a
# symlink to a directory named like a version (/opt/app/current ->
# releases/1.2.3): a release link. Other symlinks on the way (/bin, /opt on
# another disk) are not; nothing when there is none.
adopt_symlinked_dir() {
    local p="$1"
    while [[ "$p" == /*/* ]]; do
        p="${p%/*}"
        if [[ -L "$p" && -d "$p" ]]; then
            ! clean_version "$(basename "$(readlink "$p")")" >/dev/null || printf '%s' "$p"
            return 0
        fi
    done
}

# The image template for a quadlet's Image= value: the tag becomes ${TAG}
# (v1.2.3) or ${VERSION} (1.2.3); any other tag (latest) is left for the admin.
adopt_image_template() {
    local img="${1%%@*}" tag repo   # a digest is not part of the template
    tag="$(image_tag "$img")"; repo="$(image_repo "$img")"
    if [[ "$tag" =~ ^v[0-9]+(\.[0-9]+){1,2}$ ]]; then printf '%s:${TAG}' "$repo"
    elif [[ "$tag" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then printf '%s:${VERSION}' "$repo"
    else
        echo "$APP: the image tag '${tag:-none}' is not a plain version; IMAGE is written as $repo:\${TAG}: check it in the recipe" >&2
        printf '%s:${TAG}' "$repo"
    fi
}

# adopt_guess_asset FILE: for a recipe without an example, find the one
# release file that fits this host and write ASSET (and VERIFY, when the API
# gives a digest). Otherwise the candidates go into a comment.
adopt_guess_asset() {
    local file="$1" out names newest arch_re pick="" digest n arch
    arch="$(detect_arch)"
    case "$arch" in
        amd64) arch_re='amd64|x86_64|x64' ;;
        arm64) arch_re='arm64|aarch64' ;;
        *)     arch_re="$arch" ;;
    esac
    # fetch_releases exits on failure: a subshell keeps adopt alive.
    out="$( SOURCE="$SOURCE_OPT"; TAG_PREFIX=v VERSION_REGEX="" ALLOW_PRERELEASE=no
            fetch_releases >/dev/null 2>&1 || exit 1
            newest="$(newest_version)"; [[ -n "$newest" ]] || exit 1
            printf '%s\n' "$newest"
            jq -r --arg v "$newest" '.[] | select(.version == $v) | .assets[]
                | "\(.name) \(if (.digest // "") | startswith("sha256:") then "digest" else "-" end)"' <<<"$RELEASES" )" \
        || { printf '# ASSET: the release list could not be read; fill it in (README: Recipe reference).\n' >> "$file"; return 0; }
    newest="${out%%$'\n'*}"
    names="$(tail -n +2 <<<"$out" | grep -Ei "(^|[^a-z0-9])($arch_re)([^a-z0-9]|\$)" \
        | grep -Eiv '\.(sha256|sha512|sha256sum|sig|asc|pem|txt|json|deb|rpm|apk|msi|exe|dmg|pkg)( |$)|windows|darwin|macos|freebsd|openbsd|netbsd' || true)"
    n="$(grep -c . <<<"$names" || true)"
    if (( n > 1 )) && [[ "$(grep -ci linux <<<"$names")" == 1 ]]; then names="$(grep -i linux <<<"$names")"; n=1; fi
    if (( n == 1 )); then
        pick="${names% *}"; digest="${names##* }"
        pick="${pick//"$newest"/'${VERSION}'}"
        pick="${pick//"$arch"/'${ARCH}'}"
        adopt_set "$file" ASSET "$pick"
        if [[ "$digest" == digest ]]; then file_set "$file" VERIFY '"api-digest"'
        else printf '# VERIFY: the API gives no digest for this file; choose a method (README: Recipe reference).\n' >> "$file"; fi
    else
        # shellcheck disable=SC2016  # ${VERSION} is literal text for the admin
        { printf '# ASSET: %s release files fit this host; set ASSET to one of them, with ${VERSION} for %s:\n' "$n" "$newest"
          tail -n +2 <<<"$out" | sed 's/ [^ ]*$//; s/^/#   /'
        } >> "$file"
    fi
}

# adopt_write_recipe FILE: build the recipe. Dies, leaving nothing, when
# there is not enough to go on.
adopt_write_recipe() {
    local recipe="$1" new="$1.new" ex="$EXAMPLES_DIR/$APP.conf" from_example=0 q exe link img
    rm -f -- "$new"
    if [[ "$APP" == relrotate ]]; then
        # Its recipe depends on how relrotate was installed, as in setup.
        self_example >&2 || die 2 "relrotate: no recipe for this kind of install; write $recipe by hand"
        write_self_recipe "$new"
        from_example=1
        [[ -z "$SOURCE_OPT" ]] || file_set "$new" SOURCE "$SOURCE_OPT"
        echo "$APP: recipe starts from the shipped example ${SELF_EXAMPLE##*/}"
    elif [[ -n "$EXAMPLES_DIR" && -r "$ex" ]]; then
        cp -- "$ex" "$new" || die 1 "cannot write $new"
        from_example=1
        [[ -z "$SOURCE_OPT" ]] || file_set "$new" SOURCE "$SOURCE_OPT"
        echo "$APP: recipe starts from the shipped example"
    elif [[ -n "$SOURCE_OPT" ]]; then
        printf '%s\n' '# shellcheck shell=bash disable=SC2034,SC2016,SC2153' \
            "# $APP: written by 'relrotate adopt' on $(date +%F) from what the host showed. Check every line." \
            "SOURCE=$SOURCE_OPT" 'POLICY="minor"' > "$new" || die 1 "cannot write $new"
    else
        die 2 "$APP: no shipped example for it; say where its releases are: relrotate adopt --source github:owner/repo $APP"
    fi
    chmod 0640 "$new"

    q="$(adopt_find_quadlet)"
    exe=""
    # A quadlet in /etc decides. Otherwise the app's own unit goes first: a
    # quadlet in somebody's home must not take over an app that has one.
    if [[ "$q" != /etc/* ]]; then
        exe="$(adopt_unit_exec)"
        if [[ -n "$exe" && -n "$q" ]]; then echo "$APP: $q ignored: $APP.service starts $exe"; q=""; fi
    fi
    if [[ -n "$q" ]]; then
        echo "$APP: found quadlet $q"
        file_set "$new" LAYOUT container
        adopt_set "$new" QUADLET "$q"
        # A quadlet outside the system directory belongs to its owner.
        if [[ "$q" != /etc/* && "$(stat -c %u "$q")" != 0 ]]; then adopt_set "$new" QUADLET_USER "$(stat -c %U "$q")"; fi
        if ! grep -q '^IMAGE=' "$new"; then
            img="$(quadlet_image "$q")"
            [[ -n "$img" ]] || { rm -f -- "$new"; die 2 "$APP: no Image= line in $q"; }
            adopt_set "$new" IMAGE "$(adopt_image_template "$img")"
        fi
        adopt_set "$new" SERVICE "$APP.service"
    elif [[ -n "$exe" ]]; then
        echo "$APP: found $APP.service, which starts $exe"
        link="$(adopt_symlinked_dir "$exe")"
        if [[ -n "$link" ]]; then
            file_set "$new" LAYOUT symlink
            adopt_set "$new" TARGET "$link"
            adopt_set "$new" RELEASES_DIR "$(dirname "$(readlink -f "$link")")"
        else
            file_set "$new" LAYOUT binary
            adopt_set "$new" TARGET "$exe"
            [[ ! -L "$exe" ]] || echo "$APP: $exe is a symlink to $(readlink -f "$exe"): an update replaces the link with the new binary; check TARGET"
        fi
        adopt_set "$new" SERVICE "$APP.service"
        (( from_example )) || adopt_guess_asset "$new"
    elif (( from_example )); then
        echo "$APP: found no quadlet and no $APP.service; the example's paths are kept, check them"
    else
        rm -f -- "$new"
        die 2 "$APP: found no quadlet ($APP.container) and no $APP.service; write the recipe by hand (README: Recipe reference)"
    fi
    mv -f -- "$new" "$recipe" || die 1 "cannot write $recipe"
    echo "$APP: wrote $recipe"
}

# Timers, services and cron files that look like an updater for this app.
adopt_old_updaters() {
    local d f name q
    # shellcheck disable=SC2086  # a list of globs
    for d in $ADOPT_UPDATER_DIRS; do
        for f in "$d"/*; do
            [[ -f "$f" ]] || continue
            name="${f##*/}"
            [[ "$name" != relrotate* && "$name" != "$APP.service" ]] || continue
            case "$d" in
                *systemd*)
                    [[ "${name,,}" == *"${APP,,}"* ]] || continue
                    case "${name,,}" in
                        *.timer) echo "  old updater? $f   turn off: systemctl disable --now $name" ;;
                        *update*.service|*upgrade*.service) echo "  old updater? $f" ;;
                    esac ;;
                *)  ! grep -qiF -- "$APP" "$f" || echo "  old updater? $f mentions $APP: remove its line" ;;
            esac
        done
    done
    q="$(adopt_find_quadlet)"
    if [[ -n "$q" ]] && grep -q '^AutoUpdate=' "$q"; then
        echo "  old updater? $q sets AutoUpdate=: remove that line, podman would update the image too"
    fi
}

adopt_takeover() {
    APP="$1"
    valid_app_name "$APP" || die 2 "invalid app name: $APP"
    local recipe="$CONF_DIR/apps.d/$APP.conf" err ver rc=0
    if [[ -e "$recipe" ]]; then
        [[ -z "$SOURCE_OPT" ]] || die 2 "$APP: $recipe exists; --source is for writing a new recipe"
    else
        adopt_write_recipe "$recipe"
    fi
    # A recipe that still lacks something (ASSET, VERIFY) is a finding, not a crash.
    if ! err="$( (load_recipe "$APP") 2>&1 >/dev/null)"; then
        echo "$APP: the recipe is not complete yet: ${err##*msg=}"
        echo "$APP: edit $recipe, then run again: relrotate adopt $APP"
        exit 1
    fi
    load_recipe "$APP"
    acquire_lock

    echo "$APP: looking for old updaters"
    adopt_old_updaters
    ! grep -Eq '^#[[:space:]]*pre_update\(\).*backup_' "$recipe" \
        || echo "$APP: no backup is taken before an update; the recipe holds a backup hook, commented out"

    ver="$(installed_version)" || rc=$?
    if (( rc )) || [[ -z "$ver" ]]; then
        if [[ "$LAYOUT" == symlink && -d "$TARGET" && ! -L "$TARGET" ]]; then
            cat <<EOF
$APP: $TARGET is a plain directory. The symlink layout keeps each version
under $RELEASES_DIR and makes $TARGET a link to the live one. With
<version> being what is installed now, stop the service and run:
  mkdir -p $RELEASES_DIR
  mv $TARGET $RELEASES_DIR/<version>
  ln -s $RELEASES_DIR/<version> $TARGET
  relrotate adopt $APP
EOF
        else
            echo "$APP: could not read the installed version"
            [[ "$LAYOUT" != container ]] || echo "$APP: the quadlet's Image= must carry a version tag (not latest): put the running version there and check IMAGE in $recipe"
            echo "$APP: record it by hand: relrotate adopt $APP <version>"
        fi
        exit 2
    fi
    if ! state_has installed; then
        adopt_record "$ver"
        echo "$APP: recorded installed version $ver"
    else
        echo "$APP: installed version $ver (already recorded)"
        # A version read from the host does not vouch for files a partial
        # rollback may have mixed, or for a live version that fails its health
        # check: those marks stay, and only the explicit form clears them.
        if state_has incomplete; then
            echo "$APP: updates are blocked by an incomplete rollback: relrotate rollback $APP, or once the files are checked: relrotate adopt $APP $ver"
        elif state_has maintenance; then
            echo "$APP: the maintenance page is up for $(state_get maintenance); the next update retries it, or: relrotate rollback $APP"
        elif state_has unhealthy; then
            echo "$APP: $ver is marked unhealthy and checked again on every run; once it is fixed: relrotate adopt $APP $ver"
        elif [[ "$(state_get last-result)" == failed* ]]; then
            # Host and state agree and nothing is marked: the failure is history.
            state_clear failed-notified
            state_set last-result "adopted $ver ($(date -Is))"
            echo "$APP: the earlier failed result is replaced"
        fi
    fi

    echo "$APP: checks (relrotate doctor $APP)"
    DOCTOR_TOKENS=""
    ( doctor_app "$APP" ) || true
    cat <<EOF
$APP: next
  relrotate update --dry-run $APP    # pull or download and verify, change nothing
  relrotate enable $APP              # turn on the timer
EOF
}
