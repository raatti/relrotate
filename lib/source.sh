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
# where any local user could read it in ps. It is never sent over http://,
# and a token file that is set but unreadable is an error, not a silent
# unauthenticated request. The URL follows --, and curl may speak only
# https, also on redirects (http too when the recipe's own SOURCE is http).
api_get() {
    local url="$1" file="$2" scheme="$3" auth=""; shift 3
    if [[ -n "$file" && "$url" != https://* ]]; then
        log warning msg="not sending the API token over plain http" url="$url"
        file=""
    fi
    if [[ -n "$file" ]]; then
        [[ -r "$file" ]] || { log err msg="token file is not readable" file="$file"; return 1; }
        auth="header = \"Authorization: $scheme $(tr -d '[:space:]' < "$file")\""
    fi
    "$CURL" -fsSL --retry 3 --retry-delay 5 --max-time 60 -A "$USER_AGENT" \
        -H 'Accept: application/json' "${CURL_OPTS[@]+"${CURL_OPTS[@]}"}" \
        --proto "$(curl_proto)" --proto-redir "$(curl_proto)" \
        --config - "$@" -- "$url" <<<"$auth"
}

# Protocols curl may use for URLs from this recipe's source and releases.
curl_proto() {
    case "$SOURCE" in
        gitea:http://*|forgejo:http://*) printf '=http,https' ;;
        *) printf '=https' ;;
    esac
}

# gitea_token_file HOST: the global token file, or "" when GITEA_TOKEN_HOSTS
# is set and does not list HOST (with or without port).
gitea_token_file() {
    local h="${1#*://}" w
    h="${h,,}"   # host names are case-insensitive
    if [[ -n "$GITEA_TOKEN_HOSTS" ]]; then
        for w in ${GITEA_TOKEN_HOSTS,,}; do
            [[ "$w" == "$h" || "$w" == "${h%:*}" ]] && { printf '%s' "$GITEA_TOKEN_FILE"; return 0; }
        done
        return 0
    fi
    printf '%s' "$GITEA_TOKEN_FILE"
}

# A failed release check is recorded in last-result (update only: check and
# dry runs change no state) and mailed once, not on every timer run.
# The "check-failed" marker, not last-result, says a failure episode is
# already mailed: other results (a still-unhealthy recheck) may be written
# in between without starting a new episode. A good check removes it.
fetch_fail() {
    local reason="$1" first=0
    log err msg="$APP: $reason"
    if [[ "${RECORD_FETCH_FAILURE:-0}" == 1 ]]; then
        state_has check-failed || first=1
        state_set check-failed "$reason"
        state_set last-result "check failed: $reason"
        (( ! first )) || notify "release check failed" \
            "relrotate could not check $APP for new releases: $reason. It retries on every timer run and does not mail again until a check succeeds."
    fi
    exit 1
}

# jq: the version a tag stands for. Without VERSION_REGEX, TAG_PREFIX is cut
# off. A regex with a group v gives the version as is; with groups v1..v4
# (a date tag: 2026-11-18-r1) the numbers are joined with dots (2026.11.18.1).
# shellcheck disable=SC2016  # jq variables, not shell
JQ_TAG_VERSION='def tag_version($re; $prefix):
    if $re == "" then ltrimstr($prefix)
    else (capture($re)? // empty)
         | if .v != null then .v
           else [.v1, .v2, .v3, .v4] | map(select(. != null) | tonumber? | tostring) | join(".") end
    end;'

# tag_version TAG: the same for one tag (an image tag in a quadlet).
tag_version() {
    jq -rn --arg t "$1" --arg re "$VERSION_REGEX" --arg prefix "$TAG_PREFIX" \
        "$JQ_TAG_VERSION"' $t | tag_version($re; $prefix)'
}

fetch_releases() {
    local raw kind="${SOURCE%%:*}" spec="${SOURCE#*:}"
    case "$kind" in
        github)
            [[ "$spec" =~ ^[^/]+/[^/]+$ ]] || die 2 "$APP: SOURCE must be github:owner/repo"
            raw="$(api_get "https://api.github.com/repos/$spec/releases?per_page=100" \
                "$GITHUB_TOKEN_FILE" Bearer -H 'X-GitHub-Api-Version: 2022-11-28')" \
                || fetch_fail "GitHub API request failed for $spec"
            ;;
        gitea|forgejo)
            [[ "$spec" =~ ^https?://[^/]+/[^/]+/[^/]+$ ]] \
                || die 2 "$APP: SOURCE must be gitea:https://host/owner/repo"
            local host="${spec%/*/*}" path="${spec#"${spec%/*/*}"/}"
            raw="$(api_get "$host/api/v1/repos/$path/releases?limit=50" \
                "$(gitea_token_file "$host")" token)" \
                || fetch_fail "release API request failed for $spec"
            ;;
        *) die 2 "$APP: unknown SOURCE type '$kind' (github|gitea)" ;;
    esac
    # A regex, not ${raw//[[:space:]]/}: that takes minutes on a 2 MB list.
    [[ "$raw" =~ [^[:space:]] ]] || fetch_fail "release API returned an empty response for $spec"

    # n: releases that pass draft/prerelease filtering; r: those with a usable version.
    # A tag_name that is not a string (null) is skipped; \z, not $, so a
    # trailing newline cannot pass.
    local parsed n
    parsed="$(jq -c --arg prefix "$TAG_PREFIX" --arg re "$VERSION_REGEX" \
        --arg pre "$ALLOW_PRERELEASE" "$JQ_TAG_VERSION"'
        [ .[]
          | select(.draft != true)
          | select($pre == "yes" or .prerelease != true)
          | select(.tag_name | type == "string") ] as $elig
        | { t: length, n: ($elig | length), r: [ $elig[]
          | (.tag_name) as $tag
          | ($tag | tag_version($re; $prefix)) as $v
          | select($v | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)"
              + (if $re != "" then "{0,2}" else "?" end)   # a regex may give four parts
              + (if $pre == "yes" then "(-[0-9A-Za-z.]+)?" else "" end) + "\\z"))
          | select($v | sub("-.*"; "") | test("[0-9]{10}") | not)
          | { tag: $tag, version: $v, prerelease: (.prerelease // false),
              published: (.published_at // .created_at // null),
              tarball: (.tarball_url // null),
              assets: [ (.assets // [])[]
                        | { name, url: .browser_download_url, digest: (.digest // null) } ] }
        ] }' <<<"$raw")" || fetch_fail "could not parse the release list for $spec"
    n="$(jq .n <<<"$parsed")"
    [[ "$(jq .t <<<"$parsed")" != 0 ]] || fetch_fail "the release list for $spec is empty (wrong SOURCE, or releases deleted?)"
    RELEASES="$(jq -c .r <<<"$parsed")"
    if (( n > 0 )) && [[ "$RELEASES" == "[]" ]]; then
        fetch_fail "$n releases fetched for $spec but none has a usable version (TAG_PREFIX='$TAG_PREFIX' VERSION_REGEX='$VERSION_REGEX'); did upstream change its tag scheme?"
    fi
    [[ "${RECORD_FETCH_FAILURE:-0}" != 1 ]] || state_clear check-failed
    log debug msg="releases parsed" count="$(jq length <<<"$RELEASES")"
}

all_versions() {
    # '-' -> '~' so a prerelease sorts below its final release (1.3.0-rc1 < 1.3.0)
    jq -r '.[].version | gsub("-"; "~")' <<<"$RELEASES" | sort -V | tr '~' '-'
}

newest_version() {
    all_versions | tail -n1
}

tag_for_version() {
    jq -r --arg v "$1" 'first(.[] | select(.version == $v) | .tag)' <<<"$RELEASES"
}

# release_has_asset VERSION: the release carries the asset ASSET expands to.
release_has_asset() {
    local VERSION="$1" TAG name
    # shellcheck disable=SC2034  # read by expand
    TAG="$(tag_for_version "$VERSION")"
    name="$(expand "$ASSET")"
    [[ -n "$(asset_field "$name" url)" ]]
}

# pick_candidate CURRENT: sets CANDIDATE to the highest version newer than
# CURRENT that POLICY allows, is not skipped and (MIN_AGE_DAYS) is old
# enough, and WAITING to a newer one that is still too young ("" if none).
# Layouts that download only get releases that carry the asset.
pick_candidate() {
    local cur="$1" v skip lacking="" dl=0
    CANDIDATE="" WAITING=""
    layout needs_download && dl=1
    skip="$(state_get skip)"
    [[ -z "$cur" ]] && return 0
    while read -r v; do
        [[ -n "$v" ]] || continue
        version_gt "$v" "$cur" || continue
        allowed_by_policy "$cur" "$v" || continue
        [[ -n "$skip" ]] && same_version "$v" "$skip" && continue
        if (( dl )) && ! release_has_asset "$v"; then lacking="$v"; continue; fi
        if ! old_enough "$v"; then WAITING="$v"; continue; fi
        CANDIDATE="$v"
    done < <(all_versions)
    if [[ -n "$lacking" ]] && { [[ -z "$CANDIDATE" ]] || version_gt "$lacking" "$CANDIDATE"; }; then
        log warning msg="newest eligible release has no matching asset" version="$lacking" using="${CANDIDATE:-nothing}"
    fi
    if [[ -n "$WAITING" ]] && { [[ -z "$CANDIDATE" ]] || version_gt "$WAITING" "$CANDIDATE"; }; then
        log info event=waiting version="$WAITING" until="$(release_ripe_at "$WAITING")" min_age_days="$MIN_AGE_DAYS"
    else
        WAITING=""
    fi
}

# release_ripe_at VERSION: when VERSION is MIN_AGE_DAYS old (ISO date), or
# "unknown" when the release has no usable publish date.
release_ripe_at() {
    local pub ts
    pub="$(jq -r --arg v "$1" 'first(.[] | select(.version == $v) | .published) // empty' <<<"$RELEASES")"
    if [[ -z "$pub" ]] || ! ts="$(date -d "$pub" +%s 2>/dev/null)"; then echo unknown; return 0; fi
    date -u -d "@$(( ts + MIN_AGE_DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%SZ
}

# old_enough VERSION: published at least MIN_AGE_DAYS ago. A release with no
# usable date waits (fails closed) and says so.
old_enough() {
    (( MIN_AGE_DAYS > 0 )) || return 0
    local ripe; ripe="$(release_ripe_at "$1")"
    if [[ "$ripe" == unknown ]]; then
        log warning msg="release has no usable publish date; waiting for it (MIN_AGE_DAYS)" version="$1"
        return 1
    fi
    (( $(date +%s) >= $(date -d "$ripe" +%s) ))
}

# A newer release than the skipped one clears the skip marker. Update only:
# check must not change state.
clear_stale_skip() {
    local cand="$1" skip
    skip="$(state_get skip)"
    if [[ -n "$skip" && -n "$cand" ]] && version_gt "$cand" "$skip"; then
        state_clear skip
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
    local seen
    seen="$(state_get notified)"
    [[ "$seen" == "$newest" ]] && return 0
    log info event=out-of-policy-release version="$newest" installed="$cur" policy="$POLICY"
    notify "$newest available (outside policy=$POLICY)" \
        "$APP $newest is out; $cur is installed. relrotate will not install it because POLICY=$POLICY. Read the release notes, then upgrade by hand or raise POLICY in $CONF_DIR/apps.d/$APP.conf." info
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
