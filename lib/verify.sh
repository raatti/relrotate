# shellcheck shell=bash
# relrotate: download and verification.
#
# VERIFY=api-digest      sha256 digest from the release API (GitHub)
# VERIFY=sha256-sidecar  separate <asset>.sha256 file (CHECKSUM_ASSET to override)
# VERIFY=checksums-file  one SHA256SUMS / checksums.txt for all assets (CHECKSUM_ASSET)
# VERIFY=gpg             detached signature (GPG_SIG_ASSET, GPG_KEYRING)
# VERIFY="gpg sha256-sidecar"   several methods, all must pass
# VERIFY=none            explicit opt-out; logged as a warning on every run

DOWNLOAD=""

fetch_asset() {
    local name="$1" out="$2" url
    url="$(asset_field "$name" url)"
    [[ -n "$url" ]] || { log err msg="asset not found in release" asset="$name" version="$VERSION"; return 1; }
    log debug msg="downloading" url="$url"
    "$CURL" -fsSL --retry 3 --retry-delay 5 --max-time 1800 -A "$USER_AGENT" "${CURL_OPTS[@]+"${CURL_OPTS[@]}"}" \
        -o "$out" "$url"
}

download_and_verify() {
    local name; name="$(expand "$ASSET")"
    if [[ "$name" == "@tarball" ]]; then
        DOWNLOAD="$WORK/$APP-$VERSION.tar.gz"
    else
        DOWNLOAD="$WORK/$name"
    fi
    fetch_asset "$name" "$DOWNLOAD" || return 1

    local m
    for m in $VERIFY; do
        case "$m" in
            api-digest)     verify_api_digest "$name" || return 1 ;;
            sha256-sidecar) verify_sidecar "$name" || return 1 ;;
            checksums-file) verify_checksums_file "$name" || return 1 ;;
            gpg)            verify_gpg "$name" || return 1 ;;
            none)           log warning msg="VERIFY=none: installing an unverified download" asset="$name" ;;
            *)              log err msg="unknown VERIFY method" method="$m"; return 1 ;;
        esac
    done
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

verify_sidecar() {
    local name="$1" sc
    sc="$(expand "${CHECKSUM_ASSET:-${name}.sha256}")"
    fetch_asset "$sc" "$WORK/$sc" || return 1
    check_hash "$(awk 'NF{print $1; exit}' "$WORK/$sc")" "$sc"
}

verify_checksums_file() {
    local name="$1" cf line
    [[ -n "$CHECKSUM_ASSET" ]] || { log err msg="VERIFY=checksums-file needs CHECKSUM_ASSET"; return 1; }
    cf="$(expand "$CHECKSUM_ASSET")"
    fetch_asset "$cf" "$WORK/$cf" || return 1
    # Lines look like "<hash>  <name>" or "<hash> *<name>"
    line="$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f)} f==n {print $1; exit}' "$WORK/$cf")"
    [[ -n "$line" ]] || { log err msg="asset not listed in checksum file" asset="$name" file="$cf"; return 1; }
    check_hash "$line" "$cf"
}

verify_gpg() {
    local name="$1" sig
    command -v gpgv >/dev/null 2>&1 || { log err msg="VERIFY=gpg needs gpgv"; return 1; }
    [[ -n "$GPG_KEYRING" && -r "$GPG_KEYRING" ]] || { log err msg="GPG_KEYRING not readable" keyring="$GPG_KEYRING"; return 1; }
    sig="$(expand "${GPG_SIG_ASSET:-${name}.asc}")"
    fetch_asset "$sig" "$WORK/$sig" || return 1
    if ! gpgv --keyring "$GPG_KEYRING" "$WORK/$sig" "$DOWNLOAD" >"$WORK/gpgv.log" 2>&1; then
        log err msg="gpg signature check failed" asset="$name" detail="$(tail -n1 "$WORK/gpgv.log")"
        return 1
    fi
}
