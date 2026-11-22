#!/usr/bin/env bash
# Synthetic end-to-end tests for relrotate. No root, no network:
# releases are a JSON file, assets are file:// URLs, systemctl/podman/sendmail
# are stubs that log what they were asked to do.
set -Eeuo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
RR="$here/../relrotate"

# ------------------------------------------------------- scrubbed re-exec ---
# Run under env -i with a fake HOME and a PATH of stubs plus symlinks to the
# few host tools needed, so no test reaches a real systemctl, podman, sudo,
# package manager or the network, and ~/.curlrc and XDG_* are never read.
# The inner run is recognised by a token only the outer run knows, so a
# RELROTATE_TEST_T left in the caller's environment cannot skip the scrub
# (or point the cleanup trap at someone else's directory).
if [[ -z "${RELROTATE_TEST_T:-}" || -z "${RELROTATE_TEST_TOKEN:-}" \
      || "$(cat "$RELROTATE_TEST_T/.token" 2>/dev/null)" != "$RELROTATE_TEST_TOKEN" ]]; then
    T="$(mktemp -d)"
    mkdir -p "$T/bin" "$T/sysbin" "$T/home"
    token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s\n' "$token" > "$T/.token"
    for t in bash env awk basename bzip2 cat chmod chown cmp cp curl cut date dirname find flock \
             grep gzip head id install jq ln ls mkdir mkfifo mktemp mv readlink rm sed sha256sum sleep \
             sort stat tail tar tee timeout touch tr uname uniq wc xargs; do
        p="$(type -P "$t" || true)"
        [[ -n "$p" ]] || { echo "tests/run.sh: required tool not found: $t" >&2; rm -rf "$T"; exit 2; }
        ln -s "$p" "$T/sysbin/$t"
    done
    # Optional: tests skip or relrotate reports when absent.
    for t in xz zstd unzip zip gpgv hostname sqlite3; do
        p="$(type -P "$t" || true)"
        [[ -z "$p" ]] || ln -s "$p" "$T/sysbin/$t"
    done
    real_curl="$(readlink -f "$T/sysbin/curl")"
    rm "$T/sysbin/curl"   # only the wrapper below may call it, by absolute path
    exec env -i KEEP_T="${KEEP_T:-}" HOME="$T/home" LANG=C.UTF-8 TZ=UTC PATH="$T/bin:$T/sysbin" \
        RELROTATE_TEST_T="$T" RELROTATE_TEST_TOKEN="$token" RELROTATE_TEST_CURL="$real_curl" \
        "$BASH" "$0" "$@"
fi
T="$RELROTATE_TEST_T"
umask 022   # the doctor tests expect ordinary file modes
# KEEP_T=1 tests/run.sh keeps the scratch directory for debugging.
if [[ -n "${KEEP_T:-}" ]]; then echo "keeping $T" >&2; else trap 'rm -rf "$T"' EXIT; fi

# Preflight: nothing that can change the host or reach out may resolve outside
# the stubs. Stubs of the same name (systemctl, podman, runuser, curl) are fine.
for t in sudo su dnf yum apt-get npm pip wget ssh nc systemctl podman runuser curl; do
    p="$(type -P "$t" || true)"
    if [[ -n "$p" && "$p" != "$T/bin/"* ]]; then
        echo "tests/run.sh: refusing to start: $t resolves to $p, outside the stubs" >&2
        exit 2
    fi
done
[[ "$HOME" == "$T/home" ]] || { echo "tests/run.sh: refusing to start: HOME is not the fake home" >&2; exit 2; }

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# ----------------------------------------------------------------- stubs ---
mkdir -p "$T/log"
cat > "$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$T/log/systemctl"
if [[ "\${1:-}" == cat ]]; then cat "$T/units/\$2" 2>/dev/null; exit; fi   # systemctl cat UNIT
if [[ " \$* " == *" is-active "* ]]; then [[ ! -e "$T/unhealthy" ]]; exit; fi
# fail-restart: empty fails every restart, a unit name fails only that unit
if [[ " \$* " == *" restart "* ]]; then [[ ! -e "$T/fail-restart" ]] || [[ -s "$T/fail-restart" && " \$* " != *" \$(cat "$T/fail-restart") "* ]]; exit; fi
if [[ " \$* " == *"able --now "* ]]; then [[ ! -e "$T/fail-enable" ]]; exit; fi
if [[ " \$* " == *" daemon-reload "* ]]; then
    if [[ -e "$T/fail-reload-once" ]]; then rm -f "$T/fail-reload-once"; exit 1; fi
    [[ ! -e "$T/fail-reload" ]]; exit
fi
EOF
cat > "$T/bin/podman" <<EOF
#!/usr/bin/env bash
echo "podman \$*" >> "$T/log/podman"
if [[ -e "$T/fail-tag" && " \$* " == *" tag "* ]]; then exit 1; fi
if [[ -s "$T/fail-pull" && " \$* " == *" \$(cat "$T/fail-pull") "* ]]; then exit 1; fi
# image inspect: a digest derived from the image name, and from whether this
# name was pulled since (a pull moves a tag); no-digest: none
img="\${@: -1}"; mark="$T/pulled-\$(printf '%s' "\$img" | tr '/:@' '___')"
if [[ " \$* " == *" pull "* ]]; then touch "\$mark"; fi
if [[ " \$* " == *" image inspect "* ]]; then
    [[ ! -e "$T/no-digest" ]] || exit 125
    s=""; [[ ! -e "\$mark" ]] || s=+pulled
    printf 'sha256:%s\n' "\$(printf '%s' "\$img\$s" | sha256sum | cut -c1-64)"
fi
if [[ " \$* " == *" image exists "* ]]; then [[ ! -e "$T/image-gone" ]]; exit; fi
if [[ " \$* " == *" exec "* ]]; then   # pg_dumpall in a container
    [[ ! -e "$T/fail-dump" ]] || exit 1
    [[ -e "$T/empty-dump" ]] || echo "-- PostgreSQL database cluster dump"
    exit 0
fi
if [[ " \$* " == *" pull "*"@sha256:"* ]]; then [[ ! -e "$T/image-gone" ]]; exit; fi
exit 0
EOF
# runuser -u USER -- CMD...: logged, then CMD runs (as the test user).
cat > "$T/bin/runuser" <<EOF
#!/usr/bin/env bash
echo "runuser \$*" >> "$T/log/runuser"
[[ "\$1" == -u && "\$3" == -- ]] || exit 64
shift 3; exec "\$@"
EOF
# Release API requests are answered from $STUB_RELEASES; file:// URLs go
# to the real curl by absolute path, with -q (~/.curlrc ignored) and
# --proto =file, so no URL from the arguments, a --config or a guessed
# scheme can reach the network. relrotate's own "--proto X", "--proto-redir X"
# and "--" arguments are dropped (the wrapper imposes =file itself); a proto
# setting arriving in a --config on stdin, which could widen that again, is
# refused. Arguments are logged as given; a --config - on stdin is logged to
# curl-config with Authorization values redacted and then handed on to the
# real curl.
real_curl="$RELROTATE_TEST_CURL"
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "curl \$*" >> "$T/log/curl"
cfg=""
if [[ " \$* " == *" --config - "* ]]; then
    cfg="\$(cat)"
    sed -E 's/(Authorization: [A-Za-z]+) [^"]+/\1 REDACTED/' <<<"\$cfg" >> "$T/log/curl-config"
fi
if [[ "\$(grep -Ev '^(data-raw|header) = ' <<<"\$cfg")" =~ (^|[[:space:]])-*proto ]]; then
    echo "curl stub: refusing a proto setting in --config" >> "$T/log/curl"; exit 2
fi
args=()
while (( \$# )); do
    case "\$1" in
        --proto|--proto-redir) shift ;;
        --) ;;
        *) args+=("\$1") ;;
    esac
    shift
done
url="\${args[\${#args[@]}-1]}"
# A notification: its URL arrives only in the config; logged above, never fetched.
# fail-notify: every notification fails; fail-notify-url: only those whose URL holds its text.
# The body of a notification arrives as a data-raw entry of the config: curl's
# unescaping is applied to it (unquote.awk) and the exact bytes land in
# log/body-last, and one per line in log/bodies. A delivered one is recorded in
# log/sent: its URL line, its arguments and its body on one line.
if [[ "\$cfg" == "url = "* && "\$url" != file://* ]]; then
    grep '^data-raw = ' <<<"\$cfg" | awk -f "$T/unquote.awk" > "$T/log/body-last"
    { cat "$T/log/body-last"; echo; } >> "$T/log/bodies"
    [[ ! -e "$T/fail-notify" ]] || exit 1
    [[ ! -s "$T/fail-notify-url" || "\$cfg" != *"\$(cat "$T/fail-notify-url")"* ]] || exit 1
    body="\$(<"$T/log/body-last")"
    printf '%s %s %s\n' "\${cfg%%\$'\n'*}" "\${args[*]//\$'\n'/ }" "\${body//\$'\n'/ }" >> "$T/log/sent"
    exit
fi
if [[ "\$url" == file://* ]]; then
    exec "$real_curl" -q --proto =file --proto-redir =file "\${args[@]}" <<<"\$cfg"
fi
cat "\${STUB_RELEASES:-$T/releases.json}"
EOF
cat > "$T/unquote.awk" <<'AWK'
# the value of one `data-raw = "..."` line, unescaped as curl's config parser does
{
    sub(/^data-raw = "/, ""); sub(/"$/, ""); n = length($0); out = ""
    for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") {
            d = substr($0, ++i, 1)
            c = (d == "n") ? "\n" : (d == "t") ? "\t" : (d == "r") ? "\r" : (d == "v") ? "\v" : d
        }
        out = out c
    }
    printf "%s", out
}
AWK
cat > "$T/bin/sendmail" <<EOF
#!/usr/bin/env bash
cat >> "$T/log/mail"; echo "----" >> "$T/log/mail"
EOF
chmod +x "$T/bin/"*
echo "== test harness"
echo '[]' > "$T/releases.json"
check "curl wrapper fetches a file:// URL" "$T/bin/curl" -fs -o /dev/null "file://$T/releases.json"
check "curl wrapper refuses a non-file URL from --config (protocol disabled, rc 1)" bash -c "printf 'url = \"http://127.0.0.1:9/\"\\n' | '$T/bin/curl' -fs --fail-early -o /dev/null -o /dev/null --config - 'file://$T/releases.json' 2>/dev/null; test \$? = 1"
check "curl wrapper refuses a proto setting in --config (rc 2)" bash -c "printf 'proto = \"=all\"\\n' | '$T/bin/curl' -fs -o /dev/null --config - 'file://$T/releases.json'; test \$? = 2"
check "curl wrapper drops relrotate's own --proto, --proto-redir and --" "$T/bin/curl" -fs -o /dev/null --proto =https --proto-redir =https -- "file://$T/releases.json"
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

reset_logs() { rm -f "$T/log/"* "$T/healthz" "$T/unhealthy" "$T/fail-pull" "$T/fail-reload" "$T/fail-reload-once" "$T/fail-restart" "$T/fail-notify" "$T/fail-notify-url" "$T/no-digest" "$T/image-gone" "$T"/pulled-* "$T/fail-dump" "$T/empty-dump" "$T/fail-tag"; }

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

echo "== candidate already live, state behind (after a failed rollback)"
# The new release is live while state still names the old one, so the next
# run picks the live version again. Staging it would rm -rf the directory
# the symlink serves.
reset_logs; web_install_old; web_recipe minor api-digest
mkdir -p "$T/www/demo-releases/1.3.0/logs" "$T/state/web"
echo "demo 1.3.0" > "$T/www/demo-releases/1.3.0/VERSION"
echo "live" > "$T/www/demo-releases/1.3.0/logs/live.log"
ln -sfn "$T/www/demo-releases/1.3.0" "$T/www/demo"
echo 1.2.3 > "$T/state/web/installed"
check "update refuses" bash -c "! '$RR' update web 2>/dev/null"
check "symlink still on 1.3.0" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.3.0"
check "live release dir untouched" test -s "$T/www/demo-releases/1.3.0/logs/live.log"
check "no restart" bash -c "! grep -q restart '$T/log/systemctl' 2>/dev/null"
check "state still 1.2.3" test "$(cat "$T/state/web/installed")" = 1.2.3
check "last-result says refused" grep -q 'refused: 1.3.0 already live, state says 1.2.3' "$T/state/web/last-result"
check "mail says adopt" grep -q 'relrotate adopt web 1.3.0' "$T/log/mail"

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
# serve $T/assets/demo-1.3.0.$1 as the 1.3.0 asset; recipe gets EXTRACT=$2 ("" = auto)
unsafe_asset() {
    web_recipe minor none
    printf "ASSET='demo-\${VERSION}.%s'\n" "$1" >> "$T/etc/apps.d/web.conf"
    [[ -z "$2" ]] || echo "EXTRACT=$2" >> "$T/etc/apps.d/web.conf"
    releases_json | jq --arg a "demo-1.3.0.$1" --arg u "file://$T/assets/demo-1.3.0.$1" \
        'map(.assets |= map(if .name == "demo-1.3.0.tar.gz" then .name = $a | .browser_download_url = $u else . end))' \
        > "$T/releases.json"
}
unsafe_untouched() { test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3" && test ! -e "$T/www/x"; }
tar -czf "$T/assets/demo-1.3.0.bin" -C "$T/evil" --transform 's|^|../../|' x 2>/dev/null
web_install_old; unsafe_asset bin tgz
# GNU tar and unzip already skip ../ members; the log line proves our check refused it first
check "extensionless asset with EXTRACT=tgz refuses ../" bash -c "! '$RR' update web 2>'$T/log/err' && grep -q 'unsafe path' '$T/log/err'"
check "  nothing changed" unsafe_untouched
printf 'not a tarball' > "$T/assets/demo-1.3.0.tar.gz"
web_install_old; unsafe_asset tar.gz ""
check "corrupt .tar.gz is refused" bash -c "! '$RR' update web 2>'$T/log/err' && grep -q 'cannot list archive' '$T/log/err'"
check "  nothing changed" unsafe_untouched
mkdir -p "$T/evil2"; ln -s /etc "$T/evil2/link"; echo y > "$T/evil2/ok"
tar -czf "$T/assets/demo-1.3.0.tar.gz" -C "$T" evil2
web_install_old; unsafe_asset tar.gz ""
check "symlink member to absolute target is refused" bash -c "! '$RR' update web 2>'$T/log/err' && grep -q 'unsafe symlink' '$T/log/err'"
check "  nothing changed" unsafe_untouched
check "  refused tree removed" test ! -e "$T/www/demo-releases/1.3.0.relrotate-new"
mkdir -p "$T/evil3/sub"; ln -s ../../../outside "$T/evil3/sub/up"; echo y > "$T/evil3/ok"
tar -czf "$T/assets/demo-1.3.0.tar.gz" -C "$T" evil3
web_install_old; unsafe_asset tar.gz ""
check "symlink member escaping with .. is refused" bash -c "! '$RR' update web 2>'$T/log/err' && grep -q 'unsafe symlink' '$T/log/err'"
check "  nothing changed" unsafe_untouched
mkdir -p "$T/good/demo/a" "$T/good/demo/c"; echo c > "$T/good/demo/c/f"; ln -s ../c "$T/good/demo/a/b"
printf 'odd\n' > "$T/good/demo/x -> ..y"
tar -czf "$T/assets/demo-1.3.0.tar.gz" -C "$T/good" demo
web_install_old; unsafe_asset tar.gz ""
check "internal relative symlink and a ' -> ' file name are accepted" bash -c "'$RR' update web >/dev/null 2>&1 && test \"\$(cat '$T/www/demo/a/b/f')\" = c"
# A directory name ending in a newline must not hide an escaping link.
nl=$'\n'; rm -rf "$T/evil5"; mkdir -p "$T/evil5/top/a/b/c/e" "$T/evil5/top/d$nl"
ln -s a/b/c/e "$T/evil5/top/d"; ln -s ../../.. "$T/evil5/top/d$nl/ln"; echo y > "$T/evil5/top/ok"
tar -czf "$T/assets/demo-1.3.0.tar.gz" -C "$T/evil5" top
web_install_old; unsafe_asset tar.gz ""
check "escaping link under a newline-ended dir name is refused" bash -c "! '$RR' update web 2>'$T/log/err' && grep -q 'unsafe symlink' '$T/log/err'"
check "  nothing changed" unsafe_untouched
# A member written through a symlink extracted just before it must not land outside.
rm -rf "$T/evil6" "$T/outside-dir"; mkdir -p "$T/evil6/s1/top" "$T/evil6/s2/top/link" "$T/outside-dir"
ln -s "$T/outside-dir" "$T/evil6/s1/top/link"; echo pwn > "$T/evil6/s2/top/link/pwn"
tar -cf "$T/evil6/a.tar" -C "$T/evil6/s1" top && tar -rf "$T/evil6/a.tar" -C "$T/evil6/s2" top/link/pwn
gzip -c "$T/evil6/a.tar" > "$T/assets/demo-1.3.0.tar.gz"
web_install_old; unsafe_asset tar.gz ""
check "member written through an earlier symlink is refused" bash -c "! '$RR' update web 2>/dev/null"
check "  nothing landed outside" test ! -e "$T/outside-dir/pwn"
check "  nothing changed" unsafe_untouched
# Hardlink members whose stored target is absolute or ../: GNU tar strips
# both on extraction, so the link cannot reach a file outside the release.
echo secret > "$T/outside"; mkdir -p "$T/evil4"; rm -f "$T/evil4/h"; ln "$T/outside" "$T/evil4/h"
tar -czPf "$T/assets/demo-1.3.0.tar.gz" --transform "s|^$T/outside\$|top/zz|rSH;s|^$T/evil4/h\$|top/h|rSH" "$T/outside" "$T/evil4/h" 2>/dev/null
web_install_old; unsafe_asset tar.gz ""
"$RR" update web >/dev/null 2>&1 || true
check "hardlink member to an absolute target stays inside" test "$(find "$T/www" -samefile "$T/outside" | wc -l)" = 0
( cd "$T/evil4" && tar -czPf "$T/assets/demo-1.3.0.tar.gz" --transform 's|^\.\./outside$|top/zz|rSH;s|^h$|top/h|rSH' ../outside h 2>/dev/null )
web_install_old; unsafe_asset tar.gz ""
"$RR" update web >/dev/null 2>&1 || true
check "hardlink member to a ../ target stays inside" test "$(find "$T/www" -samefile "$T/outside" | wc -l)" = 0
if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    mkdir -p "$T/zips"; ln -s /etc "$T/zips/link"; echo z > "$T/zips/ok"
    rm -f "$T/assets/demo-1.3.0.zip"; ( cd "$T/zips" && zip -qy "$T/assets/demo-1.3.0.zip" link ok )
    web_install_old; unsafe_asset zip ""; echo STRIP_COMPONENTS=0 >> "$T/etc/apps.d/web.conf"
    check "zip symlink to an absolute target is refused" bash -c "! '$RR' update web 2>'$T/log/err' && grep -q 'unsafe symlink' '$T/log/err'"
    check "  nothing changed" unsafe_untouched
    rm -rf "$T/zipw" "$T/outside-dir"; mkdir -p "$T/zipw/s1" "$T/zipw/s2/link" "$T/outside-dir"
    ln -s "$T/outside-dir" "$T/zipw/s1/link"; echo pwn > "$T/zipw/s2/link/pwn"
    rm -f "$T/assets/demo-1.3.0.zip"
    ( cd "$T/zipw/s1" && zip -qy "$T/assets/demo-1.3.0.zip" link ) && ( cd "$T/zipw/s2" && zip -q "$T/assets/demo-1.3.0.zip" link/pwn )
    web_install_old; unsafe_asset zip ""; echo STRIP_COMPONENTS=0 >> "$T/etc/apps.d/web.conf"
    check "zip member written through an earlier symlink is refused" bash -c "! '$RR' update web 2>/dev/null"
    check "  nothing landed outside" test ! -e "$T/outside-dir/pwn"
    rm -f "$T/assets/demo-1.3.0.zip"
fi
if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    mkdir -p "$T/zipb/a/b"; echo z > "$T/zipb/a/x"
    ( cd "$T/zipb/a/b" && zip -q "$T/assets/demo-1.3.0.zip" ../x )
    web_install_old; unsafe_asset zip ""
    check "zip with ../ is refused" bash -c "! '$RR' update web 2>'$T/log/err' && grep -q 'unsafe path' '$T/log/err'"
    check "  nothing changed" unsafe_untouched
else echo "  (skipping zip test: zip/unzip missing)"; fi
rm -f "$T"/assets/demo-1.3.0.{bin,zip}
make_tarball 1.3.0; releases_json > "$T/releases.json"

echo "== pruning keeps KEEP versions, prereleases included"
reset_logs; web_install_old; web_recipe minor none; echo KEEP=1 >> "$T/etc/apps.d/web.conf"
mkdir -p "$T/www/demo-releases/1.1.0" "$T/www/demo-releases/1.2.3-bak"
check "update with KEEP=1 exits 0" "$RR" update web
check "without ALLOW_PRERELEASE a hand-made 1.2.3-bak dir is left alone" bash -c "test -d '$T/www/demo-releases/1.2.3-bak' && test ! -e '$T/www/demo-releases/1.1.0'"
reset_logs; web_install_old; web_recipe minor none; printf 'KEEP=1\nALLOW_PRERELEASE=yes\n' >> "$T/etc/apps.d/web.conf"
mkdir -p "$T/www/demo-releases/1.1.0" "$T/www/demo-releases/1.1.0-rc1" "$T/www/demo-releases/1.0.0-rc2"
check "update with KEEP=1 and prereleases exits 0" "$RR" update web
check "old prerelease dirs are pruned too" bash -c "test ! -e '$T/www/demo-releases/1.1.0-rc1' && test ! -e '$T/www/demo-releases/1.0.0-rc2' && test ! -e '$T/www/demo-releases/1.1.0'"
check "current and previous are kept" bash -c "test -d '$T/www/demo-releases/1.3.0' && test -d '$T/www/demo-releases/1.2.3'"

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
check "mail: rollback incomplete" grep -q 'ROLLBACK INCOMPLETE' "$T/log/mail"

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

echo "== container backups: same basename, revert outcome"
reset_logs; rm -rf "$T/state/dup" "$T/quadlet/a" "$T/quadlet/b"; mkdir -p "$T/quadlet/a" "$T/quadlet/b"
printf '[Container]\nImage=ghcr.io/example/one:v1.2.3\n' > "$T/quadlet/a/app.container"
printf '[Container]\nImage=ghcr.io/example/two:v1.2.3\n' > "$T/quadlet/b/app.container"
cat > "$T/etc/apps.d/dup.conf" <<EOF
SOURCE=github:example/demo
POLICY=minor
LAYOUT=container
CONTAINERS=(
    '$T/quadlet/a/app.container|ghcr.io/example/one:\${TAG}'
    '$T/quadlet/b/app.container|ghcr.io/example/two:\${TAG}'
)
SERVICE=demo.service
HEALTH_RETRIES=1
HEALTH_DELAY=0
EOF
check "dup basenames: update exits 0" "$RR" update dup
check "dup basenames: one backup per quadlet" test "$(find "$T/state/dup" -name "quadlet.1.2.3.*.bak" | wc -l)" = 2
check "dup basenames: rollback exits 0" "$RR" rollback dup
check "dup basenames: first quadlet back on its own image" grep -q '^Image=ghcr.io/example/one:v1.2.3$' "$T/quadlet/a/app.container"
check "dup basenames: second quadlet back on its own image" grep -q '^Image=ghcr.io/example/two:v1.2.3$' "$T/quadlet/b/app.container"

reset_logs; rm -rf "$T/state/ctr"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet/demo.container"
"$RR" update ctr >/dev/null 2>&1
for f in "$T/state/ctr"/quadlet.1.2.3.*.bak; do echo '# from-0.2.0-backup' >> "$f"; mv "$f" "$T/state/ctr/quadlet.1.2.3.demo.container.bak"; done
check "0.2.0-style backup name is found on rollback" bash -c "'$RR' rollback ctr && grep -q from-0.2.0-backup '$T/quadlet/demo.container'"

reset_logs; rm -rf "$T/state/dup"
printf '[Container]\nImage=ghcr.io/example/one:v1.2.3\n' > "$T/quadlet/a/app.container"
printf '[Container]\nImage=ghcr.io/example/two:v1.2.3\n' > "$T/quadlet/b/app.container"
"$RR" update dup >/dev/null 2>&1
rm -f "$T/state/dup"/quadlet.1.2.3.*.bak
printf '[Container]\nImage=ghcr.io/example/one:v1.2.3\n# shared-0.2.0-backup\n' > "$T/state/dup/quadlet.1.2.3.app.container.bak"
check "shared 0.2.0 backup: rollback exits 0" "$RR" rollback dup
check "shared 0.2.0 backup not used for same-named quadlets" bash -c "! grep -q shared-0.2.0-backup '$T/quadlet/a/app.container' '$T/quadlet/b/app.container'"
check "shared 0.2.0 backup: each image rebuilt from its own template" bash -c "grep -q '^Image=ghcr.io/example/one:v1.2.3$' '$T/quadlet/a/app.container' && grep -q '^Image=ghcr.io/example/two:v1.2.3$' '$T/quadlet/b/app.container'"

reset_logs; rm -rf "$T/state/ctr"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet/demo.container"
"$RR" update ctr >/dev/null 2>&1
new="$(cat "$T/state/ctr/installed")"
touch "$T/fail-reload"
check "manual rollback: daemon-reload failure exits non-zero" bash -c "! '$RR' rollback ctr 2>/dev/null"
check "manual rollback: quadlet is on v1.2.3" grep -q '^Image=ghcr.io/example/demo:v1.2.3$' "$T/quadlet/demo.container"
check "manual rollback: installed/previous/skip untouched" bash -c "grep -qx '$new' '$T/state/ctr/installed' && grep -qx 1.2.3 '$T/state/ctr/previous' && test ! -e '$T/state/ctr/skip'"
check "manual rollback: incomplete marker names 1.2.3" grep -qx 1.2.3 "$T/state/ctr/incomplete"
check "manual rollback: last-result says INCOMPLETE" grep -q 'INCOMPLETE' "$T/state/ctr/last-result"
check "manual rollback: not reported as nothing switched" bash -c "! grep -q 'still live' '$T/state/ctr/last-result' '$T/log/mail'"
check "manual rollback: mail says INCOMPLETE" grep -q 'rollback to 1.2.3 INCOMPLETE' "$T/log/mail"
rm -f "$T/log/podman"; cp "$T/state/ctr/last-result" "$T/last-result.before"
check "update is blocked while a rollback is incomplete" bash -c "! '$RR' update ctr 2>/dev/null"
check "  blocked update pulled nothing and kept last-result" bash -c "test ! -e '$T/log/podman' && [[ \"\$(cat '$T/last-result.before')\" == \"\$(cat '$T/state/ctr/last-result')\" ]]"
mv "$T/quadlet/demo.container" "$T/quadlet/demo.container.keep"
ln -s "$T/nonexistent/demo.container" "$T/quadlet/demo.container"   # the retry's copy fails
check "retry that changes nothing exits non-zero" bash -c "! '$RR' rollback ctr 2>/dev/null"
check "  says the retry changed nothing, marker kept" bash -c "grep -q 'retry changed nothing' '$T/state/ctr/last-result' && grep -qx 1.2.3 '$T/state/ctr/incomplete'"
check "  mail: still INCOMPLETE, not 'still live'" bash -c "grep -q 'still INCOMPLETE' '$T/log/mail' && ! grep -q 'still live' '$T/log/mail'"
rm -f "$T/quadlet/demo.container"; mv "$T/quadlet/demo.container.keep" "$T/quadlet/demo.container"
rm -f "$T/fail-reload"
check "rollback again after the fix exits 0" "$RR" rollback ctr
check "  now recorded: installed 1.2.3, previous and skip $new" bash -c "grep -qx 1.2.3 '$T/state/ctr/installed' && grep -qx '$new' '$T/state/ctr/previous' && grep -qx '$new' '$T/state/ctr/skip'"
check "  incomplete marker cleared" test ! -e "$T/state/ctr/incomplete"
echo 1.2.3 > "$T/state/ctr/incomplete"
check "adopt clears the incomplete marker" bash -c "'$RR' adopt ctr 1.2.3 >/dev/null && test ! -e '$T/state/ctr/incomplete'"

multi_reset
"$RR" update multi >/dev/null 2>&1
new="$(cat "$T/state/multi/installed")"
rm -f "$T/quadlet/ml.container"; ln -s "$T/nonexistent/ml.container" "$T/quadlet/ml.container"   # copy back fails
check "manual rollback: copy failure part-way exits non-zero" bash -c "! '$RR' rollback multi 2>/dev/null"
check "manual rollback: first quadlet was restored" grep -q '^Image=ghcr.io/example/server:v1.2.3$' "$T/quadlet/server.container"
check "manual rollback: partial revert keeps installed" grep -qx "$new" "$T/state/multi/installed"
check "manual rollback: partial revert last-result" grep -q 'INCOMPLETE' "$T/state/multi/last-result"
rm -f "$T/quadlet/ml.container"
check "partial revert retried after the fix" bash -c "'$RR' rollback multi >/dev/null && grep -q '^Image=ghcr.io/example/ml:v1.2.3$' '$T/quadlet/ml.container' && grep -qx 1.2.3 '$T/state/multi/installed'"

reset_logs; rm -rf "$T/state/ctr2"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet/demo.container"
{ cat "$T/etc/apps.d/ctr.conf"; echo "post_flip() { touch '$T/fail-reload'; return 1; }"; } > "$T/etc/apps.d/ctr2.conf"
check "automatic rollback: daemon-reload failure exits non-zero" bash -c "! '$RR' update ctr2 2>/dev/null"
check "automatic rollback: quadlet is on v1.2.3" grep -q '^Image=ghcr.io/example/demo:v1.2.3$' "$T/quadlet/demo.container"
check "automatic rollback: last-result says ROLLBACK INCOMPLETE" grep -q "ROLLBACK INCOMPLETE" "$T/state/ctr2/last-result"
check "automatic rollback: last-result not 'nothing changed'" bash -c "! grep -q 'nothing changed' '$T/state/ctr2/last-result'"
check "automatic rollback: installed not advanced, marker names 1.2.3" bash -c "test ! -e '$T/state/ctr2/installed' && grep -qx 1.2.3 '$T/state/ctr2/incomplete'"
check "automatic rollback: next update is blocked" bash -c "! '$RR' update ctr2 2>/dev/null"
check "  good 1.2.3 backup not overwritten" bash -c "grep -q '^Image=ghcr.io/example/demo:v1.2.3$' '$T/state/ctr2'/quadlet.1.2.3.*.bak"
rm -f "$T/fail-reload"
check "rollback finishes the automatic rollback" "$RR" rollback ctr2
check "  finished: marker cleared, installed 1.2.3, nothing skipped" bash -c "test ! -e '$T/state/ctr2/incomplete' && grep -qx 1.2.3 '$T/state/ctr2/installed' && test ! -e '$T/state/ctr2/skip' && grep -q 'finished rollback to 1.2.3' '$T/state/ctr2/last-result'"
rm -f "$T/etc/apps.d/ctr2.conf"

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
check "gitea API URL" grep -q 'https://git.example/api/v1/repos/owner/repo/releases?limit=50' "$T/log/curl"
check "gitea token header sent on stdin" grep -q 'Authorization: token REDACTED' "$T/log/curl-config"
check "token not on the curl command line" bash -c "! grep -q dummy-token '$T/log/curl'"
reset_logs
"$RR" check web >/dev/null 2>&1
check "github API URL" grep -q 'https://api.github.com/repos/example/demo/releases?per_page=100' "$T/log/curl"
check "plain relrotate User-Agent sent" grep -q -- '-A relrotate/' "$T/log/curl"
check "no github token header without a token file" bash -c "! grep -q Authorization '$T/log/curl' '$T/log/curl-config'"
printf 'SOURCE=gitea:git.example/owner/repo\nLAYOUT=container\nQUADLET=x\nIMAGE=x\n' > "$T/etc/apps.d/badsrc.conf"
"$RR" check badsrc >/dev/null 2>&1 && rc=0 || rc=$?
check "malformed gitea SOURCE is exit 2 (got $rc)" test "$rc" = 2
rm -f "$T/etc/apps.d/gt.conf" "$T/etc/apps.d/badsrc.conf"

echo "== release sources: failures are recorded and mailed once"
echo '' > "$T/rel-empty.json"
echo 'not json' > "$T/rel-garbage.json"
jq -n '[ {tag_name:"nightly-2",assets:[]}, {tag_name:"nightly-1",assets:[]} ]' > "$T/rel-notags.json"
echo '[]' > "$T/rel-none.json"
reset_logs; web_install_old; web_recipe minor api-digest
STUB_RELEASES="$T/rel-empty.json" "$RR" update web >/dev/null 2>&1 && rc=0 || rc=$?
check "empty response: update exits 1 (got $rc)" test "$rc" = 1
check "empty response: last-result says check failed" grep -q '^check failed: .*empty' "$T/state/web/last-result"
check "empty response: mailed" test "$(grep -c 'release check failed' "$T/log/mail")" = 1
STUB_RELEASES="$T/rel-empty.json" "$RR" update web >/dev/null 2>&1 || true
check "second failing run: not mailed again" test "$(grep -c 'release check failed' "$T/log/mail")" = 1
STUB_RELEASES="$T/rel-garbage.json" "$RR" update web >/dev/null 2>&1 || true
check "failure of another kind while failing: still one mail" test "$(grep -c 'release check failed' "$T/log/mail")" = 1
check "update after recovery succeeds" "$RR" update web
check "success overwrites last-result" grep -q '^updated' "$T/state/web/last-result"
STUB_RELEASES="$T/rel-empty.json" "$RR" update web >/dev/null 2>&1 || true
check "a new failure after a success mails again" test "$(grep -c 'release check failed' "$T/log/mail")" = 2
reset_logs; web_install_old
STUB_RELEASES="$T/rel-notags.json" "$RR" update web >/dev/null 2>&1 && rc=0 || rc=$?
check "2 releases, 0 usable: update exits 1 (got $rc)" test "$rc" = 1
check "message names the count and TAG_PREFIX" grep -q "2 releases.*TAG_PREFIX='v'" "$T/state/web/last-result"
check "0 usable: mailed" grep -q 'release check failed' "$T/log/mail"
reset_logs; web_install_old
STUB_RELEASES="$T/rel-none.json" "$RR" update web >/dev/null 2>&1 && rc=0 || rc=$?
check "an empty release list fails loudly (got $rc)" bash -c "test '$rc' = 1 && grep -q '^check failed: .*empty' '$T/state/web/last-result'"
reset_logs; web_install_old
STUB_RELEASES="$T/rel-empty.json" "$RR" check web >/dev/null 2>&1 && rc=0 || rc=$?
check "check on an empty response fails (got $rc)" test "$rc" = 1
check "check records nothing" bash -c "[[ ! -e '$T/state/web/last-result' && ! -e '$T/log/mail' ]]"
STUB_RELEASES="$T/rel-empty.json" "$RR" update -n web >/dev/null 2>&1 || true
check "dry run records nothing" bash -c "[[ ! -e '$T/state/web/last-result' && ! -e '$T/log/mail' ]]"

echo "== release sources: filters and ordering"
src_recipe() {   # policy allow_prerelease
    printf 'SOURCE=github:example/zero\nPOLICY=%s\nALLOW_PRERELEASE=%s\nLAYOUT=container\nQUADLET=%s\nIMAGE=%s\n' \
        "$1" "$2" "$T/quadlet/zero.container" "'docker.io/example/zero:\${TAG}'" > "$T/etc/apps.d/zero.conf"
}
cand_of() { STUB_RELEASES="$1" "$RR" check zero 2>/dev/null | awk '$1=="candidate"{print $2}'; }
newest_of() { STUB_RELEASES="$1" "$RR" check zero 2>/dev/null | awk '$1=="newest"{print $2}'; }
rm -rf "$T/state/zero"; src_recipe minor yes
jq -n '[ {tag_name:"v0.5.2-rc1",prerelease:true,assets:[]}, {tag_name:"v0.5.1",assets:[]} ]' > "$T/rel-rc.json"
check "ALLOW_PRERELEASE=yes selects 0.5.2-rc1" test "$(cand_of "$T/rel-rc.json")" = 0.5.2-rc1
jq -n '[ {tag_name:"v0.5.2",assets:[]}, {tag_name:"v0.5.2-rc1",prerelease:true,assets:[]}, {tag_name:"v0.5.1",assets:[]} ]' > "$T/rel-rc2.json"
mkdir -p "$T/state/zero"; echo 0.5.2-rc1 > "$T/state/zero/installed"
check "installed 0.5.2-rc1 updates to the final 0.5.2" test "$(cand_of "$T/rel-rc2.json")" = 0.5.2
rm -rf "$T/state/zero"; src_recipe minor no
jq -n '[ {tag_name:"v0.5.2-rc1",assets:[]}, {tag_name:"v0.5.1",assets:[]} ]' > "$T/rel-rc3.json"
src_recipe patch yes
jq -n '[ {tag_name:"v0.6.0-rc1",prerelease:true,assets:[]}, {tag_name:"v0.5.2-rc1",prerelease:true,assets:[]}, {tag_name:"v0.5.1",assets:[]} ]' > "$T/rel-rc4.json"
check "POLICY=patch judges rcs by their numeric part (0.5.2-rc1, not 0.6.0-rc1)" test "$(cand_of "$T/rel-rc4.json")" = 0.5.2-rc1
check "version_gt: 1.3.0 > 1.3.0-rc1, not the reverse" bash -c ". '$here/../lib/common.sh'; version_gt 1.3.0 1.3.0-rc1 && ! version_gt 1.3.0-rc1 1.3.0 && version_gt 1.3.0-rc2 1.3.0-rc1"
check "norm_version strips the suffix: 1.3.0-rc1 -> 1.3.0" test "$(bash -c ". '$here/../lib/common.sh'; norm_version 1.3.0-rc1")" = 1.3.0
check "norm_version: 2024.08.1 -> 2024.8.1" test "$(bash -c ". '$here/../lib/common.sh'; norm_version 2024.08.1 2>&1")" = 2024.8.1
check "norm_version: 1.010.0 -> 1.10.0" test "$(bash -c ". '$here/../lib/common.sh'; norm_version 1.010.0")" = 1.10.0
src_recipe major no
jq -n '[ {tag_name:"v0.9.0\n",assets:[]}, {tag_name:null,assets:[]}, {tag_name:"v0.5.2",assets:[]}, {tag_name:"v0.5.1",assets:[]} ]' > "$T/rel-odd.json"
check "a tag with a trailing newline and a null tag_name are skipped (newest 0.5.2)" test "$(newest_of "$T/rel-odd.json")" = 0.5.2
check "expand keeps an & in a value (bash 5.2 patsub_replacement)" test "$(bash -c "shopt -s patsub_replacement 2>/dev/null; . '$here/../lib/common.sh'; VERSION=1.0.0 TAG='a&b' ARCH=x; expand '\${TAG}-\${VERSION}'")" = 'a&b-1.0.0'
rm -f "$T/etc/apps.d/zero.conf"

echo "== state module"
st() { bash -c "set -Eeuo pipefail; STATE_DIR='$T/st'; . '$here/../lib/state.sh'; $1"; }
rm -rf "$T/st"; mkdir -p "$T/st"
# shellcheck disable=SC2016  # expands in the child shell
check "state: nothing set -> not blocked, no held, empty get" st '{ ! state_blocked || exit 1; }; { ! state_has held || exit 1; }; [[ -z "$(state_get held)" ]]'
# shellcheck disable=SC2016  # expands in the child shell
check "state: state_set writes the value, leaves no .tmp" st 'state_set skip 1.2.3; [[ "$(state_get skip)" == 1.2.3 ]]; [[ -z "$(ls "$STATE_DIR"/*.tmp 2>/dev/null)" ]]'
# shellcheck disable=SC2016  # expands in the child shell
check "state: incomplete blocks and names the version; held and unhealthy answer too" st 'state_set incomplete 1.0.0; state_set held why; state_set unhealthy 1.1.0; [[ "$(state_blocked)" == 1.0.0 ]]; state_has held; [[ "$(state_get unhealthy)" == 1.1.0 ]]'
# shellcheck disable=SC2016  # expands in the child shell
check "state: state_clear removes markers, absent ones are fine" st 'state_clear incomplete held nothing-here; { ! state_blocked || exit 1; }; { ! state_has held || exit 1; }; state_has unhealthy'
rm -rf "$T/st"

echo "== layout seam: a fourth adapter drives the transaction"
# lt 'adapter overrides' 'asserts': layout.sh dispatches by LAYOUT=fake; the
# steps around the layout are stubbed, notify lands in $STATE_DIR/alert.
lt() {
    bash -c "set -Eeuo pipefail; LIB_DIR='$here/../lib'; STATE_DIR='$T/lt'; rm -rf \"\$STATE_DIR\"; mkdir -p \"\$STATE_DIR\"
        . '$here/../lib/state.sh'; . '$here/../lib/outcome.sh'; . '$here/../lib/layout.sh'; . '$here/../lib/transaction.sh'
        log() { :; }; notify() { printf '%s\n' \"\$1\" > \"\$STATE_DIR/alert\"; }
        run_hook() { HOOK_RC=0; }; restart_service() { :; }; run_healthcheck() { HEALTHY=1; }
        doctor_ok() { echo \"ok \$1\"; }; doctor_note() { :; }; doctor_bad() { echo \"bad \$1\"; }
        layout_fake_validate() { :; }; layout_fake_needs_download() { return 1; }
        layout_fake_stage() { :; }; layout_fake_flip() { :; }; layout_fake_prune() { :; }; layout_fake_sweep() { :; }
        layout_fake_revert() { echo \"\$1\" > \"\$STATE_DIR/reverted\"; }
        layout_fake_doctor() { doctor_ok fake-paths; }
        LAYOUT=fake APP=a VERSION=2.0 OLD_VERSION=1.0 DRY_RUN=0 TARGET=/t RELEASE_DIR=/t/2.0 POLICY=minor
        $1; $2"
}
# shellcheck disable=SC2016  # expands in the child shell
{
check "seam: layout_known and doctor dispatch to the adapter" lt ':' 'layout_known; [[ "$(layout doctor)" == "ok fake-paths" ]]'
check "seam: stage 3 records already live, exits 1, flips nothing" lt 'layout_fake_stage() { return 3; }; layout_fake_flip() { touch "$STATE_DIR/flipped"; }; state_set installed 1.0' '{ ! ( transaction_apply ) >/dev/null 2>&1 || exit 1; }; [[ "$(state_get last-result)" == "refused: 2.0 already live, state says 1.0" ]]; [[ "$(state_get alert)" == "2.0 is already live, state says 1.0" ]]; [[ ! -e "$STATE_DIR/flipped" && ! -e "$STATE_DIR/reverted" ]]; [[ "$(state_get installed)" == 1.0 ]]'
check "seam: stage 1 is a plain failure, nothing changed" lt 'layout_fake_stage() { return 1; }' '{ ! ( transaction_apply ) >/dev/null 2>&1 || exit 1; }; [[ "$(state_get last-result)" == "failed 2.0 (staging failed), nothing changed" ]]'
check "seam: flip 2 reverts through the adapter" lt 'layout_fake_flip() { return 2; }' '{ ! ( transaction_apply ) >/dev/null 2>&1 || exit 1; }; [[ "$(cat "$STATE_DIR/reverted")" == 1.0 ]]; [[ "$(state_get last-result)" == "failed 2.0 (flip failed half-way), rolled back to 1.0" ]]'
check "seam: a good flip installs" lt 'state_set installed 1.0' '( transaction_apply ) >/dev/null 2>&1; [[ "$(state_get installed)" == 2.0 ]]; [[ "$(state_get last-result)" == "updated 1.0 -> 2.0" ]]'
}
rm -rf "$T/lt"

echo "== outcome module: the table of revert results"
# oc 'REVERT_*=... state...' 'function' 'asserts': fresh STATE_DIR, notify and
# log stubbed; the alert title lands in $STATE_DIR/alert, the record in last-result.
oc() {
    bash -c "set -Eeuo pipefail; STATE_DIR='$T/oc'; rm -rf \"\$STATE_DIR\"; mkdir -p \"\$STATE_DIR\"
        . '$here/../lib/state.sh'; . '$here/../lib/outcome.sh'
        log() { :; }; commit_result() { state_set last-result \"\$1\"; }
        notify() { printf '%s\n' \"\$1\" > \"\$STATE_DIR/alert\"; }
        APP=a VERSION=2.0 OLD_VERSION=1.0
        $1; $2; $3"
}
rv='REVERT_SWITCHED=1 REVERT_INCOMPLETE=0 REVERT_UNHEALTHY=0 REVERT_PROBLEMS='
# shellcheck disable=SC2016  # expands in the child shell
{
check "update revert, clean: rolled back, no markers, healthy" oc "$rv; state_set unhealthy 9" 'outcome_update_reverted why' '[[ "$(state_get last-result)" == "failed 2.0 (why), rolled back to 1.0" ]]; [[ "$(state_get alert)" == "FAILED 2.0, rolled back to 1.0" ]]; { ! state_has unhealthy || exit 1; }; { ! state_blocked || exit 1; }'
check "update revert, hook problem only: not unhealthy, not blocked" oc "$rv'on_rollback hook failed'" 'outcome_update_reverted why' '[[ "$(state_get last-result)" == "failed 2.0 (why), rolled back to 1.0; on_rollback hook failed" ]]; [[ "$(state_get alert)" == "FAILED 2.0, rolled back to 1.0 with problems" ]]; { ! state_has unhealthy || exit 1; }; { ! state_blocked || exit 1; }'
check "update revert, health check failed: ROLLBACK ALSO FAILED, unhealthy marked" oc "$rv'restart failed; health check failed'; REVERT_UNHEALTHY=1" 'outcome_update_reverted why' '[[ "$(state_get last-result)" == "failed 2.0 (why), ROLLBACK ALSO FAILED: restart failed; health check failed" ]]; [[ "$(state_get alert)" == "FAILED 2.0 and ROLLBACK FAILED" ]]; [[ "$(state_get unhealthy)" == 1.0 ]]; { ! state_blocked || exit 1; }'
check "update revert, incomplete: blocks updates (flip failed half-way)" oc "$rv'switching back to 1.0 incomplete'; REVERT_INCOMPLETE=1" 'outcome_update_reverted "flip failed half-way"' '[[ "$(state_blocked)" == 1.0 ]]; [[ "$(state_get last-result)" == "failed 2.0 (flip failed half-way), ROLLBACK INCOMPLETE: switching back to 1.0 incomplete; updates blocked until: relrotate rollback a" ]]; [[ "$(state_get alert)" == "FAILED 2.0 and ROLLBACK INCOMPLETE" ]]'
check "update revert, nothing switched: blocks updates, files still on new version" oc "REVERT_SWITCHED=0 REVERT_INCOMPLETE=0 REVERT_UNHEALTHY=0 REVERT_PROBLEMS='switching back to 1.0 failed'" 'outcome_update_reverted why' '[[ "$(state_blocked)" == 1.0 ]]; [[ "$(state_get last-result)" == "failed 2.0 (why), ROLLBACK FAILED, files still (partly) on 2.0: switching back to 1.0 failed; updates blocked until: relrotate rollback a" ]]; [[ "$(state_get alert)" == "FAILED 2.0 and ROLLBACK FAILED" ]]'
check "before the flip: nothing changed, no markers" oc "VERSION=3.0" 'outcome_nothing_changed "staging failed"' '[[ "$(state_get last-result)" == "failed 3.0 (staging failed), nothing changed" ]]; [[ "$(state_get alert)" == "update to 3.0 failed before install" ]]; { ! state_blocked || exit 1; }'
check "rollback, clean: installed/previous/skip move, incomplete cleared, no alert" oc "$rv; state_set incomplete 1.0; state_set installed 2.0" 'outcome_rollback >/dev/null' '[[ "$(state_get installed)" == 1.0 ]]; [[ "$(state_get previous)" == 2.0 ]]; [[ "$(state_get skip)" == 2.0 ]]; { ! state_blocked || exit 1; }; [[ "$(state_get last-result)" == "manual rollback 2.0 -> 1.0" ]]; [[ ! -e "$STATE_DIR/alert" ]]'
check "rollback, finishing an incomplete one (same version): no skip" oc "$rv; VERSION=1.0; state_set incomplete 1.0" 'outcome_rollback >/dev/null' '[[ "$(state_get last-result)" == "finished rollback to 1.0" ]]; { ! state_has skip || exit 1; }; { ! state_blocked || exit 1; }'
check "rollback killed after its first state write: skip already names the version rolled away from" oc "$rv; state_set incomplete 1.0; state_set installed 2.0; n=0; state_set() { n=\$((n+1)); (( n < 2 )) || exit 137; printf '%s\n' \"\$2\" > \"\$STATE_DIR/\$1\"; }" '( outcome_rollback >/dev/null ) || true' '[[ "$(state_get skip)" == 2.0 ]]'
check "rollback, hook problem: switched, healthy, exit 1" oc "$rv'restart failed'" '{ ! outcome_rollback 2>/dev/null || exit 1; }' '[[ "$(state_get installed)" == 1.0 ]]; [[ "$(state_get last-result)" == "manual rollback 2.0 -> 1.0, with problems: restart failed" ]]; [[ "$(state_get alert)" == "manual rollback to 1.0: with problems" ]]; { ! state_has unhealthy || exit 1; }'
check "rollback, health check failed: switched and unhealthy marked" oc "$rv'health check failed'; REVERT_UNHEALTHY=1" '{ ! outcome_rollback 2>/dev/null || exit 1; }' '[[ "$(state_get installed)" == 1.0 ]]; [[ "$(state_get unhealthy)" == 1.0 ]]; [[ "$(state_get last-result)" == "manual rollback 2.0 -> 1.0, UNHEALTHY: health check failed" ]]; [[ "$(state_get alert)" == "manual rollback to 1.0: UNHEALTHY" ]]'
check "rollback, incomplete: installed untouched, updates blocked" oc "$rv'switching back to 1.0 incomplete'; REVERT_INCOMPLETE=1; state_set installed 2.0" '{ ! outcome_rollback 2>/dev/null || exit 1; }' '[[ "$(state_get installed)" == 2.0 ]]; [[ "$(state_blocked)" == 1.0 ]]; [[ "$(state_get alert)" == "manual rollback to 1.0 INCOMPLETE" ]]'
check "rollback, nothing switched: installed untouched, not blocked" oc "REVERT_SWITCHED=0 REVERT_INCOMPLETE=0 REVERT_UNHEALTHY=0 REVERT_PROBLEMS='no such version'; state_set installed 2.0" '{ ! outcome_rollback 2>/dev/null || exit 1; }' '[[ "$(state_get installed)" == 2.0 ]]; { ! state_blocked || exit 1; }; [[ "$(state_get last-result)" == "manual rollback to 1.0 FAILED (no such version); 2.0 still live" ]]; [[ "$(state_get alert)" == "manual rollback to 1.0 FAILED" ]]'
check "rollback, retry that changed nothing: stays blocked" oc "REVERT_SWITCHED=0 REVERT_INCOMPLETE=0 REVERT_UNHEALTHY=0 REVERT_PROBLEMS='no such version'; state_set incomplete 1.0" '{ ! outcome_rollback 2>/dev/null || exit 1; }' '[[ "$(state_blocked)" == 1.0 ]]; [[ "$(state_get alert)" == "manual rollback to 1.0 still INCOMPLETE" ]]'
check "recheck: passes again clears unhealthy, still failing keeps it" oc "state_set unhealthy 1.0; HEALTHY=1" 'outcome_recheck 1.0' '{ ! state_has unhealthy || exit 1; }; [[ "$(state_get alert)" == "1.0 healthy again" ]]; HEALTHY=0; state_set unhealthy 1.0; outcome_recheck 1.0; state_has unhealthy; [[ "$(state_get last-result)" == "still UNHEALTHY: 1.0 fails"* ]]'
}
rm -rf "$T/oc"

echo "== release sources: the asset must exist"
reset_logs; web_install_old; web_recipe minor api-digest
jq '[{tag_name:"v1.4.0",prerelease:false,draft:false,assets:[]}] + .' "$T/releases.json" > "$T/rel-late.json"
STUB_RELEASES="$T/rel-late.json" "$RR" check web >"$T/out" 2>"$T/err" || true
check "newest 1.4.0 has no asset: candidate is 1.3.0" bash -c "grep -q 'candidate *1.3.0' '$T/out'"
check "warning names the version lacking the asset" grep -q 'level=warning.*version=1.4.0' "$T/err"
check "update installs 1.3.0 instead of failing" env STUB_RELEASES="$T/rel-late.json" "$RR" update web
check "  symlink on 1.3.0" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.3.0"

echo "== release sources: tokens and curl arguments"
reset_logs; web_install_old; web_recipe minor api-digest
"$RR" update web >/dev/null 2>&1 || true
check "API call: --proto =https --proto-redir =https -- URL" grep -q -- '--proto =https --proto-redir =https .* -- https://api.github.com/' "$T/log/curl"
check "download: --proto, --proto-redir and -- before the file URL" grep -q -- '--proto =https --proto-redir =https -o .* -- file://' "$T/log/curl"
cp "$T/etc/relrotate.conf" "$T/etc/relrotate.conf.bak"
gt_recipe() { printf 'SOURCE=gitea:%s\nPOLICY=minor\nLAYOUT=container\nQUADLET=%s\nIMAGE=x\n' "$1" "$T/quadlet/demo.container" > "$T/etc/apps.d/gt.conf"; }
reset_logs; gt_recipe http://git.example/owner/repo
"$RR" check gt >/dev/null 2>&1 || true
check "http SOURCE: curl may use http" grep -q -- '--proto =http,https --proto-redir =http,https' "$T/log/curl"
check "http SOURCE: no token sent" bash -c "! grep -q Authorization '$T/log/curl-config'"
reset_logs; gt_recipe https://git.example/owner/repo
echo 'GITEA_TOKEN_HOSTS="other.example"' >> "$T/etc/relrotate.conf"
"$RR" check gt >/dev/null 2>&1 || true
check "GITEA_TOKEN_HOSTS without the host: no token sent" bash -c "! grep -q Authorization '$T/log/curl-config'"
reset_logs
echo 'GITEA_TOKEN_HOSTS="other.example GIT.Example"' >> "$T/etc/relrotate.conf"
"$RR" check gt >/dev/null 2>&1 || true
check "GITEA_TOKEN_HOSTS with the host (any case): token sent" grep -q 'Authorization: token REDACTED' "$T/log/curl-config"
cp "$T/etc/relrotate.conf.bak" "$T/etc/relrotate.conf"
echo "GITEA_TOKEN_FILE=$T/etc/missing.token" >> "$T/etc/relrotate.conf"
"$RR" check gt >/dev/null 2>&1 && rc=0 || rc=$?
check "unreadable token file fails instead of going unauthenticated (got $rc)" test "$rc" = 1
cp "$T/etc/relrotate.conf.bak" "$T/etc/relrotate.conf"; rm -f "$T/etc/relrotate.conf.bak" "$T/etc/apps.d/gt.conf"

echo "== verification details"
# lib_unit SCRIPT: run SCRIPT with the libraries sourced and a one-release list.
lib_unit() {
    ( cd "$T" && bash -c "
        . '$here/../lib/common.sh'; . '$here/../lib/source.sh'; . '$here/../lib/verify.sh'
        SOURCE=github:a/b ARCH=amd64 VERSION=1.0.0 TAG=v1.0.0 APP=u ASSET=a.tgz
        WORK=\$(mktemp -d '$T/u.XXXXXX'); DOWNLOAD=\$WORK/a.tgz; GPG_KEYRING=''
        RELEASES=\$(jq -nc --arg u 'file://$T/assets/demo-1.2.3.tar.gz' \
            '[{tag:\"v1.0.0\",version:\"1.0.0\",assets:[{name:\"a.tgz\",url:\$u},{name:\"a.tgz.asc\",url:\$u}]}]')
        $1" ) >/dev/null 2>&1
}
lib_unit_fails() { ! lib_unit "$@"; }
check "empty VERIFY fails closed" lib_unit_fails 'VERIFY=""; download_and_verify'
check "VERIFY=none still passes (control)" lib_unit 'VERIFY=none; download_and_verify'
rel="$T/keyring-rel.gpg"; : > "$rel"
gpg_stub='gpgv() { return 0; }; VERIFY=gpg;'
check "GPG_KEYRING: an absolute path is accepted (control)" lib_unit "$gpg_stub GPG_KEYRING=$rel; download_and_verify"
check "GPG_KEYRING: a bare name is refused" lib_unit_fails "$gpg_stub touch kr.gpg; GPG_KEYRING=kr.gpg; download_and_verify"
reset_logs; web_install_old; web_recipe minor sha256-sidecar
sc="$T/assets/demo-1.3.0.tar.gz.sha256"; cp "$sc" "$sc.orig"
printf '%s\r\n' "$(cat "$sc.orig")" > "$sc"
check "sidecar with CRLF line ends verifies" "$RR" update web
mv "$sc.orig" "$sc"
reset_logs; web_install_old; web_recipe minor checksums-file; echo "CHECKSUM_ASSET=checksums.txt" >> "$T/etc/apps.d/web.conf"
cp "$T/assets/checksums.txt" "$T/assets/checksums.orig"
printf '%s  ./demo-1.3.0.tar.gz\r\n' "$(sha "$T/assets/demo-1.3.0.tar.gz")" > "$T/assets/checksums.txt"
check "checksums file with CRLF and a ./name entry verifies" "$RR" update web
mv "$T/assets/checksums.orig" "$T/assets/checksums.txt"

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

# Fails without the fix only where neither /usr/sbin/sendmail nor
# /usr/lib/sendmail exists (CI runners; not a host with an MTA).
check "relrotate runs when it has to look for sendmail itself (no MTA: still exit 0)" \
    bash -c "env -u RELROTATE_SENDMAIL '$RR' list >/dev/null"

echo "== install layout: PREFIX/sbin and PREFIX/lib/relrotate"
rm -rf "$T/pfx"; mkdir -p "$T/pfx/sbin" "$T/pfx/lib/relrotate"
cp "$RR" "$T/pfx/sbin/relrotate"; cp "$here"/../lib/*.sh "$T/pfx/lib/relrotate/"
check "relrotate finds PREFIX/lib/relrotate next to PREFIX/sbin (RELROTATE_LIB_DIR unset)" \
    bash -c "unset RELROTATE_LIB_DIR; '$T/pfx/sbin/relrotate' --version | grep -q '^relrotate [0-9]'"
ln -s "$T/pfx/sbin/relrotate" "$T/pfx-link"
check "  also through a symlink" bash -c "unset RELROTATE_LIB_DIR; '$T/pfx-link' --version | grep -q '^relrotate [0-9]'"
check "  RELROTATE_LIB_DIR still wins" bash -c "RELROTATE_LIB_DIR='$T/nowhere' '$T/pfx/sbin/relrotate' --version 2>/dev/null; test \$? != 0"
rm -rf "$T/pfx" "$T/pfx-link"

echo "== CLI parsing"
reset_logs; web_install_old; web_recipe minor api-digest
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
check "unknown option rejected, exit 2" test "$(rc_of "$RR" update web --dryrun)" = 2
check "unknown option: nothing installed" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "unknown option before the command rejected" test "$(rc_of "$RR" --bogus list)" = 2
check "extra argument to update rejected" test "$(rc_of "$RR" update web extra)" = 2
check "extra argument to list rejected" test "$(rc_of "$RR" list extra)" = 2
check "extra argument to status rejected" test "$(rc_of "$RR" status web extra)" = 2
check "adopt -n rejected, exit 2" test "$(rc_of "$RR" adopt web 1.0 -n)" = 2
check "adopt -n wrote no state" test ! -e "$T/state/web/installed"
check "rollback -n rejected" test "$(rc_of "$RR" rollback web -n)" = 2
check "bare relrotate exits 2" test "$(rc_of "$RR")" = 2
check "bare relrotate prints usage on stderr" bash -c "'$RR' 2>&1 >/dev/null | grep -q 'Usage: relrotate'"
check "relrotate help exits 0" test "$(rc_of "$RR" help)" = 0
check "options after the app still work (update web -n)" test "$(rc_of "$RR" update web -n)" = 0

echo "== app names"
cp "$T/etc/apps.d/web.conf" "$T/etc/apps.d/..conf"
cp "$T/etc/apps.d/web.conf" "$T/etc/apps.d/...conf"
check "app name . rejected" test "$(rc_of "$RR" update .)" = 2
check "app name .. rejected" test "$(rc_of "$RR" update ..)" = 2
check "app name .. did not chmod the parent of the state dir" bash -c "find '$T' -maxdepth 0 -perm 700 | grep -q ."
check "status .. rejected" test "$(rc_of "$RR" status ..)" = 2
check "status of a name with a slash rejected" test "$(rc_of "$RR" status ../etc)" = 2
rm -f "$T/etc/apps.d/..conf" "$T/etc/apps.d/...conf"

echo "== numeric settings"
for kv in HEALTH_RETRIES=0 HEALTH_RETRIES=x HEALTH_DELAY=abc HEALTH_DELAY= KEEP=0 KEEP=a1; do
    web_install_old; web_recipe minor api-digest; echo "${kv%%=*}='${kv#*=}'" >> "$T/etc/apps.d/web.conf"
    check "$kv rejected before anything runs, exit 2" test "$(rc_of "$RR" update web)" = 2
    check "$kv: nothing installed" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
done

web_install_old; web_recipe minor api-digest; echo "HEALTH_DELAY=1s" >> "$T/etc/apps.d/web.conf"
check "HEALTH_DELAY=1s (a sleep duration) is accepted" test "$(rc_of "$RR" check web)" = 0
cp "$T/etc/apps.d/web.conf" "$T/etc/apps.d/_web.conf"; cp "$T/etc/apps.d/web.conf" "$T/etc/apps.d/.web.conf"
check "app name starting with _ is accepted" test "$(rc_of "$RR" check _web)" = 0
check "app name starting with . is rejected" test "$(rc_of "$RR" check .web)" = 2
rm -f "$T/etc/apps.d/_web.conf" "$T/etc/apps.d/.web.conf"; web_recipe minor api-digest

echo "== log escaping"
out="$(bash -c ". '$here/../lib/common.sh'; APP=web; log err msg=\$'x\nrelrotate level=err app=evil'" 2>&1)"
check "a newline in a value cannot forge a log line" test "$(wc -l <<<"$out")" = 1
check "newline is escaped as \\n" grep -q 'x\\nrelrotate' <<<"$out"
out="$(bash -c ". '$here/../lib/common.sh'; APP=web; log err msg='a\\nb'" 2>&1)"
check "a literal backslash-n is escaped, so it differs from a newline" grep -qF 'msg=a\\nb' <<<"$out"
out="$(bash -c ". '$here/../lib/common.sh'; APP=web; log err msg=\$'a\rb'" 2>&1)"
check "a carriage return is escaped too" bash -c "[[ '$out' != *$'\r'* ]]"

echo "== lock fd is closed for hooks and sendmail"
reset_logs; web_install_old; web_recipe minor api-digest
cat >> "$T/etc/apps.d/web.conf" <<HOOK
post_extract() { if ( : >&9 ) 2>/dev/null; then echo open > "$T/fd9-hook"; else echo closed > "$T/fd9-hook"; fi; }
HOOK
cat > "$T/sendmail-fd" <<STUB
#!/usr/bin/env bash
if ( : >&9 ) 2>/dev/null; then echo open > "$T/fd9-mail"; else echo closed > "$T/fd9-mail"; fi
cat >/dev/null
STUB
chmod +x "$T/sendmail-fd"
RELROTATE_SENDMAIL="$T/sendmail-fd" "$RR" update web >/dev/null 2>&1 || true
check "hook ran" test -e "$T/fd9-hook"
check "hook does not inherit the lock fd" test "$(cat "$T/fd9-hook")" = closed
check "sendmail does not inherit the lock fd" test "$(cat "$T/fd9-mail")" = closed
rm -f "$T/fd9-hook" "$T/fd9-mail" "$T/sendmail-fd"

echo "== TERM before the flip"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'pre_update() { kill -TERM $$; sleep 1; }' >> "$T/etc/apps.d/web.conf"
check "TERM before the flip exits 143" test "$(rc_of "$RR" update web)" = 143
check "TERM before the flip: symlink unchanged" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "TERM before the flip: last-result says nothing changed" grep -q 'interrupted before install of 1.3.0, nothing changed' "$T/state/web/last-result"
check "TERM before the flip: no incomplete marker" test ! -e "$T/state/web/incomplete"
check "TERM before the flip: work dir cleaned up" bash -c "[[ -z \$(ls -d '$T'/state/web/work.* 2>/dev/null) ]]"

echo "== failures before install: one alert per version and reason"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'pre_update() { false; }' >> "$T/etc/apps.d/web.conf"
for i in 1 2 3; do "$RR" update web >/dev/null 2>&1 || true; done
check "the same failure three times: one alert" test "$(grep -c 'failed before install' "$T/log/mail")" = 1
check "  last-result is still written" grep -q '^failed 1.3.0 (pre_update hook failed), nothing changed' "$T/state/web/last-result"
check "  failed-notified holds version and reason" test "$(cat "$T/state/web/failed-notified")" = "1.3.0 pre_update hook failed"
web_recipe minor api-digest; echo 'post_extract() { false; }' >> "$T/etc/apps.d/web.conf"
"$RR" update web >/dev/null 2>&1 || true
check "a different reason: a second alert" test "$(grep -c 'failed before install' "$T/log/mail")" = 2
web_recipe minor api-digest
check "a successful update" "$RR" update web
check "  clears failed-notified" test ! -e "$T/state/web/failed-notified"
rm -rf "$T/www/demo-releases/1.3.0"; ln -sfn "$T/www/demo-releases/1.2.3" "$T/www/demo"; echo 1.2.3 > "$T/state/web/installed"
echo 'pre_update() { false; }' >> "$T/etc/apps.d/web.conf"
"$RR" update web >/dev/null 2>&1 || true
check "  so the same failure later alerts again" test "$(grep -c 'failed before install' "$T/log/mail")" = 3
reset_logs; web_install_old; web_recipe minor api-digest
echo 'pre_update() { kill -TERM $$; sleep 1; }' >> "$T/etc/apps.d/web.conf"
"$RR" update web >/dev/null 2>&1 || true
check "TERM before the flip: one alert" test "$(grep -c 'INTERRUPTED before install' "$T/log/mail")" = 1
"$RR" update web >/dev/null 2>&1 || true
check "  none for the same interruption again" test "$(grep -c 'INTERRUPTED before install' "$T/log/mail")" = 1
check "  last-result is written each time" grep -q 'interrupted before install of 1.3.0, nothing changed' "$T/state/web/last-result"
reset_logs; web_install_old; web_recipe minor api-digest
jq '(.[] | select(.tag_name=="v1.3.0") | .assets[0].browser_download_url) = "file:///nonexistent/demo.tar.gz"' "$T/releases.json" > "$T/releases-gone.json"
STUB_RELEASES="$T/releases-gone.json" "$RR" update web >/dev/null 2>&1 || true
check "download fails: one alert" test "$(grep -c 'failed before install' "$T/log/mail")" = 1
STUB_RELEASES="$T/releases-bad.json" "$RR" update web >/dev/null 2>&1 || true
check "  the same version failing its checksum instead: a second alert" test "$(grep -c 'failed before install' "$T/log/mail")" = 2
STUB_RELEASES="$T/releases-bad.json" "$RR" update web >/dev/null 2>&1 || true
check "  the same mismatch again: none" test "$(grep -c 'failed before install' "$T/log/mail")" = 2
check "  last-result keeps its text" grep -q '^failed 1.3.0 (download/verification failed), nothing changed' "$T/state/web/last-result"

echo "== TERM after the flip"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'post_flip() { kill -TERM $$; sleep 1; }' >> "$T/etc/apps.d/web.conf"
check "TERM after the flip exits 143" test "$(rc_of "$RR" update web)" = 143
check "TERM after the flip: incomplete names the old version" test "$(cat "$T/state/web/incomplete" 2>/dev/null)" = 1.2.3
check "TERM after the flip: last-result says so" grep -q 'interrupted while switching between 1.2.3 and 1.3.0; updates blocked until: relrotate rollback web' "$T/state/web/last-result"
check "TERM after the flip: mail sent" grep -q 'INTERRUPTED' "$T/log/mail"
check "TERM after the flip: installed still names the old version" test "$(cat "$T/state/web/installed" 2>/dev/null || echo 1.2.3)" = 1.2.3
web_recipe minor api-digest
check "update is blocked after the interrupt" test "$(rc_of "$RR" update web)" = 1
check "update stays blocked: symlink untouched" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.3.0"
check "rollback after the interrupt succeeds" test "$(rc_of "$RR" rollback web)" = 0
check "rollback restores the old version" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "rollback clears the incomplete marker" test ! -e "$T/state/web/incomplete"

echo "== TERM during the flip, after the commit, during a rollback"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'layout_symlink_flip() { kill -TERM $$; sleep 1; }' >> "$T/etc/apps.d/web.conf"   # simulates a signal inside the flip
"$RR" update web >/dev/null 2>&1 || true
check "TERM inside the flip leaves the incomplete marker" test "$(cat "$T/state/web/incomplete" 2>/dev/null)" = 1.2.3
reset_logs; web_install_old; web_recipe minor api-digest
# shellcheck disable=SC2016  # written into the recipe literally
echo 'notify() { [[ "$1" == updated* ]] || return 0; kill -TERM $$; sleep 1; }' >> "$T/etc/apps.d/web.conf"   # a signal during the success mail
check "TERM during the success mail exits 143" test "$(rc_of "$RR" update web)" = 143
check "  the recorded success is not overwritten" grep -q '^updated 1.2.3 -> 1.3.0$' "$T/state/web/last-result"
check "  no incomplete marker" test ! -e "$T/state/web/incomplete"
reset_logs; web_install_old; web_recipe minor api-digest; "$RR" update web >/dev/null 2>&1
echo 'on_rollback() { kill -TERM $$; sleep 1; }' >> "$T/etc/apps.d/web.conf"
check "TERM during a manual rollback exits 143" test "$(rc_of "$RR" rollback web)" = 143
check "  leaves the incomplete marker naming the target" test "$(cat "$T/state/web/incomplete" 2>/dev/null)" = 1.2.3
web_recipe minor api-digest
check "  rollback again finishes it" bash -c "'$RR' rollback web >/dev/null 2>&1 && test ! -e '$T/state/web/incomplete' && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.2.3'"

echo "== unhealthy after a rollback is checked again"
reset_logs; web_install_old; web_recipe minor api-digest; "$RR" update web >/dev/null 2>&1
touch "$T/unhealthy"
check "rollback with a failing health check exits 1" test "$(rc_of "$RR" rollback web)" = 1
check "  unhealthy marker names 1.2.3" test "$(cat "$T/state/web/unhealthy" 2>/dev/null)" = 1.2.3
check "  status shows UNHEALTHY before last=" bash -c "'$RR' status web | sed 's/ last=.*//' | grep -q 'UNHEALTHY(1.2.3)'"
# Only 1.2.3 and the skipped 1.3.0 exist, so these runs have nothing to install.
releases_json | jq '[.[] | select(.tag_name == "v1.2.3" or .tag_name == "v1.3.0")]' > "$T/rel-nonew.json"
export STUB_RELEASES="$T/rel-nonew.json"
rm -f "$T/log/mail"
check "next run, still failing: exit 1" test "$(rc_of "$RR" update web)" = 1
check "  last-result says still UNHEALTHY, not ok" grep -q '^still UNHEALTHY: 1.2.3' "$T/state/web/last-result"
check "  a still-unhealthy run sends no mail" test ! -s "$T/log/mail"
echo '' > "$T/rel-empty2.json"
STUB_RELEASES="$T/rel-empty2.json" "$RR" update web >/dev/null 2>&1 || true
check "  a failed check while unhealthy is mailed" test "$(grep -c 'release check failed' "$T/log/mail")" = 1
"$RR" update web >/dev/null 2>&1 || true
check "  then a good check while still unhealthy: still UNHEALTHY recorded" grep -q '^still UNHEALTHY' "$T/state/web/last-result"
STUB_RELEASES="$T/rel-empty2.json" "$RR" update web >/dev/null 2>&1 || true
check "  a failure after a good check is a new episode: mailed again" test "$(grep -c 'release check failed' "$T/log/mail")" = 2
rm -f "$T/unhealthy" "$T/log/mail"
check "next run, health passes: exit 0" test "$(rc_of "$RR" update web)" = 0
check "  marker cleared, last-result says healthy again" bash -c "test ! -e '$T/state/web/unhealthy' && grep -q '^healthy again: 1.2.3' '$T/state/web/last-result'"
check "  recovery mailed" grep -q '1.2.3 healthy again' "$T/log/mail"
check "  then a plain run records ok" bash -c "'$RR' update web >/dev/null 2>&1 && grep -qx ok '$T/state/web/last-result'"
unset STUB_RELEASES
echo 1.2.3 > "$T/state/web/unhealthy"
check "adopt clears the unhealthy marker" bash -c "'$RR' adopt web 1.2.3 >/dev/null && test ! -e '$T/state/web/unhealthy'"
reset_logs; web_install_old; web_recipe minor api-digest; "$RR" update web >/dev/null 2>&1
echo 'on_rollback() { return 1; }' >> "$T/etc/apps.d/web.conf"
"$RR" rollback web >/dev/null 2>&1 || true
check "rollback where only a hook failed: 'with problems', not UNHEALTHY" bash -c "grep -q 'with problems' '$T/state/web/last-result' && ! grep -q UNHEALTHY '$T/state/web/last-result' && test ! -e '$T/state/web/unhealthy'"
web_recipe minor api-digest

echo "== automatic rollback that leaves the old version unhealthy"
reset_logs; web_install_old; web_recipe minor api-digest; touch "$T/unhealthy"
check "update fails" test "$(rc_of "$RR" update web)" = 1
check "  rolled back, old version marked unhealthy" bash -c "test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.2.3' && test \"\$(cat '$T/state/web/unhealthy')\" = 1.2.3"
rm -f "$T/unhealthy"

echo "== automatic rollback that cannot switch back"
reset_logs; rm -rf "$T/state/ctr3"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet/demo.container"
{ cat "$T/etc/apps.d/ctr.conf"; echo "post_flip() { rm -f '$T/quadlet/demo.container'; ln -s '$T/nonexistent/q' '$T/quadlet/demo.container'; return 1; }"; } > "$T/etc/apps.d/ctr3.conf"
check "update fails" test "$(rc_of "$RR" update ctr3)" = 1
check "  files still on the new version: incomplete marker names 1.2.3" test "$(cat "$T/state/ctr3/incomplete" 2>/dev/null)" = 1.2.3
check "  last-result says files still on 1.3.0" grep -q 'ROLLBACK FAILED, files still (partly) on 1.3.0' "$T/state/ctr3/last-result"
rm -f "$T/quadlet/demo.container"; printf '[Container]\nImage=ghcr.io/example/demo:v1.3.0\n' > "$T/quadlet/demo.container"
sed -i '/^post_flip/d' "$T/etc/apps.d/ctr3.conf"
check "  rollback then finishes it" bash -c "'$RR' rollback ctr3 >/dev/null 2>&1 && grep -q '^Image=ghcr.io/example/demo:v1.2.3$' '$T/quadlet/demo.container' && test ! -e '$T/state/ctr3/incomplete'"
rm -f "$T/etc/apps.d/ctr3.conf"

echo "== mail"
reset_logs; web_install_old; web_recipe minor api-digest
hn="$(readlink -f "$T/sysbin/hostname" 2>/dev/null || true)"
rm -f "$T/sysbin/hostname"
rc=0; "$RR" update web >/dev/null 2>&1 || rc=$?
[[ -z "$hn" ]] || ln -s "$hn" "$T/sysbin/hostname"
check "update succeeds without a hostname command (rc $rc)" test "$rc" = 0
check "mail is sent without a hostname command" grep -q 'updated 1.2.3 -> 1.3.0' "$T/log/mail"
reset_logs; web_install_old
out="$(RELROTATE_SENDMAIL=/nonexistent/sendmail "$RR" update web 2>&1 >/dev/null || true)"
check "MAIL_TO set but no sendmail is a warning" grep -q 'level=warning.*no sendmail' <<<"$out"

echo "== update-all"
rm -rf "$T/etc2" "$T/state/a1" "$T/state/a2"; mkdir -p "$T/etc2/apps.d"
reset_logs; web_install_old; web_recipe minor api-digest
cp "$T/etc/apps.d/web.conf" "$T/etc2/apps.d/a1.conf"
cp "$T/etc/apps.d/web.conf" "$T/etc2/apps.d/a2.conf"
echo 'pre_update() { cat >/dev/null; }' >> "$T/etc2/apps.d/a1.conf"
RELROTATE_CONF_DIR="$T/etc2" "$RR" update-all >/dev/null 2>&1 || true
check "update-all: a1 updated" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.3.0"
check "update-all: a hook reading stdin does not eat the app list (a2 ran)" test -s "$T/state/a2/last-check"
rm -rf "$T/etc2" "$T/state/a1" "$T/state/a2"

echo "== adopt takes the lock"
web_install_old; web_recipe minor api-digest; mkdir -p "$T/state/web"
( exec 9>"$T/state/web/lock"; flock 9; sleep 3 ) &
holder=$!
sleep 0.5
check "adopt refused while update holds the lock" test "$(rc_of "$RR" adopt web 1.2.3)" = 1
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
check "adopt works when the lock is free" test "$(rc_of "$RR" adopt web 1.2.3)" = 0

echo "== hooks stop at their first failing step"
reset_logs; web_install_old; web_recipe minor api-digest
echo "pre_update() { false; touch '$T/after-false'; }" >> "$T/etc/apps.d/web.conf"
check "a failing first step fails pre_update" test "$(rc_of "$RR" update web)" = 1
check "  the step after it did not run" test ! -e "$T/after-false"
check "  nothing installed" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'post_flip() { false; true; }' >> "$T/etc/apps.d/web.conf"
check "a failing middle step in post_flip rolls back" bash -c "! '$RR' update web 2>/dev/null"
check "  back on 1.2.3" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "  last-result names post_flip" grep -q 'post_flip hook failed' "$T/state/web/last-result"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'healthcheck() { false; true; }' >> "$T/etc/apps.d/web.conf"
check "a failing step in healthcheck fails the health check" bash -c "! '$RR' update web 2>/dev/null"
check "  last-result: health check failed" grep -q 'health check failed' "$T/state/web/last-result"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'post_flip() { false; }; on_rollback() { false; true; }' >> "$T/etc/apps.d/web.conf"
"$RR" update web >/dev/null 2>&1 || true
check "a failing step in on_rollback is reported" grep -q 'on_rollback hook failed' "$T/state/web/last-result"
reset_logs; web_install_old; web_recipe minor api-digest
echo "pre_update() { false || true; touch '$T/after-false'; }" >> "$T/etc/apps.d/web.conf"
check "'|| true' lets a step fail on purpose" "$RR" update web
check "  the next step ran" test -e "$T/after-false"
rm -f "$T/after-false"
check "a hook run inside a condition counts as failed (errexit guard)" \
    test "$(bash -c ". '$here/../lib/common.sh'; h() { :; }; if run_hook h; then echo \$HOOK_RC; fi" 2>/dev/null)" = 70
check "a hook run as a statement passes (control)" \
    test "$(bash -c "set -e; . '$here/../lib/common.sh'; h() { :; }; run_hook h; echo \$HOOK_RC" 2>/dev/null)" = 0

echo "== chat notifications"
printf 'https://discord.example/api/webhooks/1/DSECRET\n' > "$T/etc/discord.url"
printf 'TGSECRET\n-100123\n' > "$T/etc/tg"
printf 'https://ntfy.example/NSECRET\n' > "$T/etc/ntfy.url"
printf 'http://127.0.0.1:8099/hook/WSECRET\n' > "$T/etc/hook.url"
cat > "$T/etc/relrotate.conf" <<EOF
MAIL_TO=root@example.net
NOTIFY=(discord:$T/etc/discord.url telegram:$T/etc/tg ntfy:$T/etc/ntfy.url webhook:$T/etc/hook.url)
EOF
reset_logs; web_install_old; web_recipe minor api-digest
rc=0; out="$("$RR" update web 2>&1)" || rc=$?
check "update with NOTIFY destinations succeeds" test "$rc" = 0
check "discord URL handed to curl on stdin" grep -qF 'url = "https://discord.example/api/webhooks/1/DSECRET"' "$T/log/curl-config"
check "telegram bot URL built from the file" grep -qF 'url = "https://api.telegram.org/botTGSECRET/sendMessage"' "$T/log/curl-config"
check "ntfy and a local http webhook too" bash -c "grep -qF 'https://ntfy.example/NSECRET' '$T/log/curl-config' && grep -qF 'http://127.0.0.1:8099/hook/WSECRET' '$T/log/curl-config'"
check "no secret on a curl command line" bash -c "! grep -qE 'DSECRET|TGSECRET|NSECRET|WSECRET' '$T/log/curl'"
# shellcheck disable=SC2016  # $1 expands in the inner shell
check "no secret in the log" bash -c '! grep -qE "DSECRET|TGSECRET|NSECRET|WSECRET" <<<"$1"' _ "$out"
check "discord gets the message as content" grep -qE '^\{"content":"\[relrotate\] [^ ]+ web: updated 1.2.3 -> 1.3.0' "$T/log/bodies"
check "discord mentions are disabled" grep -qF '"allowed_mentions":{"parse":[]}' "$T/log/bodies"
check "telegram gets the chat id" grep -qF '"chat_id":"-100123"' "$T/log/bodies"
check "ntfy gets a Title header, from the config on stdin" grep -qE '^header = "Title: \[relrotate\] [^ ]+ web: updated 1.2.3 -> 1.3.0' "$T/log/curl-config"
check "  and no Title on the curl command line" bash -c "! grep -q Title '$T/log/curl'"
check "webhook gets JSON with host, app and title" grep -qE '"source":"relrotate","host":"[^"]+","app":"web","title":"[^"]+ web: updated 1.2.3 -> 1.3.0"' "$T/log/bodies"
check "https only for https destinations" bash -c "grep -m1 'application/json' '$T/log/curl' | grep -qF -- '--proto =https --proto-redir =https'"
check "http allowed for an http destination" grep -qF -- '--proto =http,https' "$T/log/curl"
check "mail still sent" grep -q 'updated 1.2.3 -> 1.3.0' "$T/log/mail"
reset_logs; web_install_old; touch "$T/fail-notify"
rc=0; out="$("$RR" update web 2>&1)" || rc=$?
check "a destination that fails does not fail the update" test "$rc" = 0
check "  it is a warning" grep -q 'level=warning.*sending notification failed' <<<"$out"
printf 'MAIL_TO=""\nNOTIFY=(discord:%s)\n' "$T/etc/nonexistent" > "$T/etc/relrotate.conf"
reset_logs; web_install_old
out="$("$RR" update web 2>&1)" || true
check "an unreadable destination file is a warning" grep -q 'level=warning.*not readable' <<<"$out"
printf 'ftp://x.example/\n' > "$T/etc/ftp.url"
printf 'NOTIFY=(webhook:%s)\n' "$T/etc/ftp.url" > "$T/etc/relrotate.conf"
reset_logs; web_install_old
out="$("$RR" update web 2>&1)" || true
check "a non-http(s) URL is refused" grep -q 'notify URL must be http' <<<"$out"
printf 'http://discord.example/api/webhooks/1/DSECRET\n' > "$T/etc/discord-http.url"
printf 'NOTIFY=(discord:%s)\n' "$T/etc/discord-http.url" > "$T/etc/relrotate.conf"
reset_logs; web_install_old
out="$("$RR" update web 2>&1)" || true
check "http:// is refused for discord (it carries the secret)" bash -c "grep -q 'notify URL must be https' <<<\"\$1\" && ! grep -q DSECRET '$T/log/curl-config' 2>/dev/null" _ "$out"
printf 'NOTIFY=(slack:/etc/x)\n' > "$T/etc/relrotate.conf"
check "an unknown NOTIFY kind is a config error" test "$(rc_of "$RR" status)" = 2
printf 'NOTIFY=(discord:relative.url)\n' > "$T/etc/relrotate.conf"
check "a relative NOTIFY file is a config error" test "$(rc_of "$RR" status)" = 2
long="$(printf 'x%.0s' {1..3000})"
reset_logs
bash -c ". '$here/../lib/common.sh'; . '$here/../lib/source.sh'; . '$here/../lib/notify.sh'; CURL='$T/bin/curl'; APP=u
    send_chat discord '$T/etc/discord.url' title '$long'" >/dev/null 2>&1
check "a long message is cut below Discord's 2000 characters" \
    bash -c "c=\$(grep -o '\"content\":\"[^\"]*\"' '$T/log/bodies'); (( \${#c} < 2000 )) && grep -qF 'cut; see relrotate status' <<<\"\$c\""
printf 'https://ntfy.example/t\n' > "$T/etc/ntfy2.url"; reset_logs
bash -c ". '$here/../lib/common.sh'; . '$here/../lib/source.sh'; . '$here/../lib/notify.sh'; CURL='$T/bin/curl'; APP=u
    send_chat ntfy '$T/etc/ntfy2.url' title '$long$long'" >/dev/null 2>&1
check "a long ntfy body is cut below its 4096 bytes" \
    bash -c "l=\$(tr '\n' ' ' < '$T/log/bodies'); (( \${#l} < 4000 )) && grep -qF 'cut; see relrotate status' <<<\"\$l\""

echo "== notify adapters and policy"
# Each adapter builds its payload; the secret never leaves via the arguments.
nt() { bash -c ". '$here/../lib/common.sh'; . '$here/../lib/source.sh'; . '$here/../lib/notify.sh'; CURL='$T/bin/curl'; APP=a
    host_name() { echo h; }; x() { local s; printf -v s '%*s' \$1; printf '%s' \"\${s// /x}\"; }; $1" 2>&1; }
printf 'https://d.example/SECRETD\n' > "$T/etc/n-d"; printf 'TOKT\n42\n' > "$T/etc/n-t"
printf 'https://n.example/SECRETN\n' > "$T/etc/n-n"; printf 'http://10.0.0.1/SECRETW\n' > "$T/etc/n-w"
check "discord payload" test "$(nt "notify_discord '$T/etc/n-d' ti bo; printf '%s %s' \"\$NOTIFY_URL\" \"\$NOTIFY_DATA\"")" = \
    'https://d.example/SECRETD {"content":"[relrotate] ti\nbo","allowed_mentions":{"parse":[]}}'
check "telegram payload" test "$(nt "notify_telegram '$T/etc/n-t' ti bo; printf '%s %s' \"\$NOTIFY_URL\" \"\$NOTIFY_DATA\"")" = \
    'https://api.telegram.org/botTOKT/sendMessage {"chat_id":"42","text":"[relrotate] ti\nbo","disable_web_page_preview":true}'
check "ntfy payload: plain body, Title header" test "$(nt "notify_ntfy '$T/etc/n-n' ti bo; printf '%s|%s|%s|%s' \"\$NOTIFY_URL\" \"\$NOTIFY_DATA\" \"\$NOTIFY_CTYPE\" \"\${NOTIFY_HDR[*]}\"")" = \
    'https://n.example/SECRETN|bo|text/plain; charset=utf-8|-H Title: [relrotate] ti'
check "webhook payload" test "$(nt "notify_webhook '$T/etc/n-w' ti bo; printf '%s %s' \"\$NOTIFY_URL\" \"\$NOTIFY_DATA\"")" = \
    'http://10.0.0.1/SECRETW {"source":"relrotate","host":"h","app":"a","title":"ti","body":"bo"}'
# the cut marker adds 28 characters ("\n[cut; see relrotate status]")
check "discord text: 1900 stays, 1901 is cut to 1898" test "$(nt "notify_discord '$T/etc/n-d' ti \"\$(x 1885)\"; jq -r .content <<<\"\$NOTIFY_DATA\" | wc -c")" = 1901 \
    -a "$(nt "notify_discord '$T/etc/n-d' ti \"\$(x 1886)\"; jq -r .content <<<\"\$NOTIFY_DATA\" | wc -c")" = 1899
check "telegram text is cut like discord" test "$(nt "notify_telegram '$T/etc/n-t' ti \"\$(x 3000)\"; jq -r .text <<<\"\$NOTIFY_DATA\" | wc -c")" = 1899
check "ntfy body: 3500 stays, 3501 is cut to 3470 plus marker" test "$(nt "notify_ntfy '$T/etc/n-n' ti \"\$(x 3500)\"; echo \${#NOTIFY_DATA}")" = 3500 \
    -a "$(nt "notify_ntfy '$T/etc/n-n' ti \"\$(x 3501)\"; echo \${#NOTIFY_DATA}")" = 3498
check "webhook body: 60000 stays, 60001 is cut to 59970 plus marker" test "$(nt "notify_webhook '$T/etc/n-w' ti \"\$(x 60000)\"; jq -r '.body|length' <<<\"\$NOTIFY_DATA\"")" = 60000 \
    -a "$(nt "notify_webhook '$T/etc/n-w' ti \"\$(x 60001)\"; jq -r '.body|length' <<<\"\$NOTIFY_DATA\"")" = 59998
reset_logs
nt "send_chat discord '$T/etc/n-d' ti bo; send_chat telegram '$T/etc/n-t' ti bo; send_chat ntfy '$T/etc/n-n' ti bo; send_chat webhook '$T/etc/n-w' ti bo" >/dev/null
check "send_chat: all four kinds reach curl, webhook over http too" test "$(grep -c -- '--config -' "$T/log/curl")" = 4 -a "$(grep -c 'url = ' "$T/log/curl-config")" = 4
check "send_chat: no secret in the curl arguments" bash -c "! grep -qE 'SECRET|TOKT' '$T/log/curl'"
check "send_chat: --proto =http,https for the http webhook only" test "$(grep -c -- '--proto =http,https' "$T/log/curl")" = 1
reset_logs
check "webhook: http:// is accepted" test "$(nt "send_chat webhook '$T/etc/n-w' ti bo && echo ok" 2>/dev/null)" = ok
check "send_chat leaves no URL, token or text behind in the shell" test "$(nt "send_chat webhook '$T/etc/n-w' ti bo; send_chat telegram '$T/etc/n-t' ti bo; echo \"[\${NOTIFY_URL:-}\${NOTIFY_DATA:-}\${NOTIFY_TEXT:-}]\"" 2>/dev/null)" = '[]'
printf 'http://d.example/SECRETD\n' > "$T/etc/n-dh"; printf 'http://n.example/SECRETN\n' > "$T/etc/n-nh"
for k in discord ntfy; do
    reset_logs
    out="$(nt "send_chat $k '$T/etc/n-${k::1}h' ti bo || echo refused")"
    check "$k: http:// is refused, nothing sent, no secret in the message" bash -c "grep -q 'notify URL must be https' <<<\"\$1\" && grep -q refused <<<\"\$1\" && ! grep -q SECRET <<<\"\$1\" && test ! -e '$T/log/curl'" _ "$out"
done
# The payload goes to curl on stdin, not in its arguments, byte for byte.
printf 'a "q" \\ back\nline2\ttab \303\251 \342\202\254 PAYLOADWORD\n' > "$T/nasty"
rm -f "$T/body-expect"
for k in discord telegram ntfy webhook; do
    reset_logs
    nt "B=\"\$(cat '$T/nasty'; printf x)\"; B=\"\${B%x}\"; notify_$k '$T/etc/n-${k::1}' ti \"\$B\"; printf '%s' \"\$NOTIFY_DATA\" > '$T/body-expect'; send_chat $k '$T/etc/n-${k::1}' ti \"\$B\"" >/dev/null
    check "$k: the bytes curl is given as the body are the payload's" cmp -s "$T/body-expect" "$T/log/body-last"
    [[ "$k" != ntfy ]] || check "ntfy: the Title header is in the config, not in the arguments" bash -c "grep -qxF 'header = \"Title: [relrotate] ti\"' '$T/log/curl-config' && ! grep -q Title '$T/log/curl'"
    [[ "$k" != ntfy ]] || check "ntfy: the plain body is the message as it was, quote, backslash, newlines, tab, non-ASCII" cmp -s "$T/nasty" "$T/log/body-last"
    check "$k: no payload text and no chat id in the curl arguments" bash -c "! grep -qE 'PAYLOADWORD|chat_id|content|\"42\"|data-raw' '$T/log/curl'"
done
reset_logs
nt "timeout() { echo \"\$1\" >> '$T/log/timeout'; shift; \"\$@\"; }; MAIL_TO=a@b SENDMAIL='$T/bin/sendmail'; send_chat discord '$T/etc/n-d' ti bo; send_mail ti bo f" >/dev/null
check "a chat send and a mail send each get 20 s" test "$(tr '\n' ' ' < "$T/log/timeout")" = "20 20 "
check "curl's own limits stay inside it" bash -c "grep -q -- '--connect-timeout 10 --max-time 18' '$T/log/curl'"
# The policy is decided in one place: notify and update-all both ask it.
pol() { nt "NOTIFY_POLICY=$1; deliver() { echo \"deliver:\$2\"; }; outbox_add() { echo \"queue:\$2\"; }; notify s1 b info; notify s2 b alert" 2>/dev/null | grep -E '^(deliver|queue)' | tr '\n' ' '; }
check "policy each: both sent" test "$(pol each)" = "deliver:b deliver:b "
check "policy failures: info queued, alert sent" test "$(pol failures)" = "queue:s1 deliver:b "
check "policy digest: both queued" test "$(pol digest)" = "queue:s1 queue:s2 "
check "update-all runs a digest unless policy is each" test "$(nt "NOTIFY_POLICY=each; notify_digest_wanted && echo y; NOTIFY_POLICY=failures; notify_digest_wanted && echo y")" = y
echo 'MAIL_TO=root@example.net' > "$T/etc/relrotate.conf"

echo "== NOTIFY_POLICY and the summary"
rm -f "$T/state/.outbox" "$T/state/.outbox.sending"
printf 'MAIL_TO=root@example.net\nNOTIFY_POLICY=failures\n' > "$T/etc/relrotate.conf"
reset_logs; web_install_old; web_recipe minor api-digest
check "failures: update succeeds" "$RR" update web
check "  no mail for the update" bash -c "! grep -q 'updated 1.2.3' '$T/log/mail' 2>/dev/null"
check "  queued for the summary" grep -q '"subject":"updated 1.2.3 -> 1.3.0"' "$T/state/.outbox"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'pre_update() { false; }' >> "$T/etc/apps.d/web.conf"
"$RR" update web >/dev/null 2>&1 || true
check "failures: a failure is mailed at once" grep -q 'failed before install' "$T/log/mail"
check "  and not queued" bash -c "! grep -q 'failed before install' '$T/state/.outbox'"
reset_logs
check "digest sends the queue" "$RR" digest
check "  as one mail" test "$(grep -c '^Subject:' "$T/log/mail")" = 1
check "  listing the update" grep -q 'web: updated 1.2.3 -> 1.3.0' "$T/log/mail"
# updated + "2.0.0 available" twice (the failed run's fresh state saw it again)
check "  the subject counts the events" grep -qE '^Subject: \[relrotate\] [^ ]+: 3 events$' "$T/log/mail"
check "  the queue is empty afterwards" bash -c "test ! -s '$T/state/.outbox' && test ! -e '$T/state/.outbox.sending'"
reset_logs
check "an empty queue sends nothing" bash -c "'$RR' digest 2>/dev/null && test ! -e '$T/log/mail'"
printf 'MAIL_TO=root@example.net\nNOTIFY_POLICY=digest\n' > "$T/etc/relrotate.conf"
reset_logs; web_install_old; web_recipe minor api-digest
echo 'pre_update() { false; }' >> "$T/etc/apps.d/web.conf"
"$RR" update web >/dev/null 2>&1 || true
check "digest: a failure waits for the summary too" bash -c "test ! -e '$T/log/mail' && grep -q 'failed before install' '$T/state/.outbox'"
printf '#!/usr/bin/env bash\ncat >/dev/null; exit 1\n' > "$T/sendmail-fail"; chmod +x "$T/sendmail-fail"
check "a summary that cannot be sent fails and is kept" \
    bash -c "RELROTATE_SENDMAIL='$T/sendmail-fail' '$RR' digest 2>/dev/null; test \$? = 1 && test -s '$T/state/.outbox.sending'"
check "  and goes out with the next digest" \
    bash -c "'$RR' digest 2>/dev/null && grep -q 'failed before install' '$T/log/mail' && test ! -e '$T/state/.outbox.sending'"
check "  alerts are counted in the subject" grep -qE '^Subject: .*, 1 need attention$' "$T/log/mail"
check "  an alert carries its full text" grep -q '^    relrotate could not update web' "$T/log/mail"
printf '{"t":"x","app":"web","level":"info","subject":"good line","body":""}\n{"t":"torn\n' > "$T/state/.outbox"
reset_logs; rc=0; out="$("$RR" digest 2>&1)" || rc=$?
check "an unreadable queue line is dropped, the rest is sent" bash -c "test $rc = 0 && grep -q 'web: good line' '$T/log/mail'"
check "  with a warning" grep -q 'dropped unreadable summary lines.*lines=1' <<<"$out"
printf 'https://discord.example/api/webhooks/1/DSECRET\n' > "$T/etc/discord.url"
printf 'MAIL_TO=root@example.net\nNOTIFY_POLICY=digest\nNOTIFY=(discord:%s)\n' "$T/etc/discord.url" > "$T/etc/relrotate.conf"
printf '{"t":"x","app":"web","level":"info","subject":"partial","body":""}\n' > "$T/state/.outbox"
reset_logs; touch "$T/fail-notify"
check "mail sent but discord down: the digest fails" test "$(rc_of "$RR" digest)" = 1
rm -f "$T/fail-notify"
check "  the retry reaches discord" bash -c "'$RR' digest 2>/dev/null && test \$(grep -c '\"content\":.*partial' '$T/log/bodies') = 2"
check "  and does not mail again" test "$(grep -c '^Subject:' "$T/log/mail")" = 1
check "  then the batch is gone" bash -c "test ! -e '$T/state/.outbox.sending' && test ! -e '$T/state/.outbox.sending.sent'"
printf '{"t":"x","app":"web","level":"info","subject":"fd","body":""}\n' > "$T/state/.outbox"
printf 'MAIL_TO=root@example.net\nNOTIFY_POLICY=digest\n' > "$T/etc/relrotate.conf"
cat > "$T/sendmail-fd7" <<STUB
#!/usr/bin/env bash
if ( : >&7 ) 2>/dev/null; then echo open > "$T/fd7-mail"; else echo closed > "$T/fd7-mail"; fi
cat >/dev/null
STUB
chmod +x "$T/sendmail-fd7"
RELROTATE_SENDMAIL="$T/sendmail-fd7" "$RR" digest >/dev/null 2>&1 || true
check "sendmail does not inherit the digest lock fd" test "$(cat "$T/fd7-mail" 2>/dev/null)" = closed
rm -f "$T/sendmail-fd7" "$T/fd7-mail"
# A destination that always fails must not hold up the others, nor lose its own events.
printf 'https://ntfy.example/NSECRET\n' > "$T/etc/ntfy.url"
printf 'NOTIFY_POLICY=digest\nNOTIFY=(discord:%s ntfy:%s)\n' "$T/etc/discord.url" "$T/etc/ntfy.url" > "$T/etc/relrotate.conf"
ev_line() { printf '{"t":"x","app":"web","level":"info","subject":"%s","body":""}\n' "$1"; }
sent_to() { grep -F "$1" "$T/log/sent" 2>/dev/null | grep -oE 'web: [a-z]+[0-9]+' | grep -oE '[a-z]+[0-9]+$' | tr '\n' ' ' || true; }
rm -f "$T/state/.outbox" "$T/state/.outbox.sending" "$T/state/.outbox.sending.sent"
reset_logs; printf NSECRET > "$T/fail-notify-url"
{ ev_line ev1; ev_line ev2; } > "$T/state/.outbox"
check "dead destination: the digest fails" test "$(rc_of "$RR" digest)" = 1
{ ev_line ev3; } >> "$T/state/.outbox"
check "  next digest still fails, the queue is folded in" test "$(rc_of "$RR" digest)" = 1
check "  the working destination got each event once, in order" test "$(sent_to DSECRET)" = "ev1 ev2 ev3 "
check "  the queue did not pile up" test ! -s "$T/state/.outbox"
rm -f "$T/fail-notify-url"
check "  the destination back up: the digest succeeds" test "$(rc_of "$RR" digest)" = 0
check "  it got everything it missed, once, in order" test "$(sent_to NSECRET)" = "ev1 ev2 ev3 "
check "  the working one got nothing twice" test "$(sent_to DSECRET)" = "ev1 ev2 ev3 "
check "  all batch files are gone" bash -c "test ! -e '$T/state/.outbox.sending' && test ! -e '$T/state/.outbox.sending.sent'"
reset_logs
{ echo '{}'; echo '{"a":1}'; echo '{"t":"x","app":"web","level":"alert","body":"b"}'; ev_line ev4; } > "$T/state/.outbox"
rc=0; out="$("$RR" digest 2>&1)" || rc=$?
check "lines that are JSON but no event are dropped like torn ones" bash -c "test $rc = 0 && grep -qF '1 event\\n' '$T/log/sent' && ! grep -q 'null null\|need attention' '$T/log/sent' && grep -q 'dropped unreadable summary lines.*lines=3' <<<\"\$1\"" _ "$out"
reset_logs; printf NSECRET > "$T/fail-notify-url"
for i in {1..1005}; do ev_line "c$i"; done > "$T/state/.outbox"
rc=0; out="$("$RR" digest 2>&1)" || rc=$?
check "the cap keeps the newest 1000 events of a failing destination" bash -c "test \$(wc -l < '$T/state/.outbox.sending') = 1000 && head -n1 '$T/state/.outbox.sending' | grep -q '\"c6\"' && tail -n1 '$T/state/.outbox.sending' | grep -q '\"c1005\"'"
check "  and warns that it dropped the oldest" grep -q 'level=warning.*dropped.*events.*dropped=5' <<<"$out"
{ ev_line c1006; } > "$T/state/.outbox"; rm -f "$T/log/sent"; "$RR" digest >/dev/null 2>&1 || true
check "  the destination that works still gets the new event only" test "$(sent_to DSECRET)" = "c1006 "
rm -f "$T/fail-notify-url" "$T/state/.outbox" "$T/state/.outbox.sending" "$T/state/.outbox.sending.sent"
# A .sent left behind without its batch (killed between the two removals) must not swallow new events.
reset_logs
printf '5 discord:%s\n5 ntfy:%s\n' "$T/etc/discord.url" "$T/etc/ntfy.url" > "$T/state/.outbox.sending.sent"
{ ev_line ev1; ev_line ev2; } > "$T/state/.outbox"
check "a stale .sent without a batch: the digest still succeeds" test "$(rc_of "$RR" digest)" = 0
check "  and both destinations got both new events" test "$(sent_to DSECRET)" = "ev1 ev2 " -a "$(sent_to NSECRET)" = "ev1 ev2 "
reset_logs
{ ev_line ev3; } > "$T/state/.outbox.sending"; printf '9 discord:%s\n' "$T/etc/discord.url" > "$T/state/.outbox.sending.sent"
rc=0; out="$("$RR" digest 2>&1)" || rc=$?
check "a count beyond the batch is stale: sent from the start (a duplicate beats a loss), with a warning" bash -c "test $rc = 0 && grep -q 'level=warning.*stale' <<<\"\$1\" && test \"\$(grep -F DSECRET '$T/log/sent' | grep -c ev3)\" = 1" _ "$out"
rm -f "$T/state/.outbox" "$T/state/.outbox.sending" "$T/state/.outbox.sending.sent"
rm -rf "$T/etc2" "$T/state/a1" "$T/state/a2" "$T/state/.outbox"; mkdir -p "$T/etc2/apps.d"
printf 'MAIL_TO=root@example.net\nNOTIFY_POLICY=digest\n' > "$T/etc2/relrotate.conf"
reset_logs; web_install_old; web_recipe minor api-digest
cp "$T/etc/apps.d/web.conf" "$T/etc2/apps.d/a1.conf"; cp "$T/etc/apps.d/web.conf" "$T/etc2/apps.d/a2.conf"
RELROTATE_CONF_DIR="$T/etc2" "$RR" update-all >/dev/null 2>&1 || true
check "update-all with a summary policy: one mail" test "$(grep -c '^Subject:' "$T/log/mail")" = 1
check "  naming both apps" bash -c "grep -q ' a1: ' '$T/log/mail' && grep -q ' a2: ' '$T/log/mail'"
rm -rf "$T/etc2" "$T/state/a1" "$T/state/a2"
printf 'NOTIFY_POLICY=sometimes\n' > "$T/etc/relrotate.conf"
check "an unknown NOTIFY_POLICY is a config error" test "$(rc_of "$RR" status)" = 2
echo 'MAIL_TO=root@example.net' > "$T/etc/relrotate.conf"
rm -f "$T/state/.outbox" "$T/state/.outbox.sending"

echo "== MIN_AGE_DAYS"
jq --arg n "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg o "$(date -u -d '-10 days' +%Y-%m-%dT%H:%M:%SZ)" \
   --arg oo "$(date -u -d '-100 days' +%Y-%m-%dT%H:%M:%SZ)" \
   'map(.published_at = (if .tag_name == "v1.3.0" then $n elif .tag_name == "v1.2.4" then $o else $oo end))' \
   "$T/releases.json" > "$T/rel-dated.json"
reset_logs; web_install_old; web_recipe minor api-digest; echo MIN_AGE_DAYS=3 >> "$T/etc/apps.d/web.conf"
check "a young release waits, the older eligible one installs" \
    bash -c "STUB_RELEASES='$T/rel-dated.json' '$RR' update web 2>/dev/null && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.2.4'"
check "  the wait is recorded" grep -q '^1.3.0 ' "$T/state/web/waiting"
check "  status shows WAITING" bash -c "'$RR' status web | grep -q 'WAITING(1.3.0 until '"
check "  check shows it" bash -c "STUB_RELEASES='$T/rel-dated.json' '$RR' check web 2>/dev/null | grep -q '^waiting *1.3.0 until '"
reset_logs; web_install_old; web_recipe minor api-digest
check "MIN_AGE_DAYS=0 installs at once (control)" \
    bash -c "STUB_RELEASES='$T/rel-dated.json' '$RR' update web 2>/dev/null && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.3.0' && test ! -e '$T/state/web/waiting'"
reset_logs; web_install_old; web_recipe minor api-digest; echo MIN_AGE_DAYS=3 >> "$T/etc/apps.d/web.conf"
out="$("$RR" update web 2>&1)" || true
check "a release without a publish date waits (fails closed)" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
check "  and says why" grep -q 'no usable publish date' <<<"$out"
printf 'MAIL_TO=root@example.net\nMIN_AGE_DAYS=3\n' > "$T/etc/relrotate.conf"
reset_logs; web_install_old; web_recipe minor api-digest
check "a global MIN_AGE_DAYS applies" \
    bash -c "STUB_RELEASES='$T/rel-dated.json' '$RR' update web 2>/dev/null && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.2.4'"
reset_logs; web_install_old; web_recipe minor api-digest; echo MIN_AGE_DAYS=0 >> "$T/etc/apps.d/web.conf"
check "  a recipe overrides it" \
    bash -c "STUB_RELEASES='$T/rel-dated.json' '$RR' update web 2>/dev/null && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.3.0'"
echo 'MAIL_TO=root@example.net' > "$T/etc/relrotate.conf"
web_recipe minor api-digest; echo MIN_AGE_DAYS=3d >> "$T/etc/apps.d/web.conf"
check "MIN_AGE_DAYS must be whole days" test "$(rc_of "$RR" check web)" = 2
web_recipe minor api-digest; echo MIN_AGE_DAYS=08 >> "$T/etc/apps.d/web.conf"
check "MIN_AGE_DAYS with a leading zero is refused, not read as octal" test "$(rc_of "$RR" check web)" = 2
check "a Gitea date with an offset is read" test "$(bash -c ". '$here/../lib/common.sh'; . '$here/../lib/source.sh'; MIN_AGE_DAYS=1
    RELEASES='[{\"version\":\"1.0.0\",\"published\":\"2020-01-01T12:00:00+02:00\"}]'; release_ripe_at 1.0.0")" = 2020-01-02T10:00:00Z

echo "== hold / unhold"
reset_logs; web_install_old; web_recipe minor api-digest
check "hold" "$RR" hold web "db migration"
check "a held update changes nothing and exits 0" \
    bash -c "'$RR' update web 2>/dev/null && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.2.3'"
check "  no release check while held" bash -c "! grep -q api.github.com '$T/log/curl' 2>/dev/null"
check "  status shows HELD with the reason" bash -c "'$RR' status web | grep -q 'HELD(db migration (since '"
check "  check says held" bash -c "'$RR' check web 2>/dev/null | grep -q '^held *db migration'"
check "hold has no --dry-run" test "$(rc_of "$RR" hold web -n)" = 2
check "unhold" "$RR" unhold web
check "  updates run again" bash -c "'$RR' update web 2>/dev/null && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.3.0'"
check "unhold when not held says so" bash -c "'$RR' unhold web | grep -q 'not held'"
check "hold an unknown app fails" test "$(rc_of "$RR" hold nosuch)" = 2

echo "== enable / disable"
reset_logs
check "enable turns the app's timer on" bash -c "'$RR' enable web >/dev/null && grep -qx 'systemctl enable --now relrotate@web.timer' '$T/log/systemctl'"
check "disable turns it off" bash -c "'$RR' disable web >/dev/null && grep -qx 'systemctl disable --now relrotate@web.timer' '$T/log/systemctl'"
touch "$T/fail-enable"
check "a failing systemctl exits 1" test "$(rc_of "$RR" enable web)" = 1
rm -f "$T/fail-enable"
reset_logs
check "enable an unknown app exits 2" test "$(rc_of "$RR" enable nosuch)" = 2
check "  and systemctl is not called" test ! -e "$T/log/systemctl"
check "enable has no --dry-run" test "$(rc_of "$RR" enable web -n)" = 2
check "enable without an app exits 2" test "$(rc_of "$RR" enable)" = 2
check "enable says nothing about notifications when MAIL_TO is set" bash -c "! '$RR' enable web | grep -q 'journal only'"
cp "$T/etc/relrotate.conf" "$T/etc/relrotate.conf.bak"; : > "$T/etc/relrotate.conf"
check "enable without MAIL_TO or NOTIFY points at relrotate.conf" bash -c "'$RR' enable web | grep -q 'journal only.*MAIL_TO or NOTIFY in $T/etc/relrotate.conf'"
check "  disable does not" bash -c "! '$RR' disable web | grep -q 'journal only'"
mv "$T/etc/relrotate.conf.bak" "$T/etc/relrotate.conf"

echo "== setup"
rm -f "$T/etc/discord.url"
cp "$T/etc/relrotate.conf" "$T/etc/relrotate.conf.bak"
check "setup with notifications already set says so" bash -c "'$RR' setup </dev/null | grep -q 'already set'"
check "  and changes nothing" cmp -s "$T/etc/relrotate.conf" "$T/etc/relrotate.conf.bak"
printf '# top\nMAIL_TO=""\nNOTIFY=()\n# end\n' > "$T/etc/relrotate.conf"; cp "$T/etc/relrotate.conf" "$T/etc/empty.conf"
check "setup at end of input changes nothing" bash -c "'$RR' setup </dev/null >/dev/null && cmp -s '$T/etc/relrotate.conf' '$T/etc/empty.conf'"
check "setup answered no twice changes nothing" bash -c "printf 'n\n\n' | '$RR' setup >/dev/null && cmp -s '$T/etc/relrotate.conf' '$T/etc/empty.conf'"
check "setup refuses a URL that is not https (exit 2)" test "$(printf 'n\ny\ndiscord\nhttp://x.example/hook\n' | rc_of "$RR" setup)" = 2
check "  and writes no URL file" test ! -e "$T/etc/discord.url"
check "setup refuses an unknown kind (exit 2)" test "$(printf 'n\ny\nslack\n' | rc_of "$RR" setup)" = 2
check "setup refuses a bad mail address (exit 2)" test "$(printf 'y\nroot example\n' | rc_of "$RR" setup)" = 2
check "  the config is still untouched" cmp -s "$T/etc/relrotate.conf" "$T/etc/empty.conf"
check "setup does not print the URL" bash -c "! printf 'n\ny\nwebhook\nhttps://hook.example/s3cret\n' | '$RR' setup 2>&1 | grep -q s3cret"
cp "$T/etc/empty.conf" "$T/etc/relrotate.conf"; rm -f "$T/etc/webhook.url"
echo old > "$T/etc/discord.url"; chmod 644 "$T/etc/discord.url"   # a leftover, loose file
check "setup with mail and discord" bash -c "printf 'y\nops@example.net\ny\n\nhttps://discord.example/api/webhooks/1/tok\n' | '$RR' setup >/dev/null"
check "  MAIL_TO written in place" bash -c "sed -n 2p '$T/etc/relrotate.conf' | grep -qx 'MAIL_TO=\"ops@example.net\"'"
check "  NOTIFY written in place" bash -c "sed -n 3p '$T/etc/relrotate.conf' | grep -qx 'NOTIFY=(discord:$T/etc/discord.url)'"
check "  other lines kept" bash -c "test \"\$(sed -n '1p;4p' '$T/etc/relrotate.conf' | tr '\n' ' ')\" = '# top # end '"
check "  URL file holds the URL, mode 600" bash -c "test \"\$(cat '$T/etc/discord.url')\" = https://discord.example/api/webhooks/1/tok && test \"\$(stat -c %a '$T/etc/discord.url')\" = 600"
check "  doctor accepts the result" bash -c "'$RR' doctor web 2>&1 | grep -q 'ok    discord destination file readable'"
check "setup has no --dry-run" test "$(rc_of "$RR" setup -n)" = 2
rm -f "$T/etc/discord.url" "$T/etc/webhook.url" "$T/etc/empty.conf"; mv "$T/etc/relrotate.conf.bak" "$T/etc/relrotate.conf"

echo "== large release list"
# headscale's list is 2.5 MB; a per-character bash rewrite of it took minutes.
jq '.[0].body = ("release notes line with words\n" * 85000)' "$T/releases.json" > "$T/releases-big.json"
check "check finishes on a 2.5 MB release list" \
    bash -c "STUB_RELEASES='$T/releases-big.json' timeout 30 '$RR' check web 2>/dev/null | grep -q '^newest'"

echo "== doctor says whether backups are taken"
web_recipe minor api-digest
check "no backup hook: doctor says so" bash -c "'$RR' doctor web 2>&1 | grep -q 'note  no backup hook: updates take no backup'"
echo "pre_update() { backup_sqlite '$T/none.db' db; }" >> "$T/etc/apps.d/web.conf"
check "backup hook: doctor says a backup runs and how to turn it off" \
    bash -c "'$RR' doctor web 2>&1 | grep -q 'note  a hook takes a backup before every update, to .*remove the hook'"
web_recipe minor api-digest

echo "== status --json"
out="$("$RR" status --json)"
check "status --json is one JSON array" jq -e 'type == "array" and length >= 1' <<<"$out"
check "  with the fields of each app" jq -e '.[] | select(.app == "web") | .installed == "1.3.0" and .previous == "1.2.3" and .held == null and (.last_result | startswith("updated"))' <<<"$out"
check "  for one app" bash -c "'$RR' status web --json | jq -e 'length == 1 and .[0].app == \"web\"' >/dev/null"
check "--json is refused for other commands" test "$(rc_of "$RR" list --json)" = 2
check "text status keeps its columns" bash -c "'$RR' status web | grep -qE '^web {14}installed=1\.3\.0 {8}previous=1\.2\.3 {8}last-check=[^ ]+ +last=updated 1\.2\.3 -> 1\.3\.0$'"

echo "== doctor"
rm -rf "$T/etc3"; mkdir -p "$T/etc3/apps.d"; cp "$T/etc/relrotate.conf" "$T/etc3/"
reset_logs; web_install_old; web_recipe minor sha256-sidecar
cp "$T/etc/apps.d/web.conf" "$T/etc3/apps.d/web.conf"
sed "s/^ASSET=.*/ASSET='demo-\${VERSION}-renamed.tar.gz'/" "$T/etc/apps.d/web.conf" > "$T/etc3/apps.d/renamed.conf"
printf 'SOURCE=github:a/b\nLAYOUT=symlink\nHEALTH_RETRIES=0\n' > "$T/etc3/apps.d/broken.conf"
rc=0; out="$(RELROTATE_CONF_DIR="$T/etc3" "$RR" doctor 2>&1)" || rc=$?
check "doctor exits 1 when an app has a problem" test "$rc" = 1
check "  a good recipe: asset found" grep -q 'ok    asset demo-2.0.0.tar.gz in 2.0.0' <<<"$out"
check "  its checksum sidecar too" grep -q 'ok    demo-2.0.0.tar.gz.sha256 in 2.0.0' <<<"$out"
check "  a renamed asset is reported" grep -q 'FAIL  asset demo-2.0.0-renamed.tar.gz not in release 2.0.0' <<<"$out"
check "  a recipe that does not load is reported" grep -q 'FAIL  recipe does not load: .*HEALTH_RETRIES' <<<"$out"
check "  the next update is named" grep -q 'note  next update installs 1.3.0' <<<"$out"
check "  mail is checked" grep -q 'ok    mail to root@example.net' <<<"$out"
check "doctor on a good app exits 0" bash -c "RELROTATE_CONF_DIR='$T/etc3' '$RR' doctor web >/dev/null 2>&1"
: > "$T/empty.json"
out="$(STUB_RELEASES="$T/empty.json" RELROTATE_CONF_DIR="$T/etc3" "$RR" doctor web 2>&1)" || true
check "a failing release check is reported" grep -q 'FAIL  release check fails: .*empty response' <<<"$out"
check "doctor changes no state" bash -c "test ! -e '$T/state/web/check-failed' && test ! -e '$T/state/web/last-result' && test ! -e '$T/state/web/last-check'"
echo "== doctor: permissions of config, recipes, keys and secret files"
# Owned by root, or by the invoking user when the tests run unprivileged; not
# writable by group or others; secret files not readable by them either.
dp_fresh() {
    rm -rf "$T/etc4"; mkdir -p "$T/etc4/apps.d"; chmod 755 "$T/etc4" "$T/etc4/apps.d"
    cp "$T/etc3/relrotate.conf" "$T/etc4/"; cp "$T/etc3/apps.d/web.conf" "$T/etc4/apps.d/"
    chmod 644 "$T/etc4/relrotate.conf" "$T/etc4/apps.d/web.conf"
    printf 'tok\n' > "$T/etc4/tok"; chmod 600 "$T/etc4/tok"
    printf 'ring\n' > "$T/etc4/ring"; chmod 644 "$T/etc4/ring"
}
dp() { rc=0; out="$(RELROTATE_CONF_DIR="$T/etc4" "$RR" doctor web 2>&1)" || rc=$?; }
reset_logs; web_install_old
dp_fresh
printf 'GITHUB_TOKEN_FILE=%s\nNOTIFY=(ntfy:%s)\n' "$T/etc4/tok" "$T/etc4/tok" >> "$T/etc4/relrotate.conf"
printf 'VERIFY="sha256-sidecar gpg"\nGPG_KEYRING=%s\n' "$T/etc4/ring" >> "$T/etc4/apps.d/web.conf"
dp
check "tight modes: no permission finding" bash -c "! grep -E 'FAIL.*(owned by|can write|can read)' <<<\"\$1\"" _ "$out"
check "  the checks are listed" grep -q "ok    recipe $T/etc4/apps.d/web.conf" <<<"$out"
loose() {   # name, command that loosens one thing, the FAIL text expected
    dp_fresh
    printf 'GITHUB_TOKEN_FILE=%s\nNOTIFY=(ntfy:%s)\n' "$T/etc4/tok" "$T/etc4/tok" >> "$T/etc4/relrotate.conf"
    printf 'VERIFY="sha256-sidecar gpg"\nGPG_KEYRING=%s\n' "$T/etc4/ring" >> "$T/etc4/apps.d/web.conf"
    eval "$2"; dp
    check "$1: doctor fails and names the file" bash -c "test $rc = 1 && grep -qF 'FAIL  $3' <<<\"\$1\"" _ "$out"
}
# shellcheck disable=SC2016  # the commands are eval-ed later
{
loose "recipe mode 666" 'chmod 666 "$T/etc4/apps.d/web.conf"' "recipe $T/etc4/apps.d/web.conf: group or others can write"
loose "recipe group-writable" 'chmod 664 "$T/etc4/apps.d/web.conf"' "recipe $T/etc4/apps.d/web.conf: group or others can write"
loose "apps.d mode 777" 'chmod 777 "$T/etc4/apps.d"' "apps.d $T/etc4/apps.d: group or others can write"
loose "config dir mode 777" 'chmod 777 "$T/etc4"' "config dir $T/etc4: group or others can write"
loose "relrotate.conf mode 666" 'chmod 666 "$T/etc4/relrotate.conf"' "relrotate.conf $T/etc4/relrotate.conf: group or others can write"
loose "world-readable token file" 'chmod 644 "$T/etc4/tok"' "token file $T/etc4/tok: group or others can read"
loose "group-readable notify file" 'chmod 640 "$T/etc4/tok"' "notify file $T/etc4/tok: group or others can read"
loose "group-writable keyring" 'chmod 664 "$T/etc4/ring"' "keyring $T/etc4/ring: group or others can write"
# No root-owned file is visible to every sandbox, so the owner is faked: a stat
# shim reports the uid (and mode 644) for every path.
stat_as() { mkdir -p "$T/shim"; printf '#!/bin/sh\necho "%s 644"\n' "$1" > "$T/shim/stat"; chmod +x "$T/shim/stat"; }
dp_fresh
printf 'VERIFY="sha256-sidecar gpg"\nGPG_KEYRING=%s\n' "$T/etc4/ring" >> "$T/etc4/apps.d/web.conf"
stat_as 0
rc=0; out="$(PATH="$T/shim:$PATH" RELROTATE_CONF_DIR="$T/etc4" "$RR" doctor web 2>&1)" || rc=$?
check "root-owned files pass for an unprivileged doctor" bash -c "! grep -q 'owned by' <<<\"\$1\" && grep -q 'ok    keyring $T/etc4/ring' <<<\"\$1\"" _ "$out"
stat_as 4242
rc=0; out="$(PATH="$T/shim:$PATH" RELROTATE_CONF_DIR="$T/etc4" "$RR" doctor web 2>&1)" || rc=$?
check "a file owned by another non-root uid still fails" bash -c "test $rc = 1 && grep -qF 'FAIL  keyring $T/etc4/ring: owned by uid 4242, expected' <<<\"\$1\"" _ "$out"
rm -rf "$T/shim"
loose "recipe that is a symlink to a loose file" 'mv "$T/etc4/apps.d/web.conf" "$T/etc4/real.conf"; chmod 666 "$T/etc4/real.conf"; ln -s "$T/etc4/real.conf" "$T/etc4/apps.d/web.conf"' "recipe $T/etc4/real.conf: group or others can write"
}
check "  and says it is a symlink" grep -q "note  recipe $T/etc4/apps.d/web.conf is a symlink to $T/etc4/real.conf" <<<"$out"
dp_fresh; rm -f "$T/etc4/apps.d/web.conf"; cp "$T/etc3/apps.d/web.conf" "$T/etc4/apps.d/web.conf"; chmod 644 "$T/etc4/apps.d/web.conf"
dp
check "no token, keyring or notify file configured: nothing to complain about" bash -c "test $rc = 0 && ! grep -qE 'token file|keyring|notify file' <<<\"\$1\"" _ "$out"
rm -rf "$T/etc4"

# doctor and the update path share lib/verify.sh's method list: a release
# missing what a method needs is flagged by one and refused by the other.
echo "== doctor and update agree on VERIFY"
check "verify_known takes one method, never a list or an empty value" bash -c ". '$here/../lib/verify.sh'; verify_known gpg && { ! verify_known 'api-digest sha256-sidecar' || exit 1; } && { ! verify_known '' || exit 1; }"
jq -n --arg u "file://$T/assets/demo-1.3.0.tar.gz" '[{tag_name:"v2.0.0",prerelease:false,draft:false,assets:[{name:"demo-2.0.0.tar.gz",browser_download_url:$u}]}]' > "$T/rel-bare.json"
agree() {   # method [extra recipe line]: doctor output in $out, update rc in $urc, its log in $T/log/err
    web_install_old; web_recipe major "$1"; [[ -z "${2:-}" ]] || echo "$2" >> "$T/etc/apps.d/web.conf"
    cp "$T/etc/apps.d/web.conf" "$T/etc3/apps.d/web.conf"; rm -f "$T/etc3/apps.d/"{renamed,broken}.conf
    out="$(STUB_RELEASES="$T/rel-bare.json" RELROTATE_CONF_DIR="$T/etc3" "$RR" doctor web 2>&1)" || true
    urc=0; STUB_RELEASES="$T/rel-bare.json" "$RR" update web >/dev/null 2>"$T/log/err" || urc=$?
}
for m in $(bash -c ". '$here/../lib/verify.sh'; echo \$VERIFY_METHODS"); do
    case "$m" in   # method:extra recipe line:asset it needs ("" = none)
        api-digest)     extra=""; need="" ;;
        sha256-sidecar) extra=""; need="demo-2.0.0.tar.gz.sha256" ;;
        checksums-file) extra="CHECKSUM_ASSET=SUMS"; need="SUMS" ;;
        gpg)            extra="GPG_SIG_ASSET=demo.sig"; need="demo.sig" ;;
        none)           extra=""; need="" ;;
        *) check "VERIFY=$m has a doctor/update agreement test" false; continue ;;
    esac
    agree "$m" "$extra"
    check "verify_${m//-/_} exists" bash -c ". '$here/../lib/common.sh'; . '$here/../lib/verify.sh'; declare -F verify_${m//-/_} >/dev/null"
    if [[ "$m" == none ]]; then
        check "VERIFY=none: doctor ok and update passes" bash -c "test '$urc' = 0 && ! grep -q 'FAIL  ' <<<'$out'"
    elif [[ -n "$need" ]]; then
        check "VERIFY=$m: doctor flags missing $need" grep -q "FAIL  $need not in release 2.0.0" <<<"$out"
        check "  update refuses the same release" bash -c "test '$urc' = 1 && grep -q 'asset not found in release.*asset=$need' '$T/log/err'"
    else
        check "VERIFY=$m: doctor flags the missing digest" grep -q 'FAIL  release API gives no sha256 digest' <<<"$out"
        check "  update refuses the same release" bash -c "test '$urc' = 1 && grep -q 'no sha256 digest' '$T/log/err'"
    fi
done
agree "bogus"
check "unknown VERIFY method: doctor says the recipe does not load" grep -q 'FAIL  recipe does not load: .*VERIFY' <<<"$out"
check "  update refuses it as a recipe error (exit 2)" bash -c "test '$urc' = 2 && grep -q 'VERIFY.*bogus' '$T/log/err'"
for v in " " "gpg bogus"; do
    reset_logs; agree "$v"
    check "VERIFY='$v': update exits 2 and downloads nothing" bash -c "test '$urc' = 2 && ! grep -q 'demo-2.0.0.tar.gz' '$T/log/curl'"
done
web_install_old; web_recipe minor sha256-sidecar; cp "$T/etc/apps.d/web.conf" "$T/etc3/apps.d/web.conf"
reset_logs; RELROTATE_CONF_DIR="$T/etc3" "$RR" doctor web >/dev/null 2>&1 || true
check "doctor fetches the release list once" test "$(grep -c 'api.github.com' "$T/log/curl")" = 1
reset_logs; STUB_RELEASES="$T/empty.json" RELROTATE_CONF_DIR="$T/etc3" "$RR" doctor web >/dev/null 2>&1 || true
check "  and once when the fetch fails" test "$(grep -c 'api.github.com' "$T/log/curl")" = 1
rm -rf "$T/etc3" "$T/state/renamed" "$T/state/broken"

echo "== current_version fails (broken binary)"
web_on_new; echo 'current_version() { /nonexistent/app --version; }' >> "$T/etc/apps.d/web.conf"
rc=0; "$RR" update web >/dev/null 2>"$T/log/err" || rc=$?
check "update exits 1 and names current_version in the log" bash -c "test '$rc' = 1 && grep -q 'level=err.*current_version' '$T/log/err'"
rc=0; "$RR" check web >/dev/null 2>"$T/log/err" || rc=$?
check "check exits 1 and names current_version in the log" bash -c "test '$rc' = 1 && grep -q 'level=err.*current_version' '$T/log/err'"
out="$("$RR" doctor web 2>&1)" || true
check "doctor prints a FAIL line for it" grep -q 'FAIL  .*current_version' <<<"$out"
check "  and carries on with the release check" grep -q 'ok    release check' <<<"$out"
web_on_new; echo 'current_version() { false; }' >> "$T/etc/apps.d/web.conf"
rc=0; "$RR" rollback web >/dev/null 2>&1 || rc=$?
check "rollback works from the recorded state: exit 0, symlink on 1.2.3" bash -c "test '$rc' = 0 && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.2.3'"
check "  and records installed=1.2.3 previous=1.3.0" bash -c "[[ \$(cat '$T/state/web/installed') == 1.2.3 && \$(cat '$T/state/web/previous') == 1.3.0 ]]"
web_on_new; rm -f "$T/state/web/installed"; echo 'current_version() { false; }' >> "$T/etc/apps.d/web.conf"
rc=0; "$RR" rollback web >/dev/null 2>&1 || rc=$?
check "no current version at all: rollback still switches to previous, exit 0" bash -c "test '$rc' = 0 && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.2.3'"
check "  and no state file is empty or a lone newline" test -z "$(find "$T/state/web" -maxdepth 1 -type f ! -name lock -exec grep -L '[^[:space:]]' {} +)"
web_recipe minor api-digest

echo "== the installed version must be a version"
web_on_new
echo 'current_version() { echo "v1.2.3"; }' >> "$T/etc/apps.d/web.conf"
check "current_version printing v1.2.3 reads as 1.2.3" bash -c "'$RR' check web 2>/dev/null | grep -qE '^installed +1\.2\.3\$'"
web_on_new; printf '1.2.3 \r\n' > "$T/state/web/installed"
check "installed file with a trailing space and CR reads as 1.2.3" bash -c "'$RR' check web 2>/dev/null | grep -qE '^installed +1\.2\.3\$'"
web_on_new; echo 'current_version() { echo "app 1.0.0"; }' >> "$T/etc/apps.d/web.conf"
check "current_version printing 'app 1.0.0': check exits 2" test "$(rc_of "$RR" check web)" = 2
check "  update exits 2 and installs nothing" bash -c "'$RR' update web 2>'$T/log/err'; test \$? = 2 && grep -q 'not a version' '$T/log/err' && ! grep -q demo-.*tar.gz '$T/log/curl'"
check "  doctor says so" bash -c "'$RR' doctor web 2>&1 | grep -q 'FAIL  .*not a version'"
check "  rollback still works from the recorded state" bash -c "'$RR' rollback web >/dev/null 2>&1 && test \"\$(cat '$T/state/web/installed')\" = 1.2.3"
web_on_new; echo "1.3.0 x" > "$T/state/web/installed"
check "a hand-edited installed file that is not a version: update exits 2" test "$(rc_of "$RR" update web)" = 2
web_on_new
check "adopt v1.4.0 stores 1.4.0" bash -c "'$RR' adopt web v1.4.0 >/dev/null && test \"\$(cat '$T/state/web/installed')\" = 1.4.0"
check "adopt ' 1.5.0 ' stores 1.5.0" bash -c "'$RR' adopt web ' 1.5.0 ' >/dev/null && test \"\$(cat '$T/state/web/installed')\" = 1.5.0"
for v in 2024.8.1 1.9 1.3.0-rc1; do
    check "adopt accepts $v, as the release parser does" bash -c "'$RR' adopt web $v >/dev/null && test \"\$(cat '$T/state/web/installed')\" = $v"
done
for v in 1.2.3.4 1.2.3+b1 2026.11.0b6 1.2.3-rc_1 2; do
    check "adopt accepts $v, and check then runs without error" bash -c "'$RR' adopt web $v >/dev/null && test \"\$(cat '$T/state/web/installed')\" = $v && '$RR' check web >/dev/null 2>&1"
done
for v in latest "1.2.3 beta" "1..2" "-1.2.3" "1.2.3-"; do
    check "adopt '$v' exits 2 and keeps the state" bash -c "'$RR' adopt web '$v' >/dev/null 2>&1; test \$? = 2 && test \"\$(cat '$T/state/web/installed')\" = 2"
done
web_recipe minor api-digest

echo "== hostile asset and tag names stay in the work dir"
evil_recipe() {   # extra recipe lines
    web_install_old; web_recipe major "${EVIL_VERIFY:-none}"
    printf '%s\n' "VERSION_REGEX='(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)'" "ASSET='\${TAG}.tar.gz'" "$@" >> "$T/etc/apps.d/web.conf"
}
evil_release() {   # tag asset-name...: every asset points at a real tarball
    local u="file://$T/assets/demo-1.2.4.tar.gz" a
    local -a as=()
    for a in "${@:2}"; do as+=("$(jq -n --arg n "$a" --arg u "$u" '{name:$n,browser_download_url:$u}')"); done
    jq -n --arg t "$1" --argjson a "[$(IFS=,; echo "${as[*]}")]" '[{tag_name:$t,prerelease:false,draft:false,assets:$a}]' > "$T/rel-evil.json"
}
rm -f "$T/state/escape-1.9.0.tar.gz" "$T/state/web/escape-1.9.0.tar.gz"
reset_logs; evil_recipe; evil_release "../../escape-1.9.0" "../../escape-1.9.0.tar.gz"
rc=0; STUB_RELEASES="$T/rel-evil.json" "$RR" update web >/dev/null 2>"$T/log/err" || rc=$?
check "tag and asset name with ../..: update exits 1 and logs it" bash -c "test '$rc' = 1 && grep -q 'level=err.*unsafe' '$T/log/err'"
check "  nothing was written outside the work dir" test -z "$(find "$T/state" -name 'escape-*' -type f)"
reset_logs; EVIL_VERIFY=sha256-sidecar evil_recipe "CHECKSUM_ASSET='../side.sha256'"
evil_release "v1.9.0" "v1.9.0.tar.gz" "../side.sha256"
rc=0; STUB_RELEASES="$T/rel-evil.json" "$RR" update web >/dev/null 2>"$T/log/err" || rc=$?
check "checksum asset name with a slash: update exits 1 and logs it" bash -c "test '$rc' = 1 && grep -q 'level=err.*unsafe' '$T/log/err'"
check "  nothing was written outside the work dir" test ! -e "$T/state/web/side.sha256"
reset_logs; web_install_old; web_recipe major none; echo "TAG_PREFIX='app/v'" >> "$T/etc/apps.d/web.conf"
evil_release "app/v1.9.0" "demo-1.9.0.tar.gz"
rc=0; STUB_RELEASES="$T/rel-evil.json" "$RR" update web >/dev/null 2>&1 || rc=$?
check "a monorepo tag app/v1.9.0 (TAG_PREFIX='app/v') still updates (exit $rc)" test "$rc" = 0 -a "$(cat "$T/state/web/installed")" = 1.9.0
reset_logs; web_install_old; web_recipe major none
STUB_RELEASES="$T/releases.json" "$RR" update web >/dev/null 2>&1 || true
check "downloads switch curl URL globbing off" grep -q -- '--globoff.* -o .*demo-2.0.0.tar.gz' "$T/log/curl"
web_recipe minor api-digest

echo "== version comparison"
tags_release() {   # tag...: releases carrying a demo-<version>.tar.gz asset each
    local t v u
    local -a rs=()
    for t in "$@"; do
        v="${t#v}"; u="${TAGS_URL:-file://$T/assets/demo-1.2.4.tar.gz}"
        rs+=("$(jq -n --arg t "$t" --arg n "demo-$v.tar.gz" --arg u "$u" '{tag_name:$t,prerelease:false,draft:false,assets:[{name:$n,browser_download_url:$u}]}')")
    done
    ( IFS=,; echo "[${rs[*]}]" ) > "$T/rel-tags.json"
}
cand_of() { STUB_RELEASES="$T/rel-tags.json" "$RR" check web 2>/dev/null | awk '$1=="candidate"{print $2}'; }
web_install_old; web_recipe patch api-digest
tags_release v1.2.3 v1.18446744073709551618.0
check "a 20-digit version component is dropped, not wrapped (candidate: $(cand_of))" test "$(cand_of)" = "none"
web_recipe major api-digest
check "  also under POLICY=major" test "$(cand_of)" = "none"
web_recipe major api-digest; echo 1.9 > "$T/state/web/installed"
tags_release v1.9.0 v1.09.0 v1.9
check "1.9.0, 1.09.0 and 1.9 are not newer than an installed 1.9 (candidate: $(cand_of))" test "$(cand_of)" = "none"
echo 1.9.0 > "$T/state/web/installed"; tags_release v1.2.3 v01.9.0
echo 1.9.0 > "$T/state/web/skip"; echo 1.2.3 > "$T/state/web/installed"
check "skip=1.9.0 also skips the tag 01.9.0 (candidate: $(cand_of))" test "$(cand_of)" = "none"
rm -f "$T/state/web/skip"
check "  without the skip, 01.9.0 is a candidate and keeps its spelling" test "$(cand_of)" = "01.9.0"
check "adopt refuses a 20-digit component too" test "$(rc_of "$RR" adopt web 1.18446744073709551618.0)" = 2
check "adopt accepts a long date suffix (only numeric components are limited)" test "$(rc_of "$RR" adopt web 1.2.3-20240101123456)" = 0
vcmp() { bash -c ". '$here/../lib/common.sh'; $1" >/dev/null 2>&1; }
for pair in "1.2.3.4 1.2.4" "2026.11.0b6 2026.11.0" "1.2.3+b1 1.2.3" "1.2.3-rc_1 1.2.3" "2 1.2.0"; do
    read -r x y <<<"$pair"
    check "compare $x and $y: no error, and never both newer than the other" bash -c "
        . '$here/../lib/common.sh'
        a=0; b=0; version_gt '$x' '$y' || a=\$?; version_gt '$y' '$x' || b=\$?
        [[ \$a -le 1 && \$b -le 1 ]] && ! { [[ \$a = 0 && \$b = 0 ]]; }"
done
check "1.2.3.4 is older than 1.2.4" vcmp "version_gt 1.2.4 1.2.3.4"
check "same_version: 1.2.3.4 is itself, and not 2026.11.0b6 vs 2026.11.0" vcmp "same_version 1.2.3.4 1.2.3.4 && ! same_version 2026.11.0b6 2026.11.0"
web_recipe minor api-digest

echo "== special archive members and modes"
rm -rf "$T/build/sp" "$T/build/ok"; mkdir -p "$T/build/sp/demo" "$T/build/ok/demo"
echo hi > "$T/build/sp/demo/VERSION"; mkfifo "$T/build/sp/demo/pipe"
tar -czf "$T/assets/fifo.tar.gz" -C "$T/build/sp" demo
echo hi > "$T/build/ok/demo/VERSION"; printf '#!/bin/sh\n' > "$T/build/ok/demo/run"; chmod 4755 "$T/build/ok/demo/run"
mkdir "$T/build/ok/demo/shared"; chmod 0775 "$T/build/ok/demo/shared"; echo x > "$T/build/ok/demo/shared/f"; chmod 0664 "$T/build/ok/demo/shared/f"
tar -czf "$T/assets/modes.tar.gz" -C "$T/build/ok" demo
web_install_old; web_recipe major none; TAGS_URL="file://$T/assets/fifo.tar.gz" tags_release v1.9.0
rc=0; STUB_RELEASES="$T/rel-tags.json" "$RR" update web >/dev/null 2>"$T/log/err" || rc=$?
check "an archive with a FIFO is refused (exit 1, logged)" bash -c "test '$rc' = 1 && grep -q 'level=err.*unsafe archive member' '$T/log/err'"
check "  and no release dir was created" test -z "$(find "$T/www/demo-releases" -maxdepth 1 -name '1.9.0*')"
web_install_old; TAGS_URL="file://$T/assets/modes.tar.gz" tags_release v1.9.0
rc=0; ( umask 077; STUB_RELEASES="$T/rel-tags.json" "$RR" update web >/dev/null 2>&1 ) || rc=$?
check "archive modes survive a hardened umask: dir 0775, file 0664 (got $(stat -c %a "$T/www/demo-releases/1.9.0/shared" "$T/www/demo-releases/1.9.0/shared/f" 2>&1 | tr '\n' ' '))" \
    test "$(stat -c %a "$T/www/demo-releases/1.9.0/shared" "$T/www/demo-releases/1.9.0/shared/f" | tr '\n' ' ')" = "775 664 "
check "a normal archive still installs, executable (exit $rc)" test "$rc" = 0 -a -x "$T/www/demo-releases/1.9.0/run"
check "  and a setuid bit in the archive does not survive" test ! -u "$T/www/demo-releases/1.9.0/run"
web_recipe minor api-digest

echo "== container image digests"
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
ctr_fresh() { reset_logs; rm -rf "$T/state/ctr"; printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet/demo.container"; }
dig() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }
d123="$(dig ghcr.io/example/demo:v1.2.3)"
ctr_fresh
check "update records the digest of the image it replaces" \
    bash -c "'$RR' update ctr 2>/dev/null && grep -qx '$d123' '$T/state/ctr'/quadlet.1.2.3.*.digest"
check "rollback points the tag back at that exact image" \
    bash -c "'$RR' rollback ctr 2>/dev/null && grep -qF 'tag ghcr.io/example/demo@$d123 ghcr.io/example/demo:v1.2.3' '$T/log/podman'"
ctr_fresh; "$RR" update ctr >/dev/null 2>&1; touch "$T/image-gone"
rc=0; out="$("$RR" rollback ctr 2>&1)" || rc=$?
check "an image that is gone everywhere: rollback still succeeds" test "$rc" = 0
check "  with a warning" grep -q 'level=warning.*could not point the tag back' <<<"$out"
ctr_fresh; touch "$T/no-digest"
check "no digest available: update still works" "$RR" update ctr
check "  and records none" bash -c "! ls '$T/state/ctr'/quadlet.*.digest 2>/dev/null"
ctr_fresh; echo PIN_DIGEST=yes >> "$T/etc/apps.d/ctr.conf"
check "PIN_DIGEST=yes: update succeeds" "$RR" update ctr
check "  Image= names tag and digest" grep -qx "Image=ghcr.io/example/demo:v1.3.0@$(dig ghcr.io/example/demo:v1.3.0+pulled)" "$T/quadlet/demo.container"
rm -f "$T/state/ctr/installed"
check "  the version is still read from the tag" bash -c "'$RR' check ctr 2>/dev/null | grep -q 'installed *1.3.0'"
ctr_fresh; touch "$T/no-digest"
check "PIN_DIGEST=yes without a digest fails before install" bash -c "! '$RR' update ctr 2>/dev/null && grep -qx 'Image=ghcr.io/example/demo:v1.2.3' '$T/quadlet/demo.container'"
sed -i 's/^PIN_DIGEST=yes/PIN_DIGEST=maybe/' "$T/etc/apps.d/ctr.conf"
check "PIN_DIGEST must be yes or no" test "$(rc_of "$RR" check ctr)" = 2
sed -i '/^PIN_DIGEST=/d' "$T/etc/apps.d/ctr.conf"
ctr_fresh; sed -i 's/^Image=.*/Image=ghcr.io\/example\/demo:latest/' "$T/quadlet/demo.container"
sed "s/^IMAGE=.*/IMAGE='ghcr.io\/example\/demo:latest'/" "$T/etc/apps.d/ctr.conf" > "$T/etc/apps.d/ctrl.conf"
rm -rf "$T/state/ctrl"; "$RR" adopt ctrl 1.2.3 >/dev/null
check "a tag that does not change (latest): the digest is read before the pull" \
    bash -c "'$RR' update ctrl 2>/dev/null && grep -qx '$(dig ghcr.io/example/demo:latest)' '$T/state/ctrl'/quadlet.1.2.3.*.digest"
rm -rf "$T/state/ctrl" "$T/etc/apps.d/ctrl.conf"
repo_of() { bash -c ". '$here/../lib/common.sh'; . '$here/../lib/layout-container.sh'; image_repo '$1'"; }
check "image_repo drops the tag" test "$(repo_of reg.example:5000/a/b:v1)" = reg.example:5000/a/b
check "image_repo keeps a registry port when there is no tag" test "$(repo_of reg.example:5000/a/b)" = reg.example:5000/a/b

echo "== container: quadlet on another version than recorded (killed after the flip)"
ctr_fresh; "$RR" update ctr >/dev/null 2>&1
echo 1.2.3 > "$T/state/ctr/installed"   # the run died before "installed" was written
cp "$T"/state/ctr/quadlet.1.2.3.*.bak "$T/bak.before"; ls "$T"/state/ctr/quadlet.1.2.3.*.digest > "$T/dig.list"
rm -f "$T/log/podman"
rc=0; out="$("$RR" update ctr 2>&1)" || rc=$?
check "quadlet on v1.3.0, installed 1.2.3: update exits 1" test "$rc" = 1
check "  names the tag found and the recorded version, advises adopt" grep -q 'tag v1.3.0 is not the recorded version 1.2.3.*relrotate adopt ctr 1.3.0' <<<"$out"
check "  says where the backup is to go back" grep -q 'restore .*demo.container from .*quadlet.1.2.3' <<<"$out"
check "  the 1.2.3 backup is unchanged" test "$(sha "$T/bak.before")" = "$(sha "$T"/state/ctr/quadlet.1.2.3.*.bak)"
check "  nothing was pulled" bash -c "! grep -q pull '$T/log/podman' 2>/dev/null"
check "  recorded as failed before install" grep -q 'nothing changed' "$T/state/ctr/last-result"
ctr_fresh; printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3 \r\n' > "$T/quadlet/demo.container"
check "Image= with trailing space and CR: the guard does not refuse" bash -c "'$RR' update ctr 2>/dev/null && grep -q '^Image=ghcr.io/example/demo:v1.3.0\$' '$T/quadlet/demo.container'"
ctr_fresh; printf '[Container]\nImage=ghcr.io/example/demo@sha256:%064d\n' 7 > "$T/quadlet/demo.container"; "$RR" adopt ctr 1.2.3 >/dev/null
check "digest-only Image= (no tag): the guard does not refuse" bash -c "'$RR' update ctr 2>/dev/null && grep -q '^Image=ghcr.io/example/demo:v1.3.0\$' '$T/quadlet/demo.container'"
echo "== container: how Image= is found and rewritten"
Q="$T/quadlet/demo.container"
q_img() { grep -qxF "$1" "$Q"; }
ctr_fresh; rm -rf "$T/quadlet-real"; mkdir -p "$T/quadlet-real"; printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/quadlet-real/demo.container"
chmod 640 "$T/quadlet-real/demo.container"; rm -f "$Q"; ln -s "$T/quadlet-real/demo.container" "$Q"
check "symlinked quadlet: update works" "$RR" update ctr
check "  the link is still a link" test -L "$Q"
check "  the target has the new image" grep -qxF 'Image=ghcr.io/example/demo:v1.3.0' "$T/quadlet-real/demo.container"
check "  and keeps its mode" test "$(stat -c %a "$T/quadlet-real/demo.container")" = 640
rm -f "$Q"; rm -rf "$T/quadlet-real"
ctr_fresh
printf '[Service]\nImage=not-this\n\n[Unit]\n# Image=old\n; Image=old\n\n[Container]\n# Image=old\nImage=second\nImage=ghcr.io/example/demo:v1.2.3\n\n[Install]\nImage=keep\n' > "$Q"
check "update with other Image= lines around" "$RR" update ctr
check "  the last Image= of [Container] is rewritten" q_img 'Image=ghcr.io/example/demo:v1.3.0'
check "  comments, other sections and an earlier Image= are left alone" bash -c "grep -qxF 'Image=not-this' '$Q' && grep -qxF '# Image=old' '$Q' && grep -qxF '; Image=old' '$Q' && grep -qxF 'Image=second' '$Q' && grep -qxF 'Image=keep' '$Q' && test \$(grep -c '^Image=ghcr' '$Q') = 1"
ctr_fresh; printf '[Container]\nImage=ghcr.io/example/other:v9.9.9\n[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$Q"
check "two [Container] sections: the last Image= is read" bash -c "'$RR' check ctr 2>/dev/null | grep -q 'installed *1.2.3'"
check "  and the only one rewritten" bash -c "'$RR' update ctr 2>/dev/null && grep -qxF 'Image=ghcr.io/example/other:v9.9.9' '$Q' && grep -qxF 'Image=ghcr.io/example/demo:v1.3.0' '$Q'"
ctr_fresh; printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3 \\\n  extra\n' > "$Q"; cp "$Q" "$T/q.before"
rc=0; out="$("$RR" update ctr 2>&1)" || rc=$?
check "a continued Image= line (trailing backslash): refused with a clear message, quadlet untouched" bash -c "test $rc != 0 && grep -q 'continued Image= line.*not supported' <<<\"\$1\" && cmp -s '$T/q.before' '$Q'" _ "$out"
out="$("$RR" doctor ctr 2>&1)" || true
check "  doctor reports it" grep -q 'continued Image= line.*not supported' <<<"$out"
if [[ "$(id -u)" != 0 ]]; then
    ctr_fresh; chmod 555 "$T/quadlet"
    rc=0; out="$("$RR" update ctr 2>&1)" || rc=$?
    chmod 755 "$T/quadlet"
    check "a quadlet that cannot be written (read-only directory): its own message, not 'no Image= line'" bash -c "test $rc != 0 && grep -q 'could not write the quadlet' <<<\"\$1\" && ! grep -q 'no Image= line' <<<\"\$1\"" _ "$out"
fi
ctr_fresh; printf '[Container]\nImage = ghcr.io/example/demo:v1.2.3\n' > "$Q"
check "Image = x with blanks around the = : check reads the version" bash -c "'$RR' check ctr 2>/dev/null | grep -q 'installed *1.2.3'"
check "  update works" "$RR" update ctr
check "  and writes Image=<image>" q_img 'Image=ghcr.io/example/demo:v1.3.0'
ctr_fresh; printf '[Container]\n  Image\t=  ghcr.io/example/demo:v1.2.3  \n' > "$Q"; "$RR" adopt ctr 1.2.3 >/dev/null
check "  tab and leading blanks too, the guard does not refuse" bash -c "'$RR' update ctr 2>/dev/null && grep -qxF 'Image=ghcr.io/example/demo:v1.3.0' '$Q'"
sed "s|^IMAGE=.*|IMAGE='ghcr.io/example/de\&mo\\\\1:\${TAG}'|" "$T/etc/apps.d/ctr.conf" > "$T/etc/apps.d/ctrx.conf"
ctr_fresh; rm -rf "$T/state/ctrx"; printf '[Container]\nImage=ghcr.io/example/de&mo\\1:v1.2.3\n' > "$Q"
check "an image with & and a backslash: update works" "$RR" update ctrx
check "  and is written as it is" q_img 'Image=ghcr.io/example/de&mo\1:v1.3.0'
rm -f "$T/etc/apps.d/ctrx.conf"; rm -rf "$T/state/ctrx"
ctr_fresh; printf '[Install]\nImage=x:v1.2.3\n[Container]\nPublishPort=1:1\n' > "$Q"
rc=0; out="$("$RR" update ctr 2>&1)" || rc=$?
check "no Image= in [Container]: refused, the quadlet is untouched" bash -c "test $rc != 0 && grep -qxF 'Image=x:v1.2.3' '$Q' && ! grep -q v1.3.0 '$Q'"

ctr_fresh; sed 's/^POLICY=.*/POLICY=major/' "$T/etc/apps.d/ctr.conf" > "$T/etc/apps.d/ctrp.conf"; echo PIN_DIGEST=yes >> "$T/etc/apps.d/ctrp.conf"
rm -rf "$T/state/ctrp"; "$RR" update ctrp >/dev/null 2>&1; echo 1.2.3 > "$T/state/ctrp/installed"; rm -f "$T/log/podman"
check "PIN_DIGEST=yes, quadlet on v2.0.0@sha256, installed 1.2.3: still refused" bash -c "! '$RR' update ctrp 2>/dev/null && ! grep -q pull '$T/log/podman' 2>/dev/null"
rm -rf "$T/state/ctrp" "$T/etc/apps.d/ctrp.conf"
ctr_fresh; sed -i 's/^Image=.*/Image=ghcr.io\/example\/demo:latest/' "$T/quadlet/demo.container"
sed "s/^IMAGE=.*/IMAGE='ghcr.io\/example\/demo:latest'/" "$T/etc/apps.d/ctr.conf" > "$T/etc/apps.d/ctrl.conf"
rm -rf "$T/state/ctrl"; "$RR" adopt ctrl 1.2.3 >/dev/null
check "constant tag (latest): the guard does not refuse" "$RR" update ctrl
rm -rf "$T/state/ctrl" "$T/etc/apps.d/ctrl.conf"
ctr_fresh; sed 's/^POLICY=.*/POLICY=major/' "$T/etc/apps.d/ctr.conf" > "$T/etc/apps.d/ctrp.conf"; echo PIN_DIGEST=yes >> "$T/etc/apps.d/ctrp.conf"
rm -rf "$T/state/ctrp"
check "PIN_DIGEST=yes: a second update from name:tag@sha256 works" bash -c "'$RR' update ctrp 2>/dev/null && '$RR' update ctrp 2>/dev/null && grep -q '^Image=ghcr.io/example/demo:v2.0.0@sha256:' '$T/quadlet/demo.container'"
rm -rf "$T/state/ctrp" "$T/etc/apps.d/ctrp.conf"
multi_reset; "$RR" adopt multi 1.2.3 >/dev/null
printf '[Container]\nImage=ghcr.io/example/ml:v1.3.0\n' > "$T/quadlet/ml.container"
check "set: the 2nd quadlet on another version refuses the update" bash -c "! '$RR' update multi 2>/dev/null && ! grep -q pull '$T/log/podman' 2>/dev/null && grep -q ':v1.2.3\$' '$T/quadlet/server.container'"
multi_reset; "$RR" adopt multi 1.2.3 >/dev/null
check "set: both quadlets on the recorded version update" "$RR" update multi
ctr_fresh; "$RR" update ctr >/dev/null 2>&1; rm -f "$T/state/ctr"/quadlet.*; "$RR" rollback ctr >/dev/null 2>&1
check "after a manual rollback without backup the next update works" bash -c "rm -f '$T/state/ctr/skip'; '$RR' update ctr 2>/dev/null && grep -q ':v1.3.0\$' '$T/quadlet/demo.container'"

echo "== state dir unwritable after the flip"
if [[ "$(id -u)" == 0 ]]; then echo "  (skipping: root ignores directory modes)"; else
reset_logs; web_install_old; web_recipe minor api-digest
{ cat "$T/etc/apps.d/web.conf"; echo "post_flip() { chmod 555 '$T/state/ws'; }"; } > "$T/etc/apps.d/ws.conf"
rm -rf "$T/state/ws"; "$RR" adopt ws 1.2.3 >/dev/null
rc=0; out="$("$RR" update ws 2>&1)" || rc=$?
chmod 755 "$T/state/ws"
check "commit-time state write fails: update exits 1" test "$rc" = 1
check "  logs event=state-write-failed with the versions" grep -q 'event=state-write-failed.*live=1.3.0.*recorded=1.2.3' <<<"$out"
check "  alerts: which version is live, what the state says, adopt" bash -c "grep -q 'state write FAILED' '$T/log/mail' && grep -q 'relrotate adopt ws' '$T/log/mail' && grep -q 'state says 1.2.3' '$T/log/mail'"
check "  the new version is what is live" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.3.0"
check "  the state still names 1.2.3" test "$(cat "$T/state/ws/installed")" = 1.2.3
reset_logs; ctr_fresh
{ cat "$T/etc/apps.d/ctr.conf"; echo "post_flip() { touch '$T/fail-reload'; chmod 555 '$T/state/ctrw'; return 1; }"; } > "$T/etc/apps.d/ctrw.conf"
rm -rf "$T/state/ctrw"; "$RR" adopt ctrw 1.2.3 >/dev/null
rc=0; out="$("$RR" update ctrw 2>&1)" || rc=$?
chmod 755 "$T/state/ctrw"
check "revert: the incomplete marker cannot be written: exit 1" test "$rc" = 1
check "  logged and alerted" bash -c "grep -q 'event=state-write-failed' <<<\"\$1\" && grep -q 'state write FAILED' '$T/log/mail'" _ "$out"
rm -rf "$T/state/ws" "$T/state/ctrw" "$T/etc/apps.d/ws.conf" "$T/etc/apps.d/ctrw.conf"
fi

echo "== leftovers of a killed run, and a backup cut short"
reset_logs; web_install_old; web_recipe minor api-digest
mkdir -p "$T/state/web/work.x" "$T/www/demo-releases/1.0.0.relrotate-new"; echo asset > "$T/state/web/work.x/file"
check "a dry run leaves stale work dirs alone" bash -c "'$RR' update -n web 2>/dev/null; test -e '$T/state/web/work.x/file' && test -d '$T/www/demo-releases/1.0.0.relrotate-new'"
check "update: exits 0" "$RR" update web
check "  stale work dir removed" test ! -e "$T/state/web/work.x"
check "  stale RELEASES_DIR/*.relrotate-new removed" test ! -e "$T/www/demo-releases/1.0.0.relrotate-new"
check "  the new release is in place" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.3.0"
reset_logs; web_install_old; mv "$T/www/demo-releases" "$T/www/real-releases"; ln -s real-releases "$T/www/demo-releases"
mkdir -p "$T/www/real-releases/1.0.0.relrotate-new"
check "RELEASES_DIR is a symlink: stale *.relrotate-new is removed too" bash -c "'$RR' update web 2>/dev/null && test ! -e '$T/www/real-releases/1.0.0.relrotate-new'"
rm -rf "$T/www/real-releases" "$T/www/demo-releases"
if [[ "$(uname -m)" != x86_64 ]]; then echo "  (skipping binary tests: not amd64)"; else
reset_logs; rm -rf "$T/state/bin"; cp "$T/assets/demobin_1.2.3_linux_amd64" "$T/usr/bin/demobin"
cat > "$T/bin/cp" <<EOF2
#!/usr/bin/env bash
# the copy is cut short: 5 bytes arrive, then the run dies
if [[ -e "$T/cp-truncate" && "\${*: -1}" == */bin/1.2.3/* ]]; then head -c 5 "\${*: -2:1}" > "\${*: -1}"; exit 1; fi
exec "$T/sysbin/cp" "\$@"
EOF2
chmod +x "$T/bin/cp"; touch "$T/cp-truncate"
check "backup of the running binary cut short: update fails" bash -c "! '$RR' update bin 2>/dev/null"
check "  the cut-short file does not count as the backup" test ! -e "$T/state/bin/bin/1.2.3/demobin"
rm -f "$T/cp-truncate"
check "  the next update succeeds" "$RR" update bin
check "  and the backup is the whole old binary" test "$(sha "$T/state/bin/bin/1.2.3/demobin")" = "$(sha "$T/assets/demobin_1.2.3_linux_amd64")"
check "  rollback installs it" bash -c "'$RR' rollback bin 2>/dev/null && test \"\$('$T/usr/bin/demobin')\" = 'demobin 1.2.3'"
rm -f "$T/bin/cp"
fi

echo "== constant tag: a failed update puts the tags a pull moved back"
cat > "$T/etc/apps.d/multil.conf" <<EOF
SOURCE=github:example/demo
POLICY=minor
LAYOUT=container
CONTAINERS=(
    '$T/quadlet/server.container|ghcr.io/example/server:latest'
    '$T/quadlet/ml.container|ghcr.io/example/ml:latest'
)
SERVICE="ml.service server.service"
HEALTH_RETRIES=1
HEALTH_DELAY=0
EOF
multil_reset() {
    reset_logs; rm -rf "$T/state/multil"
    printf '[Container]\nImage=ghcr.io/example/server:latest\n' > "$T/quadlet/server.container"
    printf '[Container]\nImage=ghcr.io/example/ml:latest\n' > "$T/quadlet/ml.container"
    "$RR" adopt multil 1.2.3 >/dev/null
}
tagged() { local r="ghcr.io/example/$1"; grep -qF "podman tag $r@$(dig "$r:latest") $r:latest" "$T/log/podman"; }
tagged_both() { tagged server && tagged ml; }
multil_reset; echo "ghcr.io/example/ml:latest" > "$T/fail-pull"
check "latest: 2nd pull fails: the update fails" bash -c "! '$RR' update multil 2>/dev/null"
check "  the 1st image's tag is pointed back at its recorded digest" tagged server
check "  the image whose pull failed is left alone" bash -c "! grep -q 'podman tag ghcr.io/example/ml' '$T/log/podman'"
multil_reset; touch "$T/fail-reload-once"
check "latest: daemon-reload fails in the flip: the update fails" bash -c "! '$RR' update multil 2>/dev/null"
check "  both tags are pointed back" tagged_both
multil_reset; touch "$T/fail-reload"
"$RR" update multil >/dev/null 2>&1 || true
check "latest: daemon-reload keeps failing: both tags are pointed back" tagged_both
multil_reset; echo "ghcr.io/example/ml:latest" > "$T/fail-pull"; touch "$T/fail-tag"
out="$("$RR" update multil 2>&1)" || true
check "latest: a retag that fails is logged as an error with image and digest" grep -q "level=err.*could not point the tag back.*image=ghcr.io/example/server:latest digest=$(dig ghcr.io/example/server:latest)" <<<"$out"
multi_reset; echo "ghcr.io/example/ml:v1.3.0" > "$T/fail-pull"; "$RR" update multi >/dev/null 2>&1 || true
check "version tags: a failed pull logs no tag call" bash -c "! grep -q '^podman tag' '$T/log/podman'"
multi_reset; touch "$T/fail-reload-once"; "$RR" update multi >/dev/null 2>&1 || true
check "version tags: a failed daemon-reload logs no tag call" bash -c "! grep -q '^podman tag' '$T/log/podman'"
rm -rf "$T/state/multil" "$T/etc/apps.d/multil.conf"

echo "== SERVICE units: the update stops at the first failing restart, the revert tries every unit"
reset_logs; web_install_old; web_recipe minor api-digest
sed 's/^SERVICE=.*/SERVICE="a.service b.service"/' "$T/etc/apps.d/web.conf" > "$T/etc/apps.d/web2.conf"
rm -rf "$T/state/web2"; "$RR" adopt web2 1.2.3 >/dev/null
echo a.service > "$T/fail-restart"
check "first unit fails to restart: the update fails and is rolled back" test "$(rc_of "$RR" update web2)" = 1
check "  forward: b is not restarted onto the new version; revert: a fails again, b is still restarted" test "$(grep restart "$T/log/systemctl" | tr '\n' ' ')" = "systemctl restart a.service systemctl restart a.service systemctl restart b.service "
check "  the failure is still reported" grep -q 'rolled back to 1.2.3; restart failed' "$T/state/web2/last-result"
check "  and the old version is live" test "$(readlink "$T/www/demo")" = "$T/www/demo-releases/1.2.3"
rm -rf "$T/state/web2" "$T/etc/apps.d/web2.conf"

echo "== signed checksum file"
printf '%s  a.tgz\n' "$(sha "$T/assets/demo-1.2.3.tar.gz")" > "$T/assets/SUMS"
echo sig > "$T/assets/SUMS.asc"; : > "$T/kr.gpg"
cat > "$T/sums-unit.sh" <<EOF
. '$here/../lib/common.sh'; . '$here/../lib/source.sh'; . '$here/../lib/verify.sh'
SOURCE=github:a/b ARCH=amd64 VERSION=1.0.0 TAG=v1.0.0 APP=u ASSET=a.tgz VERIFY=checksums-file CHECKSUM_ASSET=SUMS
CHECKSUM_SIG_ASSET="\${SIG-SUMS.asc}" GPG_KEYRING="\${KR-$T/kr.gpg}"
WORK=\$(mktemp -d '$T/u.XXXXXX'); DOWNLOAD=\$WORK/a.tgz
RELEASES=\$(jq -nc --arg d 'file://$T/assets' '[{tag:"v1.0.0",version:"1.0.0",assets:[{name:"a.tgz",url:"\(\$d)/demo-1.2.3.tar.gz"},{name:"SUMS",url:"\(\$d)/SUMS"},{name:"SUMS.asc",url:"\(\$d)/SUMS.asc"}]}]')
gpgv() { echo "gpgv \$*" >> '$T/log/gpgv'; [[ ! -e '$T/gpg-bad' ]]; }
download_and_verify
EOF
sums() { ( cd "$T" && env "$@" bash "$T/sums-unit.sh" ) >/dev/null 2>&1; }
reset_logs
check "a signed checksum file verifies" sums
check "  gpgv checked SUMS against SUMS.asc with the keyring" grep -qE "^gpgv --keyring $T/kr.gpg [^ ]+/SUMS.asc [^ ]+/SUMS$" "$T/log/gpgv"
touch "$T/gpg-bad"
check "a bad signature on the checksum file fails" bash -c "$(declare -f sums); T='$T'; ! sums"
rm -f "$T/gpg-bad"
check "a missing signature asset fails" bash -c "$(declare -f sums); T='$T'; ! sums SIG=SUMS.sig"
check "a relative keyring fails" bash -c "$(declare -f sums); T='$T'; ! sums KR=kr.gpg"
reset_logs
check "without CHECKSUM_SIG_ASSET no signature is checked (control)" bash -c "$(declare -f sums); T='$T'; sums SIG= && test ! -e '$T/log/gpgv'"

echo "== backup helpers"
bk="$T/bk"
backup_recipe() {   # hook-body [extra recipe lines]
    rm -rf "$bk"; reset_logs; web_install_old; web_recipe minor api-digest
    printf 'BACKUP_DIR=%s\n%s\npre_update() { %s; }\n' "$bk" "${2:-}" "$1" >> "$T/etc/apps.d/web.conf"
}
if command -v sqlite3 >/dev/null; then
    db="$T/app.db"; rm -f "$db"; sqlite3 "$db" 'CREATE TABLE t(x); INSERT INTO t VALUES (42);'
    backup_recipe "backup_sqlite '$db' db"
    check "backup_sqlite: update succeeds" "$RR" update web
    check "  one backup, named NAME-OLD_VERSION-stamp" bash -c "ls '$bk' | grep -qxE 'db-1\.2\.3-[0-9]{14}\.sqlite3' && test \$(ls '$bk' | wc -l) = 1"
    check "  it holds the data" test "$(sqlite3 "$bk"/db-1.2.3-*.sqlite3 'SELECT x FROM t')" = 42
    check "  BACKUP_DIR is private" test "$(find "$bk" -maxdepth 0 -perm 0700 | wc -l)" = 1
    backup_recipe "backup_sqlite '$db' db" "BACKUP_KEEP=2"
    mkdir -m 0700 "$bk"
    for i in 1 2 3; do touch -d "-$i days" "$bk/db-1.0.$i-2020010100000$i.sqlite3"; done
    touch "$bk/other-1.0.0-20200101000000.sqlite3"
    # same prefix, another name: must never count as "db" (all older than the db ones)
    for i in 4 5 6; do touch -d "-$i days" "$bk/db-old-1.0.$i-2020010100000$i.sqlite3"; done
    "$RR" update web >/dev/null 2>&1
    check "BACKUP_KEEP: the newest 2 of a name are kept" bash -c "test \$(ls '$bk'/db-[0-9]* | wc -l) = 2 && test -e '$bk/db-1.0.1-20200101000001.sqlite3' && ls '$bk'/db-1.2.3-* >/dev/null"
    check "  other names are left alone" test -e "$bk/other-1.0.0-20200101000000.sqlite3"
    check "  a name that starts the same (db-old) is left alone" test "$(find "$bk" -name 'db-old-*' | wc -l)" = 3
    chmod 0755 "$bk"; backup_recipe "backup_sqlite '$db' db"; mkdir -m 0755 "$bk"
    "$RR" update web >/dev/null 2>&1
    check "an existing BACKUP_DIR is made private" test "$(find "$bk" -maxdepth 0 -perm 0700 | wc -l)" = 1
    check "  and the backup is 0600" test "$(find "$bk" -name 'db-*.sqlite3' -perm 0600 | wc -l)" = 1
    backup_recipe "backup_sqlite '$T' db"
    check "a database path that is a directory fails" bash -c "! '$RR' update web 2>/dev/null"
    printf 'not a database\n' > "$T/bad.db"
    backup_recipe "backup_sqlite '$T/bad.db' bad"
    check "a backup that fails stops the update before install" bash -c "! '$RR' update web 2>/dev/null && test \"\$(readlink '$T/www/demo')\" = '$T/www/demo-releases/1.2.3'"
    check "  and leaves no partial file" bash -c "! ls '$bk'/*.part 2>/dev/null"
    check "  last-result names the hook" grep -q 'pre_update hook failed' "$T/state/web/last-result"
    rm -rf "$T/etc3"; mkdir -p "$T/etc3/apps.d"; cp "$T/etc/relrotate.conf" "$T/etc3/"
    backup_recipe "backup_sqlite '$db' db"; cp "$T/etc/apps.d/web.conf" "$T/etc3/apps.d/"
    check "doctor checks the backup tool" bash -c "RELROTATE_CONF_DIR='$T/etc3' '$RR' doctor web 2>&1 | grep -q 'ok    sqlite3 for backup_sqlite'"
    rm -rf "$T/etc3"
else
    echo "  (sqlite3 not installed: backup_sqlite tests skipped)"
fi
backup_recipe "backup_sqlite '$T/nonexistent.db' db"
rc=0; out="$("$RR" update web 2>&1)" || rc=$?
check "a database that does not exist yet: update goes on" test "$rc" = 0
check "  with a warning" grep -q 'level=warning.*backup skipped: database does not exist' <<<"$out"
backup_recipe "backup_pg pg-ctr postgres app"
check "backup_pg: update succeeds" "$RR" update web
check "  the dump is gzipped and complete" bash -c "f=\$(ls '$bk'/app-1.2.3-*.sql.gz) && gzip -t \"\$f\" && gzip -dc \"\$f\" | grep -q 'PostgreSQL database cluster dump'"
check "  pg_dumpall ran in the container" grep -q 'exec pg-ctr pg_dumpall --clean --if-exists -U postgres' "$T/log/podman"
backup_recipe "backup_pg pg-ctr"; touch "$T/fail-dump"
check "a failing pg_dumpall stops the update" bash -c "! '$RR' update web 2>/dev/null && ! ls '$bk'/*.sql.gz '$bk'/*.part 2>/dev/null"
backup_recipe "backup_pg pg-ctr"; touch "$T/empty-dump"
check "an empty dump stops the update" bash -c "! '$RR' update web 2>/dev/null && ! ls '$bk'/*.sql.gz 2>/dev/null"
backup_recipe "backup_pg pg-ctr postgres 'bad name'"
check "a backup name with a space is refused" bash -c "! '$RR' update web 2>/dev/null"
backup_recipe ":" "BACKUP_KEEP=0"
check "BACKUP_KEEP must be 1 or more" test "$(rc_of "$RR" check web)" = 2
backup_recipe ":" "BACKUP_DIR=relative/dir"
check "BACKUP_DIR must be absolute" test "$(rc_of "$RR" check web)" = 2
backup_recipe "backup_pg pg-ctr postgres app" "current_version() { echo 1.2.3-rc1; }"
check "a prerelease version is made safe in the file name" \
    bash -c "'$RR' update web 2>/dev/null; ls '$bk' | grep -qxE \"app-1\\.2\\.3_rc1-[0-9]{14}\\.sql\\.gz\""
rm -rf "$bk"; web_recipe minor api-digest

echo "== rootless quadlet: its owner's account does the file work"
reset_logs; rm -rf "$T/state/rl"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\nPublishPort=8080:8080\n' > "$T/quadlet/rl.container"
chmod 600 "$T/quadlet/rl.container"
cat > "$T/etc/apps.d/rl.conf" <<EOF
SOURCE=github:example/demo
POLICY=minor
LAYOUT=container
QUADLET=$T/quadlet/rl.container
QUADLET_USER=tenant
IMAGE='ghcr.io/example/demo:\${TAG}'
SERVICE=rl.service
HEALTH_RETRIES=1
HEALTH_DELAY=0
EOF
check "the version is read" bash -c "'$RR' check rl 2>/dev/null | grep -q '^installed *1.2.3'"
check "  through the owner's account, not by root" grep -qx "runuser -u tenant -- cat -- $T/quadlet/rl.container" "$T/log/runuser"
reset_logs
check "update exits 0" "$RR" update rl
check "  Image= bumped, other lines kept" bash -c "grep -qx 'Image=ghcr.io/example/demo:v1.3.0' '$T/quadlet/rl.container' && grep -qx 'PublishPort=8080:8080' '$T/quadlet/rl.container'"
check "  the quadlet was written by the owner's account" grep -q "^runuser -u tenant -- bash -c .* bash $T/quadlet/rl.container\$" "$T/log/runuser"
check "  its mode is unchanged" test "$(stat -c %a "$T/quadlet/rl.container")" = 600
check "  nothing is left next to it" bash -c "! ls '$T/quadlet' | grep -q 'rl.container.'"
reset_logs
check "rollback puts the old quadlet back" bash -c "'$RR' rollback rl 2>/dev/null && grep -qx 'Image=ghcr.io/example/demo:v1.2.3' '$T/quadlet/rl.container'"
check "  also through the owner's account" grep -q "^runuser -u tenant -- bash -c .* bash $T/quadlet/rl.container\$" "$T/log/runuser"
# a quadlet the owner's account cannot read: reported, not worked around as root
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/runuser.fail"; chmod +x "$T/bin/runuser.fail"
mv "$T/bin/runuser" "$T/bin/runuser.ok"; mv "$T/bin/runuser.fail" "$T/bin/runuser"
rm -f "$T/state/rl/installed"
check "when the owner's account cannot read the quadlet, the version is unknown" \
    bash -c "'$RR' check rl 2>/dev/null | grep -q '^installed *unknown'"
mv "$T/bin/runuser.ok" "$T/bin/runuser"
rm -f "$T/etc/apps.d/rl.conf" "$T/quadlet/rl.container"; rm -rf "$T/state/rl"

echo "== adopt <app>: take over an existing install"
reset_logs
rm -rf "$T/ex" "$T/qd" "$T/upd" "$T/units" "$T/opt"
mkdir -p "$T/ex" "$T/qd" "$T/upd/systemd" "$T/upd/cron.d" "$T/units" "$T/opt/sapp/releases/1.0.0/bin"
export RELROTATE_EXAMPLES_DIR="$T/ex" RELROTATE_QUADLET_DIRS="$T/qd $T/nowhere/*" \
       RELROTATE_UPDATER_DIRS="$T/upd/systemd $T/upd/cron.d"
adopt_out() { "$RR" adopt "$@" 2>&1 || true; }
has() { grep -q -- "$1" <<<"$out"; }
not_has() { ! grep -q -- "$1" <<<"$out"; }
# a recipe exists: the version is read and recorded
web_install_old; web_recipe minor api-digest
check "with a recipe: the installed version is read and recorded" \
    bash -c "'$RR' adopt web 2>&1 | grep -q 'web: recorded installed version 1.2.3' && test \"\$(cat '$T/state/web/installed')\" = 1.2.3"
cp "$T/etc/apps.d/web.conf" "$T/web.conf.before"
check "  the recipe is not touched" bash -c "'$RR' adopt web >/dev/null 2>&1; cmp -s '$T/etc/apps.d/web.conf' '$T/web.conf.before'"
check "  --source with an existing recipe is refused (exit 2)" test "$(rc_of "$RR" adopt --source github:example/demo web)" = 2
check "--source with another command is refused (exit 2)" test "$(rc_of "$RR" check --source github:example/demo web)" = 2
check "--source must look like a source (exit 2)" test "$(rc_of "$RR" adopt --source 'github:a/b;id' capp)" = 2
# nothing to go on
check "no recipe, no example, no --source: exit 2" test "$(rc_of "$RR" adopt capp)" = 2
check "  and no recipe is left" bash -c "! ls '$T/etc/apps.d' | grep -q '^capp'"
check "--source but nothing on the host: exit 2, no recipe" \
    bash -c "test \"\$('$RR' adopt --source github:example/demo capp >/dev/null 2>&1; echo \$?)\" = 2 && ! ls '$T/etc/apps.d' | grep -q '^capp'"
# a quadlet
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\nAutoUpdate=registry\n' > "$T/qd/capp.container"
touch "$T/upd/systemd/capp-update.timer" "$T/upd/systemd/capp-update.service" "$T/upd/systemd/other.timer"
echo "15 4 * * * root /usr/local/sbin/update-capp" > "$T/upd/cron.d/nightly"
out="$(adopt_out --source github:example/demo capp)"
check "quadlet: recipe written" test -s "$T/etc/apps.d/capp.conf"
check "  container layout, quadlet path, image template, service" bash -c "
    grep -qx 'LAYOUT=container' '$T/etc/apps.d/capp.conf' &&
    grep -qx \"QUADLET='$T/qd/capp.container'\" '$T/etc/apps.d/capp.conf' &&
    grep -qx \"IMAGE='ghcr.io/example/demo:\\\${TAG}'\" '$T/etc/apps.d/capp.conf' &&
    grep -qx \"SERVICE='capp.service'\" '$T/etc/apps.d/capp.conf' &&
    grep -qx 'SOURCE=github:example/demo' '$T/etc/apps.d/capp.conf'"
check "  installed version recorded from the image tag" test "$(cat "$T/state/capp/installed")" = 1.2.3
check "  the old timer is listed with how to turn it off" grep -q 'capp-update.timer   turn off: systemctl disable --now capp-update.timer' <<<"$out"
check "  the cron file that mentions the app is listed" grep -q "old updater? $T/upd/cron.d/nightly mentions capp" <<<"$out"
check "  AutoUpdate= in the quadlet is listed" grep -q 'sets AutoUpdate=' <<<"$out"
check "  an unrelated timer is not listed" not_has other.timer
check "  nothing was turned off or restarted" bash -c "! grep -Eq 'disable|restart|daemon-reload' '$T/log/systemctl' 2>/dev/null"
check "  the doctor checks ran" has 'ok    release check'
check "  the next steps are printed" has 'relrotate enable capp'
check "  the written recipe works: check finds the candidate" bash -c "'$RR' check capp 2>/dev/null | grep -q '^candidate *1.3.0'"
cp "$T/etc/apps.d/capp.conf" "$T/capp.conf.before"
check "adopt again: recipe unchanged, version already recorded" \
    bash -c "'$RR' adopt capp 2>&1 | grep -q 'already recorded' && cmp -s '$T/etc/apps.d/capp.conf' '$T/capp.conf.before'"
# a quadlet on :latest
printf '[Container]\nImage=ghcr.io/example/demo:latest\n' > "$T/qd/lapp.container"
check "quadlet on :latest: recipe written, version unknown, exit 2" \
    bash -c "out=\$('$RR' adopt --source github:example/demo lapp 2>&1); test \$? = 2 && grep -q 'must carry a version tag' <<<\"\$out\" && test -s '$T/etc/apps.d/lapp.conf'"
# a hostile Image= value must not reach a file that root sources
# shellcheck disable=SC2016  # the $( ) must stay literal: it is the attack
printf '[Container]\nImage=ghcr.io/$(touch %s/pwned)/demo:v1.0.0\n' "$T" > "$T/qd/happ.container"
check "hostile Image= value: refused (exit 2), no recipe" \
    bash -c "'$RR' adopt --source github:example/demo happ >/dev/null 2>&1; test \$? = 2 && ! ls '$T/etc/apps.d' | grep -q '^happ'"
check "  and nothing was run" test ! -e "$T/pwned"
# a shipped example: its IMAGE and hooks stay, the host's quadlet path goes in
cat > "$T/ex/eapp.conf" <<'EOF'
SOURCE=github:example/demo
POLICY="patch"
LAYOUT=container
QUADLET=/etc/containers/systemd/eapp.container
IMAGE='ghcr.io/example/demo:${TAG}'
SERVICE=eapp.service
# BACKUP_DIR=/var/lib/eapp/backups
# pre_update() { backup_sqlite /var/lib/eapp/db.sqlite db; }
EOF
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/qd/eapp.container"
out="$(adopt_out eapp)"
check "shipped example: used without --source" grep -q 'recipe starts from the shipped example' <<<"$out"
check "  the example's policy is kept, the quadlet path is the host's" \
    bash -c "grep -qx 'POLICY=\"patch\"' '$T/etc/apps.d/eapp.conf' && grep -qx \"QUADLET='$T/qd/eapp.container'\" '$T/etc/apps.d/eapp.conf'"
check "  says that backups are off and the hook is commented out" grep -q 'no backup is taken before an update' <<<"$out"
# a unit whose program sits under a symlinked directory
ln -s "$T/opt/sapp/releases/1.0.0" "$T/opt/sapp/current"; touch "$T/opt/sapp/releases/1.0.0/bin/sapp"
printf '[Service]\nExecStart=-%s/opt/sapp/current/bin/sapp serve --port 1\n' "$T" > "$T/units/sapp.service"
jq -n '[{tag_name: "v1.3.0", draft: false, prerelease: false, assets: [
        {name: "sapp_1.3.0_linux_amd64.tar.gz", browser_download_url: "file:///x", digest: "sha256:00"},
        {name: "sapp_1.3.0_linux_arm64.tar.gz", browser_download_url: "file:///x", digest: "sha256:00"},
        {name: "sapp_1.3.0_darwin_amd64.tar.gz", browser_download_url: "file:///x", digest: "sha256:00"},
        {name: "sapp_1.3.0_darwin_arm64.tar.gz", browser_download_url: "file:///x", digest: "sha256:00"},
        {name: "checksums.txt", browser_download_url: "file:///x"}]}]' > "$T/releases-sapp.json"
out="$(STUB_RELEASES="$T/releases-sapp.json" adopt_out --source github:example/sapp sapp)"
check "unit under a symlinked dir: symlink layout with TARGET and RELEASES_DIR" bash -c "
    grep -qx 'LAYOUT=symlink' '$T/etc/apps.d/sapp.conf' &&
    grep -qx \"TARGET='$T/opt/sapp/current'\" '$T/etc/apps.d/sapp.conf' &&
    grep -qx \"RELEASES_DIR='$T/opt/sapp/releases'\" '$T/etc/apps.d/sapp.conf'"
case "$(uname -m)" in x86_64|amd64|aarch64|arm64)
check "  the one release file for this host becomes ASSET; VERIFY from the API digest" bash -c "
    grep -qx \"ASSET='sapp_\\\${VERSION}_linux_\\\${ARCH}.tar.gz'\" '$T/etc/apps.d/sapp.conf' &&
    grep -qx 'VERIFY=\"api-digest\"' '$T/etc/apps.d/sapp.conf'"
check "  version read from the link" test "$(cat "$T/state/sapp/installed" 2>/dev/null)" = 1.0.0
;; esac
# a plain binary, release files that do not single one out
touch "$T/opt/bapp"
printf '[Service]\nExecStart=%s/opt/bapp\n' "$T" > "$T/units/bapp.service"
jq -n '[{tag_name: "v1.3.0", draft: false, prerelease: false, assets: [
        {name: "bapp-1.3.0.tar.gz", browser_download_url: "file:///x"}]}]' > "$T/releases-bapp.json"
out="$(STUB_RELEASES="$T/releases-bapp.json" adopt_out --source github:example/demo bapp)"
check "plain binary, no single release file: binary layout, candidates listed, adopt stops" bash -c "
    grep -qx 'LAYOUT=binary' '$T/etc/apps.d/bapp.conf' && grep -qx \"TARGET='$T/opt/bapp'\" '$T/etc/apps.d/bapp.conf' &&
    grep -q '^# ASSET: 0 release files fit this host' '$T/etc/apps.d/bapp.conf'"
check "  adopt says the recipe is not complete" has 'the recipe is not complete yet'
check "  exit 1" test "$(rc_of "$RR" adopt bapp)" = 1
# values that must not be taken at face value
printf "[Container]\nImage=ghcr.io/a'b/demo:v1.0.0\n" > "$T/qd/qapp.container"
check "a quote in the Image= value: refused (exit 2), no recipe" \
    bash -c "'$RR' adopt --source github:example/demo qapp >/dev/null 2>&1; test \$? = 2 && ! ls '$T/etc/apps.d' | grep -q '^qapp'"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3@sha256:abcd\n' > "$T/qd/dapp.container"
out="$(adopt_out --source github:example/demo dapp)"
check "an image with a digest: the template has no digest, the version is read" bash -c "
    grep -qx \"IMAGE='ghcr.io/example/demo:\\\${TAG}'\" '$T/etc/apps.d/dapp.conf' && test \"\$(cat '$T/state/dapp/installed')\" = 1.2.3"
printf '[Container]\nImage=ghcr.io/example/demo:1.2.3-alpine\n' > "$T/qd/xapp.container"
out="$(adopt_out --source github:example/demo xapp)"
check "a tag with a suffix is not turned into a template silently" has "the image tag '1.2.3-alpine' is not a plain version"
printf '[Service]\nExecStart=/usr/bin/env FOO=1 %s/opt/bapp\n' "$T" > "$T/units/wapp.service"
out="$(adopt_out --source github:example/demo wapp)"
check "a unit that starts a system program (wrapper): not taken as the app" has 'a system program: not taken as the app'
check "  and no recipe names it as TARGET" bash -c "! ls '$T/etc/apps.d' | grep -q '^wapp'"
ln -s "$T/opt" "$T/lnk"
printf '[Service]\nExecStart=%s/lnk/bapp\n' "$T" > "$T/units/papp.service"
out="$(STUB_RELEASES="$T/releases-bapp.json" adopt_out --source github:example/demo papp)"
check "a symlink on the way that is no release link: binary layout, not symlink" bash -c "
    grep -qx 'LAYOUT=binary' '$T/etc/apps.d/papp.conf' && grep -qx \"TARGET='$T/lnk/bapp'\" '$T/etc/apps.d/papp.conf'"
ln -s capp.container "$T/qd/zapp.container"
check "a quadlet that is a symlink is not used" \
    bash -c "'$RR' adopt --source github:example/demo zapp >/dev/null 2>&1; test \$? = 2 && ! ls '$T/etc/apps.d' | grep -q '^zapp'"
printf '[Container]\nImage=ghcr.io/example/demo:v1.2.3\n' > "$T/qd/uapp.container"
printf '[Service]\nExecStart=%s/opt/bapp\n' "$T" > "$T/units/uapp.service"
out="$(STUB_RELEASES="$T/releases-bapp.json" adopt_out --source github:example/demo uapp)"
check "the app's own unit wins over a quadlet outside /etc" has "uapp.container ignored: uapp.service starts"
check "  binary layout is written" grep -qx 'LAYOUT=binary' "$T/etc/apps.d/uapp.conf"
rm -f "$T/lnk"
for a in qapp dapp xapp wapp papp zapp uapp; do rm -rf "$T/etc/apps.d/$a.conf" "$T/state/$a"; done
unset RELROTATE_EXAMPLES_DIR
check "the shipped examples are found next to the script" bash -c "
    rm -f '$T/etc/apps.d/npmplus.conf'; '$RR' adopt npmplus >/dev/null 2>&1
    grep -q '^SOURCE=github:ZoeyVid/NPMplus' '$T/etc/apps.d/npmplus.conf'"
check "no shipped example has a backup hook switched on" \
    bash -c "! grep -l '^pre_update() { backup_' '$here'/../examples/apps.d/*.conf"
for a in capp lapp happ eapp sapp bapp npmplus; do rm -rf "$T/etc/apps.d/$a.conf" "$T/state/$a"; done
rm -rf "$T/ex" "$T/qd" "$T/upd" "$T/units" "$T/opt" "$T"/*.conf.before "$T/releases-sapp.json" "$T/releases-bapp.json"
unset RELROTATE_QUADLET_DIRS RELROTATE_UPDATER_DIRS

echo "== date tags: VERSION_REGEX with groups v1..v4"
reset_logs; rm -rf "$T/state/dt"
printf '[Container]\nImage=docker.io/example/dt:2026-10-22-r1\n' > "$T/quadlet/dt.container"
jq -n '["2026-11-18-r1", "2026-10-22-r2", "2026-10-22-r1", "2026-07-24-r1", "develop"]
    | map({tag_name: ., draft: false, prerelease: false, published_at: "2026-01-01T00:00:00Z", assets: []})' \
    > "$T/releases-dt.json"
cat > "$T/etc/apps.d/dt.conf" <<EOF
SOURCE=github:example/dt
VERSION_REGEX='^(?<v1>[0-9]{4})-(?<v2>[0-9]{2})-(?<v3>[0-9]{2})-r(?<v4>[0-9]+)\$'
POLICY=major
LAYOUT=container
QUADLET=$T/quadlet/dt.container
IMAGE='docker.io/example/dt:\${TAG}'
SERVICE=dt.service
HEALTH_RETRIES=1
HEALTH_DELAY=0
EOF
export STUB_RELEASES="$T/releases-dt.json"
check "installed version read from the quadlet's date tag" bash -c "'$RR' check dt 2>/dev/null | grep -q '^installed *2026\.10\.22\.1$'"
check "newest is the latest date" bash -c "'$RR' check dt 2>/dev/null | grep -q '^newest *2026\.11\.18\.1$'"
jq 'del(.[0])' "$T/releases-dt.json" > "$T/releases-dt2.json"
check "a second release on the same day (r2) is newer than r1" \
    bash -c "STUB_RELEASES='$T/releases-dt2.json' '$RR' check dt 2>/dev/null | grep -q '^candidate *2026\.10\.22\.2$'"
check "update exits 0" "$RR" update dt
check "  Image= carries the upstream tag, not the version" grep -qx 'Image=docker.io/example/dt:2026-11-18-r1' "$T/quadlet/dt.container"
check "  state records the version" test "$(cat "$T/state/dt/installed")" = 2026.11.18.1
check "rollback puts the old date tag back" bash -c "'$RR' rollback dt 2>/dev/null && grep -qx 'Image=docker.io/example/dt:2026-10-22-r1' '$T/quadlet/dt.container'"
unset STUB_RELEASES
jq '[{tag_name: "v9.9.9.9", draft: false, prerelease: false, assets: []}] + .' "$T/releases.json" > "$T/releases-4.json"
check "without VERSION_REGEX a four-part tag is still not a version" \
    bash -c "out=\$(STUB_RELEASES='$T/releases-4.json' '$RR' check web 2>/dev/null) && grep -q '^newest' <<<\"\$out\" && ! grep -q '9\.9\.9\.9' <<<\"\$out\""
rm -f "$T/etc/apps.d/dt.conf" "$T/quadlet/dt.container" "$T"/releases-dt*.json "$T/releases-4.json"; rm -rf "$T/state/dt"

echo "== relrotate updates itself"
# install.sh runs for real into scratch directories, and the installed copy
# then updates itself from fake releases. gpgv is a stub here; the signature
# check itself is covered by "signed checksum file" above and, with the real
# key, by .github/release-rpm.sh at release time.
P="$T/self"; mkdir -p "$P/units" "$P/assets"
self_env=(PREFIX="$P/pfx" ETC="$P/etc" UNITDIR="$P/units" STATEDIR="$P/state" ALLOW_NONROOT=yes
          RELROTATE_CONF_DIR="$P/etc" RELROTATE_STATE_DIR="$P/state")
selfinst() { env "${self_env[@]}" "$1/install.sh" </dev/null >/dev/null 2>&1; }
selfrr() { env -u RELROTATE_LIB_DIR -u RELROTATE_EXAMPLES_DIR "${self_env[@]}" "$P/pfx/sbin/relrotate" "$@"; }
selfver() { selfrr --version | awk '{print $2}'; }
cur="$("$RR" --version | awk '{print $2}')"; new="${cur%.*}.99"; broken="${cur%.*}.100"
printf '#!/usr/bin/env bash\necho "gpgv $*" >> "%s/log/gpgv"\n[[ ! -e "%s/gpg-bad" ]]\n' "$T" "$T" > "$T/bin/gpgv"; chmod +x "$T/bin/gpgv"
# mkrel VERSION [broken]: a release of this tree under another version number;
# broken: its install.sh stops after it has replaced the relrotate script.
mkrel() {
    local v="$1" d="$P/build/relrotate-$1"
    mkdir -p "$d"
    cp -r "$here/../relrotate" "$here/../install.sh" "$here/../lib" "$here/../etc" "$here/../systemd" \
        "$here/../examples" "$here/../relrotate-keyring.gpg" "$d/"
    sed -i "s/^RELROTATE_VERSION=.*/RELROTATE_VERSION=\"$v\"/" "$d/relrotate"
    # shellcheck disable=SC2016  # a literal $src in the sed pattern
    [[ -z "${2:-}" ]] || sed -i '/^install -m 0755 "\$src\/relrotate"/a exit 1' "$d/install.sh"
    tar -czf "$P/assets/relrotate-$v.tar.gz" -C "$P/build" "relrotate-$v"
    ( cd "$P/assets" && sha256sum "relrotate-$v.tar.gz" > "SHA256SUMS-$v" )
    echo sig > "$P/assets/SHA256SUMS.asc"
    jq -n --arg d "file://$P/assets" --arg v "$v" '[{tag_name: ("v" + $v), draft: false, prerelease: false,
        published_at: "2020-01-01T00:00:00Z", assets: [
          {name: ("relrotate-" + $v + ".tar.gz"), browser_download_url: ($d + "/relrotate-" + $v + ".tar.gz")},
          {name: "SHA256SUMS", browser_download_url: ($d + "/SHA256SUMS-" + $v)},
          {name: "SHA256SUMS.asc", browser_download_url: ($d + "/SHA256SUMS.asc")}]}]' > "$P/rel-$v.json"
}
mkrel "$new"; mkrel "$broken" broken
check "the broken test release really has a failing install.sh" grep -qx 'exit 1' "$P/build/relrotate-$broken/install.sh"

check "install.sh installs into a PREFIX" selfinst "$here/.."
check "  the installed copy runs" test "$(selfver)" = "$cur"
check "  the installed tree is kept as a release, the symlink points at it" \
    test "$(readlink "$P/pfx/lib/relrotate-current")" = "$P/pfx/lib/relrotate-releases/$cur" -a -x "$P/pfx/lib/relrotate-current/install.sh"
check "  the signing keyring is installed" cmp -s "$here/../relrotate-keyring.gpg" "$P/pfx/share/relrotate/relrotate-keyring.gpg"
touch "$P/pfx/lib/relrotate-releases/$cur/marker"   # a re-copy of the tree would lose it
check "install.sh run again from that release directory leaves it in place" \
    bash -c "$(declare -f selfinst); $(declare -p self_env); selfinst '$P/pfx/lib/relrotate-current' && test -e '$P/pfx/lib/relrotate-releases/$cur/marker'"

reset_logs
check "setup from a checkout does not offer self-update" bash -c "'$RR' setup </dev/null | grep -q 'self-update is not offered'"
check "setup answered no writes no recipe" bash -c "$(declare -f selfrr); $(declare -p self_env); P='$P'; printf 'n\nn\nn\n' | selfrr setup >/dev/null && test ! -e '$P/etc/apps.d/relrotate.conf'"
check "setup answered yes writes the recipe" bash -c "$(declare -f selfrr); $(declare -p self_env); P='$P'; printf 'n\nn\ny\n' | selfrr setup >/dev/null 2>&1"
check "  with this PREFIX in place of /usr/local" bash -c "grep -qx 'TARGET=$P/pfx/lib/relrotate-current' '$P/etc/apps.d/relrotate.conf' && ! grep -q /usr/local '$P/etc/apps.d/relrotate.conf'"
check "  not readable by others" test "$(stat -c %a "$P/etc/apps.d/relrotate.conf")" = 640
check "  and enables the timer" grep -q 'enable --now relrotate@relrotate.timer' "$T/log/systemctl"
check "setup again says self-update is on and asks nothing" bash -c "$(declare -f selfrr); $(declare -p self_env); P='$P'; selfrr setup </dev/null | grep -q 'relrotate updates itself'"
check "check reads the installed version from the symlink" bash -c "$(declare -f selfrr); $(declare -p self_env); P='$P'; STUB_RELEASES='$P/rel-$new.json' selfrr check relrotate 2>/dev/null | grep -q '^installed *$cur\$'"

touch "$T/gpg-bad"
check "a release with a bad signature is not installed" bash -c "$(declare -f selfrr selfver); $(declare -p self_env); P='$P'; ! STUB_RELEASES='$P/rel-$new.json' selfrr update relrotate 2>'$P/bad.err' && test \"\$(selfver)\" = '$cur'"
check "  and the reason is the signature" grep -q 'gpg signature check failed' "$P/bad.err"
rm -f "$T/gpg-bad"; reset_logs
check "relrotate updates itself (exit 0)" bash -c "$(declare -f selfrr); $(declare -p self_env); P='$P'; STUB_RELEASES='$P/rel-$new.json' selfrr update relrotate 2>/dev/null"
check "  SHA256SUMS was checked against the shipped keyring" grep -qE "^gpgv --keyring $P/pfx/share/relrotate/relrotate-keyring.gpg [^ ]+/SHA256SUMS.asc [^ ]+/SHA256SUMS$" "$T/log/gpgv"
check "  the installed copy is the new version" test "$(selfver)" = "$new"
check "  symlink and state say so" test "$(readlink "$P/pfx/lib/relrotate-current")" = "$P/pfx/lib/relrotate-releases/$new" -a "$(cat "$P/state/relrotate/installed")" = "$new"
check "  the old release is kept for a rollback" test -x "$P/pfx/lib/relrotate-releases/$cur/install.sh"
check "rollback reinstalls the old version" bash -c "$(declare -f selfrr selfver); $(declare -p self_env); P='$P'; selfrr rollback relrotate 2>/dev/null && test \"\$(selfver)\" = '$cur'"
check "  symlink is back" test "$(readlink "$P/pfx/lib/relrotate-current")" = "$P/pfx/lib/relrotate-releases/$cur"
check "a release whose install.sh fails half-way fails the update" bash -c "$(declare -f selfrr); $(declare -p self_env); P='$P'; ! STUB_RELEASES='$P/rel-$broken.json' selfrr update relrotate 2>/dev/null"
check "  and the old version is installed again" test "$(selfver)" = "$cur" -a "$(cat "$P/state/relrotate/installed")" = "$cur"

# An RPM install: rpm says it owns the script, so setup takes the RPM recipe.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/rpm"; chmod +x "$T/bin/rpm"
check "setup on an RPM install writes the RPM recipe" bash -c "printf 'y\n' | env -u RELROTATE_EXAMPLES_DIR '$RR' setup >/dev/null 2>&1 && cmp -s '$here/../examples/apps.d/relrotate-rpm.conf' '$T/etc/apps.d/relrotate.conf'"
rm -f "$T/bin/rpm" "$T/bin/gpgv" "$T/etc/apps.d/relrotate.conf"; rm -rf "$P" "$T/state/relrotate"

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 ))
