#!/usr/bin/env bash
# Every check CI runs, in one place, so a local run matches the runner:
# bash syntax, shellcheck on scripts and on shell-sourced configs, tests.
# Needs: bash, shellcheck, and what tests/run.sh needs (jq, curl, bzip2, ...).
#   tests/check.sh lint   only the syntax check and shellcheck (seconds)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

scripts=(relrotate install.sh lib/*.sh tests/*.sh .github/release-rpm.sh)
# Recipes and the global config are sourced as bash. examples/strict.conf
# is a systemd drop-in, not shell, so it is left out.
configs=(etc/relrotate.conf examples/apps.d/*.conf)

echo "== bash -n"
for f in "${scripts[@]}" "${configs[@]}"; do
    bash -n "$f"
done

echo "== shellcheck $(shellcheck --version | sed -n 's/^version: //p')"
shellcheck -x "${scripts[@]}"
shellcheck -x -s bash "${configs[@]}"

echo "== release signing key"
# The binary keyring gpgv reads must be the armored key, and that key must be
# the one the README names.
fpr=4EBA8E3ADBB7F14ECAD754A2829AF6170A43D845
grep -q "${fpr:0:4} ${fpr:4:4} ${fpr:8:4} ${fpr:12:4} ${fpr:16:4}  ${fpr:20:4} ${fpr:24:4} ${fpr:28:4} ${fpr:32:4} ${fpr:36:4}" README.md \
    || { echo "README.md does not name the key fingerprint $fpr" >&2; exit 1; }
if command -v gpg >/dev/null; then
    gpghome="$(mktemp -d)"
    got="$(gpg --homedir "$gpghome" --batch --show-keys --with-colons RPM-GPG-KEY-relrotate 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}')"
    gpg --homedir "$gpghome" --batch --dearmor < RPM-GPG-KEY-relrotate > "$gpghome/keyring.gpg" 2>/dev/null || true
    same=1; cmp -s "$gpghome/keyring.gpg" relrotate-keyring.gpg || same=0
    rm -rf "$gpghome"
    [[ "$got" == "$fpr" ]] || { echo "RPM-GPG-KEY-relrotate is key '$got', expected $fpr" >&2; exit 1; }
    (( same )) || { echo "relrotate-keyring.gpg is not RPM-GPG-KEY-relrotate dearmored (gpg --dearmor)" >&2; exit 1; }
    echo "key $fpr"
else
    echo "gpg not found: key files not checked"
fi

echo "== relrotate.spec"
v="$(sed -n 's/^RELROTATE_VERSION="\(.*\)"$/\1/p' relrotate)"
grep -qx "Version:  *$v" relrotate.spec \
    || { echo "relrotate.spec: Version is not $v (RELROTATE_VERSION)" >&2; exit 1; }
# rpmbuild alone is not enough: Ubuntu has it with an empty RPM database, so
# the spec's BuildRequires can never be met there.
if rpm -q rpm-build systemd-rpm-macros >/dev/null 2>&1 && command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
    # The same build as .github/workflows/release.yml, from the working tree.
    rpmtmp="$(mktemp -d)"
    trap 'rm -rf "$rpmtmp"' EXIT
    git ls-files -z | tar --null -T - --transform "s|^|relrotate-$v/|" -czf "$rpmtmp/relrotate-$v.tar.gz"
    rpmbuild -ta "$rpmtmp/relrotate-$v.tar.gz" --define "_topdir $rpmtmp/build" --define "_rpmdir $rpmtmp" \
        --define '_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' --define 'dist %{nil}' \
        > "$rpmtmp/log" 2>&1 || { cat "$rpmtmp/log" >&2; exit 1; }
    files="$(rpm -qpl "$rpmtmp/relrotate-$v-1.noarch.rpm")"
    for f in /usr/sbin/relrotate /usr/lib/relrotate/common.sh /usr/lib/systemd/system/relrotate@.timer \
             /usr/share/relrotate/examples/apps.d/headscale.conf /etc/relrotate/relrotate.conf /var/lib/relrotate; do
        grep -qxF "$f" <<<"$files" || { echo "relrotate.spec: the RPM lacks $f" >&2; exit 1; }
    done
    echo "built relrotate-$v-1.noarch.rpm"
else
    echo "not an RPM build host (rpm-build, systemd-rpm-macros, git): RPM build not checked"
fi

[[ "${1:-}" != lint ]] || exit 0

echo "== tests"
bash tests/run.sh
