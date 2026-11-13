#!/usr/bin/env bash
# Synthetic end-to-end tests for relrotate. No root, no network:
# releases are a JSON file, assets are file:// URLs, systemctl/podman/sendmail
# are stubs that log what they were asked to do.
set -Eeuo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
RR="$here/../relrotate"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# ----------------------------------------------------------------- stubs ---
mkdir -p "$T/bin" "$T/log"
cat > "$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$T/log/systemctl"
if [[ " \$* " == *" is-active "* ]]; then [[ ! -e "$T/unhealthy" ]]; exit; fi
if [[ " \$* " == *" restart "* ]]; then [[ ! -e "$T/fail-restart" ]]; exit; fi
if [[ " \$* " == *" daemon-reload "* ]]; then
    if [[ -e "$T/fail-reload-once" ]]; then rm -f "$T/fail-reload-once"; exit 1; fi
    [[ ! -e "$T/fail-reload" ]]; exit
fi
EOF
cat > "$T/bin/podman" <<EOF
#!/usr/bin/env bash
echo "podman \$*" >> "$T/log/podman"
if [[ -s "$T/fail-pull" && " \$* " == *" \$(cat "$T/fail-pull") "* ]]; then exit 1; fi
EOF
# Release API requests are answered from $STUB_RELEASES; file:// URLs go
# to the real curl. Arguments are logged as given; a --config - on stdin is
# logged to curl-config with Authorization values redacted.
real_curl="$(command -v curl)"
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
url="\${!#}"
printf '%s\n' "curl \$*" >> "$T/log/curl"
if [[ " \$* " == *" --config - "* ]]; then
    sed -E 's/(Authorization: [A-Za-z]+) [^"]+/\1 REDACTED/' >> "$T/log/curl-config"
fi
if [[ "\$url" == file://* ]]; then exec "$real_curl" "\$@"; fi
cat "\${STUB_RELEASES:-$T/releases.json}"
EOF
cat > "$T/bin/sendmail" <<EOF
#!/usr/bin/env bash
cat >> "$T/log/mail"; echo "----" >> "$T/log/mail"
EOF
chmod +x "$T/bin/"*
export RELROTATE_SYSTEMCTL="$T/bin/systemctl" RELROTATE_PODMAN="$T/bin/podman" \
       RELROTATE_SENDMAIL="$T/bin/sendmail" \
       RELROTATE_CURL="$T/bin/curl"
export RELROTATE_CONF_DIR="$T/etc" RELROTATE_STATE_DIR="$T/state"
mkdir -p "$T/etc/apps.d" "$T/state" "$T/assets"
echo 'MAIL_TO=root@example.net' > "$T/etc/relrotate.conf"

# --------------------------------------------------------- fake releases ---
sha() { sha256sum "$1" | awk '{print $1}'; }

make_tarball() {   # version
    local v="$1" d="$T/build/demo-$1"
    mkdir -p "$d/data"
    echo "demo $v" > "$d/VERSION"
    echo "stock data" > "$d/data/readme"
    tar -czf "$T/assets/demo-$v.tar.gz" -C "$T/build" "demo-$v"
    sha "$T/assets/demo-$v.tar.gz" > "$T/assets/demo-$v.tar.gz.sha256"
}
make_binary() {
    local v="$1"
    printf '#!/bin/sh\necho "demobin %s"\n' "$v" > "$T/assets/demobin_${v}_linux_amd64"
    chmod +x "$T/assets/demobin_${v}_linux_amd64"
    bzip2 -kf "$T/assets/demobin_${v}_linux_amd64"
}
for v in 1.2.3 1.2.4 1.3.0 2.0.0; do make_tarball "$v"; make_binary "$v"; done
( cd "$T/assets" && sha256sum demobin_*_linux_amd64 demobin_*_linux_amd64.bz2 > checksums.txt )

# GitHub-shaped release list, newest first, plus a prerelease and a draft.
releases_json() {
    local out="[" first=1 v
    for v in 2.0.0 1.4.0-rc1 1.3.0 1.2.4 1.2.3; do
        local pre=false draft=false
        [[ "$v" == *-rc* ]] && pre=true
        local assets="[]"
        if [[ "$v" != *-rc* ]]; then
            assets="$(jq -n --arg v "$v" --arg d "$T/assets" \
                --arg td "sha256:$(sha "$T/assets/demo-$v.tar.gz")" \
                --arg bd "sha256:$(sha "$T/assets/demobin_${v}_linux_amd64")" '[
                {name: "demo-\($v).tar.gz", browser_download_url: "file://\($d)/demo-\($v).tar.gz", digest: $td},
                {name: "demo-\($v).tar.gz.sha256", browser_download_url: "file://\($d)/demo-\($v).tar.gz.sha256"},
                {name: "demobin_\($v)_linux_amd64", browser_download_url: "file://\($d)/demobin_\($v)_linux_amd64", digest: $bd},
                {name: "demobin_\($v)_linux_amd64.bz2", browser_download_url: "file://\($d)/demobin_\($v)_linux_amd64.bz2"},
                {name: "checksums.txt", browser_download_url: "file://\($d)/checksums.txt"}]')"
        fi
        (( first )) || out+=","
        first=0
        out+="$(jq -n --arg t "v$v" --argjson pre "$pre" --argjson draft "$draft" --argjson a "$assets" \
            '{tag_name: $t, prerelease: $pre, draft: $draft, assets: $a}')"
    done
    out+=",$(jq -n '{tag_name: "v9.9.9", draft: true, prerelease: false, assets: []}')"
    echo "$out]"
}
releases_json > "$T/releases.json"

reset_logs() { rm -f "$T/log/"* "$T/healthz" "$T/unhealthy" "$T/fail-pull" "$T/fail-reload" "$T/fail-reload-once" "$T/fail-restart"; }

# ------------------------------------------------- symlink layout recipe ---
web_recipe() {   # policy verify
    cat > "$T/etc/apps.d/web.conf" <<EOF
SOURCE=github:example/demo
ASSET='demo-\${VERSION}.tar.gz'
VERIFY="$2"
POLICY=$1
LAYOUT=symlink
TARGET=$T/www/demo
RELEASES_DIR=$T/www/demo-releases
LINKS=('data:$T/www/shared-data')
SERVICE=demo.service
HEALTH_RETRIES=2
HEALTH_DELAY=0
EOF
}
web_install_old() {
    rm -rf "$T/www" "$T/state/web"
    mkdir -p "$T/www/demo-releases/1.2.3" "$T/www/shared-data"
    echo "demo 1.2.3" > "$T/www/demo-releases/1.2.3/VERSION"
    ln -s "$T/www/demo-releases/1.2.3" "$T/www/demo"
}

echo "== policy selection"
web_install_old
for p in patch:1.2.4 minor:1.3.0 major:2.0.0; do
    web_recipe "${p%%:*}" api-digest
    got="$("$RR" check web 2>/dev/null | awk '$1=="candidate"{print $2}')"
    check "POLICY=${p%%:*} picks ${p#*:} (got $got)" test "$got" = "${p#*:}"
done
web_recipe minor api-digest
check "installed version read from symlink" \
    bash -c "'$RR' check web 2>/dev/null | grep -q 'installed *1.2.3'"
check "draft v9.9.9 ignored (newest is 2.0.0)" \
    bash -c "'$RR' check web 2>/dev/null | grep -q 'newest *2.0.0'"

echo "== check changes nothing"
web_install_old; web_recipe minor api-digest
mkdir -p "$T/state/web"; echo 1.2.4 > "$T/state/web/skip"
"$RR" check web >/dev/null 2>&1
check "check keeps the skip marker" test -s "$T/state/web/skip"
check "update past a skipped version" "$RR" update web
check "update clears the skip marker" test ! -e "$T/state/web/skip"

echo "== symlink update, two verify methods"
reset_logs; web_install_old; web_recipe minor "api-digest sha256-sidecar"
check "update exits 0" "$RR" update web
check "symlink points at 1.3.0" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.3.0"
check "state installed=1.3.0" test "$(cat "$T/state/web/installed")" = 1.3.0
check "state previous=1.2.3" test "$(cat "$T/state/web/previous")" = 1.2.3
check "LINKS replaced data/ with symlink" test -L "$T/www/demo-releases/1.3.0/data"
check "service restarted" grep -q 'restart demo.service' "$T/log/systemctl"
check "mail: updated" grep -q 'updated 1.2.3 -> 1.3.0' "$T/log/mail"
check "mail: 2.0.0 out of policy" grep -q '2.0.0 available' "$T/log/mail"
check "second run is a no-op" "$RR" update web
check "out-of-policy mail sent only once" test "$(grep -c '2.0.0 available' "$T/log/mail")" = 1

echo "== dry run changes nothing"
reset_logs; web_install_old; web_recipe minor api-digest
check "dry run exits 0" "$RR" update -n web
check "dry run: symlink unchanged" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "dry run: no state written" bash -c "[[ -z \$(ls '$T/state/web' | grep -v lock) ]]"
check "dry run: no mail (not even out-of-policy)" test ! -e "$T/log/mail"
jq '(.[] | select(.tag_name=="v1.3.0") | .assets[0].digest) = "sha256:'"$(printf '0%.0s' {1..64})"'"' \
    "$T/releases.json" > "$T/releases-bad.json"
check "dry run with a bad download fails" bash -c "! STUB_RELEASES='$T/releases-bad.json' '$RR' update -n web 2>/dev/null"
check "dry run failure: no state, no mail" bash -c "[[ -z \$(ls '$T/state/web' | grep -v lock) && ! -e '$T/log/mail' ]]"

echo "== HEALTH_URL"
reset_logs; web_install_old; web_recipe minor api-digest
echo "HEALTH_URL=file://$T/healthz" >> "$T/etc/apps.d/web.conf"
check "HEALTH_URL missing: update rolls back" bash -c "! '$RR' update web 2>/dev/null"
check "HEALTH_URL missing: symlink on 1.2.3" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
reset_logs; web_install_old; touch "$T/healthz"
check "HEALTH_URL answers: update exits 0" "$RR" update web
check "HEALTH_URL was asked" grep -q "file://$T/healthz" "$T/log/curl"
rm -f "$T/healthz"

echo "== digest mismatch"
reset_logs; web_install_old; web_recipe minor api-digest
jq '(.[] | select(.tag_name=="v1.3.0") | .assets[0].digest) = "sha256:'"$(printf '0%.0s' {1..64})"'"' \
    "$T/releases.json" > "$T/releases-bad.json"
check "update fails" bash -c "! STUB_RELEASES='$T/releases-bad.json' '$RR' update web 2>/dev/null"
check "symlink unchanged" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "no installed state written" test ! -e "$T/state/web/installed"
check "no release dir staged" test ! -e "$T/www/demo-releases/1.3.0"
check "mail: failed before install" grep -q 'failed before install' "$T/log/mail"

echo "== health check fails -> rollback"
reset_logs; web_install_old; web_recipe minor api-digest
touch "$T/unhealthy"
# healthy again once we are back on the old version
cat >> "$T/etc/apps.d/web.conf" <<EOF
healthcheck() { [[ "\$(cat "\$TARGET/VERSION")" == "demo 1.2.3" ]]; }
EOF
check "update fails" bash -c "! '$RR' update web 2>/dev/null"
check "symlink rolled back to 1.2.3" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "installed state not advanced" test ! -e "$T/state/web/installed"
check "mail: rolled back" grep -q 'rolled back to 1.2.3' "$T/log/mail"

echo "== every update step that fails is caught"
for hook in post_extract pre_update; do
    reset_logs; web_install_old; web_recipe minor api-digest
    echo "$hook() { return 1; }" >> "$T/etc/apps.d/web.conf"
    check "$hook failure: update fails" bash -c "! '$RR' update web 2>/dev/null"
    check "$hook failure: symlink unchanged" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
    check "$hook failure: no restart" bash -c "! grep -q restart '$T/log/systemctl' 2>/dev/null"
    check "$hook failure: mail says nothing changed" grep -q 'failed before install' "$T/log/mail"
done
for step in post_flip restart; do
    reset_logs; web_install_old; web_recipe minor api-digest
    if [[ "$step" == post_flip ]]; then
        echo "post_flip() { return 1; }" >> "$T/etc/apps.d/web.conf"
    else
        touch "$T/fail-restart"
        # restart works again once relrotate rolls back
        echo "on_rollback() { rm -f '$T/fail-restart'; }" >> "$T/etc/apps.d/web.conf"
    fi
    check "$step failure: update fails" bash -c "! '$RR' update web 2>/dev/null"
    check "$step failure: symlink rolled back" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
    check "$step failure: installed state not advanced" test ! -e "$T/state/web/installed"
    check "$step failure: mail rolled back" grep -q 'rolled back to 1.2.3' "$T/log/mail"
done

echo "== failing on_rollback hook during an automatic rollback"
reset_logs; web_install_old; web_recipe minor api-digest
echo "post_flip() { return 1; }; on_rollback() { return 1; }" >> "$T/etc/apps.d/web.conf"
check "update fails" bash -c "! '$RR' update web 2>/dev/null"
check "still restarted and back on 1.2.3" bash -c "grep -q 'restart demo.service' '$T/log/systemctl' && [[ \$(readlink '$T/www/demo') == '$T/www/demo-releases/1.2.3' ]]"
check "last-result names the hook" grep -q 'on_rollback hook failed' "$T/state/web/last-result"
check "mail names the hook" grep -q 'on_rollback hook failed' "$T/log/mail"

echo "== manual rollback"
web_on_new() {   # installed 1.3.0, previous 1.2.3, both release dirs present
    reset_logs; web_install_old; web_recipe minor api-digest
    mkdir -p "$T/www/demo-releases/1.3.0"; echo "demo 1.3.0" > "$T/www/demo-releases/1.3.0/VERSION"
    ln -sfn "$T/www/demo-releases/1.3.0" "$T/www/demo"
    mkdir -p "$T/state/web"; echo 1.3.0 > "$T/state/web/installed"; echo 1.2.3 > "$T/state/web/previous"
}
web_on_new
check "rollback exits 0" "$RR" rollback web
check "symlink on 1.2.3" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "state installed=1.2.3 previous=1.3.0 skip=1.3.0" bash -c "[[ \$(cat '$T/state/web/installed') == 1.2.3 && \$(cat '$T/state/web/previous') == 1.3.0 && \$(cat '$T/state/web/skip') == 1.3.0 ]]"
check "no mail on success" test ! -s "$T/log/mail"

web_on_new
echo "on_rollback() { return 1; }" >> "$T/etc/apps.d/web.conf"
check "hook failure: rollback exits non-zero" bash -c "! '$RR' rollback web 2>/dev/null"
check "hook failure: still restarted" grep -q 'restart demo.service' "$T/log/systemctl"
check "hook failure: state records 1.2.3 as installed" test "$(cat "$T/state/web/installed")" = 1.2.3
check "hook failure: last-result names the hook" grep -q 'on_rollback hook failed' "$T/state/web/last-result"
check "hook failure: mail sent" grep -q 'manual rollback' "$T/log/mail"

web_on_new
touch "$T/unhealthy"
check "unhealthy: rollback exits non-zero" bash -c "! '$RR' rollback web 2>/dev/null"
check "unhealthy: state records 1.2.3 as installed" test "$(cat "$T/state/web/installed")" = 1.2.3
check "unhealthy: 1.3.0 skipped" test "$(cat "$T/state/web/skip")" = 1.3.0
check "unhealthy: last-result says UNHEALTHY" grep -q UNHEALTHY "$T/state/web/last-result"
check "unhealthy: status shows it" bash -c "'$RR' status web | grep -q UNHEALTHY"
check "unhealthy: mail sent" grep -q 'manual rollback' "$T/log/mail"

web_on_new
rm -rf "$T/www/demo-releases/1.2.3"
check "switch fails: rollback exits non-zero" bash -c "! '$RR' rollback web 2>/dev/null"
check "switch fails: symlink still on 1.3.0" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.3.0"
check "switch fails: state still 1.3.0" test "$(cat "$T/state/web/installed")" = 1.3.0
check "switch fails: no skip written" test ! -e "$T/state/web/skip"
check "switch fails: no restart" bash -c "! grep -q restart '$T/log/systemctl' 2>/dev/null"
check "switch fails: mail sent" grep -q 'manual rollback' "$T/log/mail"
rm -rf "$T/state/web"

echo "== flip failure is caught"
reset_logs; web_install_old; web_recipe minor api-digest
# a directory where the temporary symlink must go makes ln -sfn fail
mkdir -p "$T/www/demo.relrotate-new/blocker"
check "update fails when the flip fails" bash -c "! '$RR' update web 2>/dev/null"
check "installed state not advanced" test ! -e "$T/state/web/installed"
check "symlink still on 1.2.3" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
rm -rf "$T/www/demo.relrotate-new"

echo "== unsafe archive"
reset_logs; web_install_old; web_recipe minor none
mkdir -p "$T/evil"; echo x > "$T/evil/x"
tar -czf "$T/assets/demo-1.3.0.tar.gz" -C "$T/evil" --transform 's|^|../../|' x 2>/dev/null
check "update refuses ../ paths" bash -c "! '$RR' update web 2>/dev/null"
check "nothing written outside" test ! -e "$T/www/x"
make_tarball 1.3.0; releases_json > "$T/releases.json"

echo "== binary layout"
reset_logs; rm -rf "$T/state/bin"
mkdir -p "$T/usr/bin"
cp "$T/assets/demobin_1.2.3_linux_amd64" "$T/usr/bin/demobin"
cat > "$T/etc/apps.d/bin.conf" <<EOF
SOURCE=github:example/demobin
ASSET='demobin_\${VERSION}_linux_amd64'
VERIFY="api-digest checksums-file"
CHECKSUM_ASSET=checksums.txt
POLICY=patch
LAYOUT=binary
TARGET=$T/usr/bin/demobin
SERVICE=demobin.service
HEALTH_RETRIES=1
HEALTH_DELAY=0
current_version() { "\$TARGET" | awk '{print \$2}'; }
EOF
if [[ "$(uname -m)" != x86_64 ]]; then echo "  (skipping binary tests: not amd64)"; else
check "update exits 0" "$RR" update bin
check "binary is 1.2.4 (patch policy)" test "$("$T/usr/bin/demobin")" = "demobin 1.2.4"
check "pre-relrotate binary kept for rollback" test -x "$T/state/bin/bin/1.2.3/demobin"
check "rollback command" "$RR" rollback bin
check "binary back to 1.2.3" test "$("$T/usr/bin/demobin")" = "demobin 1.2.3"
check "1.2.4 marked as skipped" test "$(cat "$T/state/bin/skip")" = 1.2.4
check "next update skips 1.2.4" bash -c "'$RR' update bin 2>&1 | grep -q 'event=up-to-date'"

echo "== binary flip failure is caught"
reset_logs; rm -rf "$T/state/bin"
cp "$T/assets/demobin_1.2.3_linux_amd64" "$T/usr/bin/demobin"
mkdir -p "$T/usr/bin/demobin.relrotate-new/blocker"
check "update fails when the flip fails" bash -c "! '$RR' update bin 2>/dev/null"
check "binary still 1.2.3" test "$("$T/usr/bin/demobin")" = "demobin 1.2.3"
check "installed state not advanced" test ! -e "$T/state/bin/installed"
check "service not restarted" bash -c "! grep -q restart '$T/log/systemctl'"
rm -rf "$T/usr/bin/demobin.relrotate-new"
fi

echo "== container layout"
reset_logs; rm -rf "$T/state/ctr"
mkdir -p "$T/quadlet"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\nPublishPort=8080:8080\n' > "$T/quadlet/demo.container"
cat > "$T/etc/apps.d/ctr.conf" <<EOF
SOURCE=github:example/demo
POLICY=minor
LAYOUT=container
QUADLET=$T/quadlet/demo.container
IMAGE='ghcr.io/example/demo:\${TAG}'
SERVICE=demo.service
HEALTH_RETRIES=1
HEALTH_DELAY=0
EOF
mkdir -p "$T/state/ctr"; touch "$T/state/ctr/quadlet.1.0.0.demo.container.bak"
check "version read from Image= tag" bash -c "'$RR' check ctr 2>/dev/null | grep -q 'installed *1.2.3'"
check "update exits 0" "$RR" update ctr
check "Image= bumped to v1.3.0" grep -q '^Image=ghcr.io/example/demo:v1.3.0$' "$T/quadlet/demo.container"
check "other quadlet lines untouched" grep -q '^PublishPort=8080:8080$' "$T/quadlet/demo.container"
check "image pulled first" grep -q 'pull --quiet ghcr.io/example/demo:v1.3.0' "$T/log/podman"
check "daemon-reload + restart" bash -c "grep -q daemon-reload '$T/log/systemctl' && grep -q 'restart demo.service' '$T/log/systemctl'"
check "old quadlet backups pruned, previous kept" bash -c "ls '$T/state/ctr'/quadlet.*.bak | grep -q 'quadlet.1.2.3.' && ! ls '$T/state/ctr'/quadlet.1.0.0.* 2>/dev/null"
rm -f "$T/state/ctr"/quadlet.*.bak
check "rollback without a backup" "$RR" rollback ctr
check "Image= rebuilt as TAG_PREFIX + version" grep -q '^Image=ghcr.io/example/demo:v1.2.3$' "$T/quadlet/demo.container"

reset_logs; rm -rf "$T/state/ctr"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet/demo.container"
touch "$T/unhealthy"
check "unhealthy container update fails" bash -c "! '$RR' update ctr 2>/dev/null"
check "quadlet restored to v1.2.3" grep -q '^Image=ghcr.io/example/demo:v1.2.3$' "$T/quadlet/demo.container"

echo "== container flip failure is caught"
reset_logs; rm -rf "$T/state/ctr"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet/demo.container"
touch "$T/fail-reload-once"
check "update fails when daemon-reload fails" bash -c "! '$RR' update ctr 2>/dev/null"
check "quadlet back on v1.2.3" grep -q '^Image=ghcr.io/example/demo:v1.2.3$' "$T/quadlet/demo.container"
check "installed state not advanced" test ! -e "$T/state/ctr/installed"
check "no temp quadlet left" test ! -e "$T/quadlet/demo.container.relrotate-new"
check "mail: failed before install" grep -q 'failed before install' "$T/log/mail"
check "service not restarted" bash -c "! grep -q restart '$T/log/systemctl'"

reset_logs; rm -rf "$T/state/ctr"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet/demo.container"
touch "$T/fail-reload"
check "update fails when daemon-reload keeps failing" bash -c "! '$RR' update ctr 2>/dev/null"
check "mail does not claim nothing changed" bash -c "! grep -q 'failed before install' '$T/log/mail'"
check "mail: rollback failed" grep -q 'ROLLBACK FAILED' "$T/log/mail"

echo "== bz2 single-file binary"
reset_logs; rm -rf "$T/state/bz"
cp "$T/assets/demobin_1.2.3_linux_amd64" "$T/usr/bin/demobz"
cat > "$T/etc/apps.d/bz.conf" <<EOF
SOURCE=github:example/demobin
ASSET='demobin_\${VERSION}_linux_amd64.bz2'
VERIFY=checksums-file
CHECKSUM_ASSET=checksums.txt
POLICY=minor
LAYOUT=binary
TARGET=$T/usr/bin/demobz
current_version() { "\$TARGET" | awk '{print \$2}'; }
healthcheck() { [[ "\$("\$TARGET")" == "demobin \$VERSION" ]]; }
HEALTH_RETRIES=1
HEALTH_DELAY=0
EOF
if [[ "$(uname -m)" != x86_64 ]]; then echo "  (skipping: not amd64)"; else
check "bz2 update exits 0" "$RR" update bz
check "binary unpacked from .bz2 is 1.3.0" test "$("$T/usr/bin/demobz")" = "demobin 1.3.0"
check "binary is executable" test -x "$T/usr/bin/demobz"
fi

echo "== multi-container set (Immich style)"
multi_reset() {
    reset_logs; rm -rf "$T/state/multi"
    printf '[Container]\nImage=ghcr.io/example/server:v1.2.3\n' > "$T/quadlet/server.container"
    printf '[Container]\nImage=ghcr.io/example/ml:v1.2.3\n' > "$T/quadlet/ml.container"
}
cat > "$T/etc/apps.d/multi.conf" <<EOF
SOURCE=github:example/demo
POLICY=minor
LAYOUT=container
CONTAINERS=(
    '$T/quadlet/server.container|ghcr.io/example/server:\${TAG}'
    '$T/quadlet/ml.container|ghcr.io/example/ml:\${TAG}'
)
SERVICE="ml.service server.service"
HEALTH_RETRIES=1
HEALTH_DELAY=0
EOF
multi_reset
check "version read from first quadlet" bash -c "'$RR' check multi 2>/dev/null | grep -q 'installed *1.2.3'"
check "update exits 0" "$RR" update multi
check "server bumped to v1.3.0" grep -q '^Image=ghcr.io/example/server:v1.3.0$' "$T/quadlet/server.container"
check "ml bumped to v1.3.0" grep -q '^Image=ghcr.io/example/ml:v1.3.0$' "$T/quadlet/ml.container"
check "both services restarted, in order" \
    bash -c "grep restart '$T/log/systemctl' | tr '\n' ' ' | grep -q 'restart ml.service.*restart server.service'"
check "one daemon-reload for the whole set" test "$(grep -c daemon-reload "$T/log/systemctl")" = 1

multi_reset
echo "ghcr.io/example/ml:v1.3.0" > "$T/fail-pull"
check "failed pull of 2nd image fails the update" bash -c "! '$RR' update multi 2>/dev/null"
check "server quadlet untouched after failed pull" grep -q '^Image=ghcr.io/example/server:v1.2.3$' "$T/quadlet/server.container"
check "no daemon-reload after failed pull" bash -c "! grep -q daemon-reload '$T/log/systemctl' 2>/dev/null"

multi_reset
touch "$T/unhealthy"
check "unhealthy set fails" bash -c "! '$RR' update multi 2>/dev/null"
check "server rolled back" grep -q '^Image=ghcr.io/example/server:v1.2.3$' "$T/quadlet/server.container"
check "ml rolled back" grep -q '^Image=ghcr.io/example/ml:v1.2.3$' "$T/quadlet/ml.container"

multi_reset
touch "$T/fail-reload-once"
check "set: failed daemon-reload fails the update" bash -c "! '$RR' update multi 2>/dev/null"
check "set: server quadlet restored" grep -q '^Image=ghcr.io/example/server:v1.2.3$' "$T/quadlet/server.container"
check "set: ml quadlet restored" grep -q '^Image=ghcr.io/example/ml:v1.2.3$' "$T/quadlet/ml.container"
check "set: mail says nothing changed" grep -q 'failed before install' "$T/log/mail"

echo "== 0.x versions: minor policy means patches only"
jq -n '[ {tag_name:"v0.6.0",assets:[]}, {tag_name:"v0.5.2",assets:[]}, {tag_name:"v0.5.1",assets:[]} ]' > "$T/releases-zero.json"
printf '[Container]\nImage=docker.io/example/zero:v0.5.1\n' > "$T/quadlet/zero.container"
cat > "$T/etc/apps.d/zero.conf" <<EOF
SOURCE=github:example/zero
POLICY=minor
LAYOUT=container
QUADLET=$T/quadlet/zero.container
IMAGE='docker.io/example/zero:\${TAG}'
EOF
got="$(STUB_RELEASES="$T/releases-zero.json" "$RR" check zero 2>/dev/null | awk '$1=="candidate"{print $2}')"
check "0.5.1 + POLICY=minor picks 0.5.2, not 0.6.0 (got $got)" test "$got" = 0.5.2
sed -i 's/^POLICY=minor/POLICY=major/' "$T/etc/apps.d/zero.conf"
got="$(STUB_RELEASES="$T/releases-zero.json" "$RR" check zero 2>/dev/null | awk '$1=="candidate"{print $2}')"
check "0.5.1 + POLICY=major picks 0.6.0 (got $got)" test "$got" = 0.6.0
rm -f "$T/etc/apps.d/zero.conf"

echo "== release sources"
reset_logs
echo dummy-token > "$T/etc/gitea.token"
echo "GITEA_TOKEN_FILE=$T/etc/gitea.token" >> "$T/etc/relrotate.conf"
printf 'SOURCE=gitea:https://git.example/owner/repo\nPOLICY=minor\nLAYOUT=container\nQUADLET=%s\nIMAGE=x\n' \
    "$T/quadlet/demo.container" > "$T/etc/apps.d/gt.conf"
check "gitea check runs" bash -c "'$RR' check gt 2>/dev/null | grep -q 'newest *2.0.0'"
check "gitea API URL" grep -q 'https://git.example/api/v1/repos/owner/repo/releases?limit=30' "$T/log/curl"
check "gitea token header sent on stdin" grep -q 'Authorization: token REDACTED' "$T/log/curl-config"
check "token not on the curl command line" bash -c "! grep -q dummy-token '$T/log/curl'"
reset_logs
"$RR" check web >/dev/null 2>&1
check "github API URL" grep -q 'https://api.github.com/repos/example/demo/releases?per_page=30' "$T/log/curl"
check "plain relrotate User-Agent sent" grep -q -- '-A relrotate/' "$T/log/curl"
check "no github token header without a token file" bash -c "! grep -q Authorization '$T/log/curl' '$T/log/curl-config'"
printf 'SOURCE=gitea:git.example/owner/repo\nLAYOUT=container\nQUADLET=x\nIMAGE=x\n' > "$T/etc/apps.d/badsrc.conf"
"$RR" check badsrc >/dev/null 2>&1 && rc=0 || rc=$?
check "malformed gitea SOURCE is exit 2 (got $rc)" test "$rc" = 2
rm -f "$T/etc/apps.d/gt.conf" "$T/etc/apps.d/badsrc.conf"

echo "== config errors"
printf 'SOURCE=github:a/b\nASSET=x\nLAYOUT=binary\nTARGET=/tmp/x\n' > "$T/etc/apps.d/noverify.conf"
"$RR" check noverify >/dev/null 2>&1 && rc=0 || rc=$?
check "missing VERIFY is exit 2 (got $rc)" test "$rc" = 2
printf 'SOURCE=github:a/b\nLAYOUT=rpm\n' > "$T/etc/apps.d/badlayout.conf"
"$RR" check badlayout >/dev/null 2>&1 && rc=0 || rc=$?
check "unknown LAYOUT is exit 2 (got $rc)" test "$rc" = 2
rm -f "$T/etc/apps.d/badlayout.conf"
"$RR" update ../etc >/dev/null 2>&1 && rc=0 || rc=$?
check "path-like app name rejected (got $rc)" test "$rc" = 2
check "status lists apps" bash -c "'$RR' status | grep -q '^web '"

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 ))
