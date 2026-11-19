# shellcheck shell=bash
# shellcheck disable=SC2034  # FAIL_STEP is read in lib/outcome.sh
# relrotate: download and verification.
#
# VERIFY=api-digest      sha256 digest from the release API (GitHub)
# VERIFY=sha256-sidecar  separate <asset>.sha256 file (CHECKSUM_ASSET to override)
# VERIFY=checksums-file  one SHA256SUMS / checksums.txt for all assets (CHECKSUM_ASSET);
#                        with CHECKSUM_SIG_ASSET, that file's detached signature
#                        is checked against GPG_KEYRING first
# VERIFY=gpg             detached signature (GPG_SIG_ASSET, GPG_KEYRING)
# VERIFY="gpg sha256-sidecar"   several methods, all must pass
# VERIFY=none            explicit opt-out; logged as a warning on every run

DOWNLOAD=""

# Every VERIFY method: verify_<method> (dashes as underscores) checks a download,
# verify_needs says which extra release assets it fetches. doctor shares both,
# and an unknown method is refused by verify_known alone.
VERIFY_METHODS="api-digest sha256-sidecar checksums-file gpg none"
verify_known() { [[ -n "$1" && "$1" != *" "* && " $VERIFY_METHODS " == *" $1 "* ]]; }

# verify_validate: die 2 unless VERIFY is a non-empty list of known methods.
# For the layouts that download.
verify_validate() {
    local m
    [[ -n "${VERIFY//[[:space:]]/}" ]] || die 2 "$APP: VERIFY is not set (use VERIFY=none to opt out explicitly)"
    for m in $VERIFY; do
        verify_known "$m" || die 2 "$APP: unknown VERIFY method: $m"
    done
}

# verify_needs NAME METHOD: the extra assets METHOD fetches for asset NAME, one
# per line (checksums-file: the file, then its signature if CHECKSUM_SIG_ASSET).
verify_needs() {
    case "$2" in
        sha256-sidecar) expand "${CHECKSUM_ASSET:-${1}.sha256}"; echo ;;
        checksums-file)
            [[ -z "$CHECKSUM_ASSET" ]] || { expand "$CHECKSUM_ASSET"; echo; }
            [[ -z "$CHECKSUM_SIG_ASSET" ]] || { expand "$CHECKSUM_SIG_ASSET"; echo; } ;;
        gpg) expand "${GPG_SIG_ASSET:-${1}.asc}"; echo ;;
    esac
}

fetch_asset() {
    local name="$1" out="$2" url
    # A name from the release API (TAG expands into it too) becomes a local
    # file name under $WORK: it must not leave that directory.
    case "$name" in ""|.|..|*/*) log err msg="unsafe asset name" asset="$name"; return 1 ;; esac
    url="$(asset_field "$name" url)"
    [[ -n "$url" ]] || { log err msg="asset not found in release" asset="$name" version="$VERSION"; return 1; }
    log debug msg="downloading" url="$url"
    "$CURL" -fsSL --globoff --retry 3 --retry-delay 5 --max-time 1800 -A "$USER_AGENT" "${CURL_OPTS[@]+"${CURL_OPTS[@]}"}" \
        --proto "$(curl_proto)" --proto-redir "$(curl_proto)" -o "$out" -- "$url"
}

# FAIL_STEP names the step that failed (download, verify-METHOD): it refines
# the "alert once" key of outcome.sh, never a message.
download_and_verify() {
    FAIL_STEP=download
    [[ -n "$VERIFY" ]] || { log err msg="VERIFY is not set (use VERIFY=none to opt out explicitly)"; return 1; }
    local name; name="$(expand "$ASSET")"
    if [[ "$name" == "@tarball" ]]; then
        DOWNLOAD="$WORK/$APP-$VERSION.tar.gz"
    else
        DOWNLOAD="$WORK/$name"
    fi
    fetch_asset "$name" "$DOWNLOAD" || return 1

    local m
    for m in $VERIFY; do
        FAIL_STEP="verify-$m"
        verify_known "$m" || { log err msg="unknown VERIFY method" method="$m"; return 1; }
        "verify_${m//-/_}" "$name" || return 1
    done
    FAIL_STEP=""
    log info event=verified asset="$name" methods="$VERIFY"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

check_hash() {
    local expected="$1" what="$2" actual
    expected="$(tr '[:upper:]' '[:lower:]' <<<"$expected")"
    actual="$(sha256_of "$DOWNLOAD")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { log err msg="no usable sha256 from $what"; return 1; }
    if [[ "$actual" != "$expected" ]]; then
        log err msg="sha256 mismatch ($what)" expected="$expected" actual="$actual"
        return 1
    fi
}

verify_api_digest() {
    local d; d="$(asset_field "$1" digest)"
    [[ "$d" == sha256:* ]] || { log err msg="release API gave no sha256 digest for asset" asset="$1"; return 1; }
    check_hash "${d#sha256:}" "API digest"
}

verify_none() { log warning msg="VERIFY=none: installing an unverified download" asset="$1"; }

verify_sha256_sidecar() {
    local name="$1" sc
    sc="$(verify_needs "$name" sha256-sidecar)"
    fetch_asset "$sc" "$WORK/$sc" || return 1
    check_hash "$(tr -d '\r' < "$WORK/$sc" | awk 'NF{print $1; exit}')" "$sc"
}

verify_checksums_file() {
    local name="$1" cf line need
    [[ -n "$CHECKSUM_ASSET" ]] || { log err msg="VERIFY=checksums-file needs CHECKSUM_ASSET"; return 1; }
    mapfile -t need < <(verify_needs "$name" checksums-file)
    cf="${need[0]}"
    fetch_asset "$cf" "$WORK/$cf" || return 1
    if [[ -n "$CHECKSUM_SIG_ASSET" ]]; then
        local sig="${need[1]}"
        fetch_asset "$sig" "$WORK/$sig" || return 1
        gpgv_check "$WORK/$sig" "$WORK/$cf" "$cf" || return 1
    fi
    # Lines look like "<hash>  <name>", "<hash> *<name>" or "<hash>  ./<name>"; CRLF is fine
    line="$(tr -d '\r' < "$WORK/$cf" | awk -v n="$name" '{f=$2; sub(/^\*/, "", f); sub(/^\.\//, "", f)} f==n {print $1; exit}')"
    [[ -n "$line" ]] || { log err msg="asset not listed in checksum file" asset="$name" file="$cf"; return 1; }
    check_hash "$line" "$cf"
}

verify_gpg() {
    local name="$1" sig
    sig="$(verify_needs "$name" gpg)"
    fetch_asset "$sig" "$WORK/$sig" || return 1
    gpgv_check "$WORK/$sig" "$DOWNLOAD" "$name"
}

# gpgv_check SIG FILE WHAT: FILE carries a good signature from GPG_KEYRING.
gpgv_check() {
    command -v gpgv >/dev/null 2>&1 || { log err msg="gpg verification needs gpgv"; return 1; }
    # Absolute only: gpgv looks a bare name up in its gpg home, unlike -r.
    [[ "$GPG_KEYRING" == /* && -r "$GPG_KEYRING" ]] || { log err msg="GPG_KEYRING must be an absolute path to a readable file" keyring="$GPG_KEYRING"; return 1; }
    if ! gpgv --keyring "$GPG_KEYRING" "$1" "$2" >"$WORK/gpgv.log" 2>&1; then
        log err msg="gpg signature check failed" asset="$3" detail="$(tail -n1 "$WORK/gpgv.log")"
        return 1
    fi
}
