#!/usr/bin/env bash
# Every check CI runs, in one place, so a local run matches the runner:
# bash syntax, shellcheck on scripts and on shell-sourced configs, tests.
# Needs: bash, shellcheck, and what tests/run.sh needs (jq, curl, bzip2, ...).
#   tests/check.sh lint   only the syntax check and shellcheck (seconds)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

scripts=(relrotate install.sh lib/*.sh tests/*.sh)
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

echo "== relrotate.spec"
v="$(sed -n 's/^RELROTATE_VERSION="\(.*\)"$/\1/p' relrotate)"
grep -qx "Version:  *$v" relrotate.spec \
    || { echo "relrotate.spec: Version is not $v (RELROTATE_VERSION)" >&2; exit 1; }
if command -v rpmbuild >/dev/null && command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
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
    echo "rpmbuild or git not found: RPM build not checked"
fi

[[ "${1:-}" != lint ]] || exit 0

echo "== tests"
bash tests/run.sh
