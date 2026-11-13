# shellcheck shell=bash
# relrotate: release sources (GitHub, Gitea/Forgejo/Codeberg).
#
# SOURCE=github:owner/repo
# SOURCE=gitea:https://codeberg.org/owner/repo     (Gitea, Forgejo, Codeberg)
#
# Releases are normalised to:
#   [{tag, version, prerelease, assets: [{name, url, digest}]}]  newest first

RELEASES="[]"
# A plain, non-browser User-Agent. Bot shields such as Anubis (used by
# code.forgejo.org) challenge browser-like agents but let API clients through.
USER_AGENT="relrotate/${RELROTATE_VERSION:-dev} (+https://github.com/raatti/relrotate)"

# api_get URL TOKEN_FILE SCHEME [curl args...]
# The token reaches curl on stdin (--config -), never on its command line,
# where any local user could read it in ps.
api_get() {
    local url="$1" file="$2" scheme="$3" auth=""; shift 3
    if [[ -n "$file" && -r "$file" ]]; then
        auth="header = \"Authorization: $scheme $(tr -d '[:space:]' < "$file")\""
    fi
    "$CURL" -fsSL --retry 3 --retry-delay 5 --max-time 60 -A "$USER_AGENT" \
        -H 'Accept: application/json' "${CURL_OPTS[@]+"${CURL_OPTS[@]}"}" \
        --config - "$@" "$url" <<<"$auth"
}

fetch_releases() {
    local raw kind="${SOURCE%%:*}" spec="${SOURCE#*:}"
    case "$kind" in
        github)
            [[ "$spec" =~ ^[^/]+/[^/]+$ ]] || die 2 "$APP: SOURCE must be github:owner/repo"
            raw="$(api_get "https://api.github.com/repos/$spec/releases?per_page=30" \
                "$GITHUB_TOKEN_FILE" Bearer -H 'X-GitHub-Api-Version: 2022-11-28')" \
                || die 1 "$APP: GitHub API request failed for $spec"
            ;;
        gitea|forgejo)
            [[ "$spec" =~ ^https?://[^/]+/[^/]+/[^/]+$ ]] \
                || die 2 "$APP: SOURCE must be gitea:https://host/owner/repo"
            local host="${spec%/*/*}" path="${spec#"${spec%/*/*}"/}"
            raw="$(api_get "$host/api/v1/repos/$path/releases?limit=30" "$GITEA_TOKEN_FILE" token)" \
                || die 1 "$APP: release API request failed for $spec"
            ;;
        *) die 2 "$APP: unknown SOURCE type '$kind' (github|gitea)" ;;
    esac

    RELEASES="$(jq -c --arg prefix "$TAG_PREFIX" --arg re "$VERSION_REGEX" \
        --arg pre "$ALLOW_PRERELEASE" '
        [ .[]
          | select(.draft != true)
          | select($pre == "yes" or .prerelease != true)
          | (.tag_name) as $tag
          | ( if $re != "" then ($tag | capture($re).v? // empty)
              else ($tag | ltrimstr($prefix)) end ) as $v
          | select($v | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"))
          | { tag: $tag, version: $v, prerelease: (.prerelease // false),
              tarball: (.tarball_url // null),
              assets: [ (.assets // [])[]
                        | { name, url: .browser_download_url, digest: (.digest // null) } ] }
        ]' <<<"$raw")" || die 1 "$APP: could not parse release list"
    log debug msg="releases parsed" count="$(jq length <<<"$RELEASES")"
}

all_versions() {
    jq -r '.[].version' <<<"$RELEASES" | sort -V
}

newest_version() {
    all_versions | tail -n1
}

tag_for_version() {
    jq -r --arg v "$1" 'first(.[] | select(.version == $v) | .tag)' <<<"$RELEASES"
}

# Highest version newer than CURRENT that POLICY allows and is not skipped.
pick_candidate() {
    local cur="$1" v best="" skip=""
    [[ -s "$STATE_DIR/skip" ]] && skip="$(cat "$STATE_DIR/skip")"
    [[ -z "$cur" ]] && return 0
    while read -r v; do
        [[ -n "$v" ]] || continue
        version_gt "$v" "$cur" || continue
        allowed_by_policy "$cur" "$v" || continue
        [[ "$v" == "$skip" ]] && continue
        best="$v"
    done < <(all_versions)
    printf '%s' "$best"
}

# A newer release than the skipped one clears the skip marker. Update only:
# check must not change state.
clear_stale_skip() {
    local cand="$1" skip=""
    [[ -s "$STATE_DIR/skip" ]] && skip="$(cat "$STATE_DIR/skip")"
    if [[ -n "$skip" && -n "$cand" ]] && version_gt "$cand" "$skip"; then
        rm -f "$STATE_DIR/skip"
    fi
}

# Mail once per out-of-policy release (usually a major bump).
check_major_available() {
    local cur="$1" newest
    newest="$(newest_version)"
    [[ -n "$newest" ]] || return 0
    version_gt "$newest" "$cur" || return 0
    allowed_by_policy "$cur" "$newest" && return 0
    [[ "$MAJOR_ACTION" == mail ]] || return 0
    local seen=""
    [[ -s "$STATE_DIR/notified" ]] && seen="$(cat "$STATE_DIR/notified")"
    [[ "$seen" == "$newest" ]] && return 0
    log info event=out-of-policy-release version="$newest" installed="$cur" policy="$POLICY"
    notify "$newest available (outside policy=$POLICY)" \
        "$APP $newest is out; $cur is installed. relrotate will not install it because POLICY=$POLICY. Read the release notes, then upgrade by hand or raise POLICY in $CONF_DIR/apps.d/$APP.conf."
    state_set notified "$newest"
}

# asset_field NAME FIELD  (url | digest) for the release being installed.
# NAME "@tarball" means the source archive GitHub/Gitea generate per tag
# (for projects that attach no assets); it has no digest.
asset_field() {
    jq -r --arg v "$VERSION" --arg n "$1" --arg f "$2" '
        first(.[] | select(.version == $v)
              | if $n == "@tarball" then (if $f == "url" then .tarball else null end)
                else (.assets[] | select(.name == $n) | .[$f]) end) // empty' \
        <<<"$RELEASES"
}
