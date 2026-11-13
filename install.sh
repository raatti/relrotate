#!/usr/bin/env bash
# Install relrotate into /usr/local and /etc. Re-run to upgrade; existing
# config and recipes are never overwritten.
set -Eeuo pipefail

PREFIX="${PREFIX:-/usr/local}"
ETC="${ETC:-/etc/relrotate}"
UNITDIR="${UNITDIR:-/etc/systemd/system}"
src="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

missing=()
for t in curl jq sha256sum tar flock; do command -v "$t" >/dev/null || missing+=("$t"); done
if (( ${#missing[@]} )); then
    echo "missing tools: ${missing[*]}" >&2
    if command -v dnf >/dev/null; then
        echo "  dnf install ${missing[*]/sha256sum/coreutils}" >&2
    elif command -v apt-get >/dev/null; then
        echo "  apt-get install ${missing[*]/sha256sum/coreutils}" >&2
    fi
    exit 1
fi
command -v gpgv >/dev/null || echo "note: gpgv not found; VERIFY=gpg recipes will fail until it is installed" >&2

install -d -m 0755 "$PREFIX/sbin" "$PREFIX/lib/relrotate"
install -m 0755 "$src/relrotate" "$PREFIX/sbin/relrotate"
install -m 0644 "$src"/lib/*.sh "$PREFIX/lib/relrotate/"

install -d -m 0750 "$ETC" "$ETC/apps.d" "$ETC/keys"
[[ -e "$ETC/relrotate.conf" ]] || install -m 0640 "$src/etc/relrotate.conf" "$ETC/relrotate.conf"
install -d -m 0755 "$PREFIX/share/relrotate/examples"
cp -r "$src/examples/." "$PREFIX/share/relrotate/examples/"

install -m 0644 "$src/systemd/relrotate@.service" "$src/systemd/relrotate@.timer" "$UNITDIR/"
install -d -m 0750 /var/lib/relrotate

if command -v restorecon >/dev/null && command -v selinuxenabled >/dev/null && selinuxenabled; then
    restorecon -R "$PREFIX/sbin/relrotate" "$PREFIX/lib/relrotate" "$ETC" "$UNITDIR"/relrotate@.* /var/lib/relrotate
fi
systemctl daemon-reload

cat <<EOF
relrotate installed.

Next:
  cp $PREFIX/share/relrotate/examples/apps.d/<app>.conf $ETC/apps.d/   # then edit
  relrotate check <app>
  relrotate adopt <app> <installed-version>      # only if check shows 'unknown'
  relrotate update --dry-run <app>
  systemctl enable --now relrotate@<app>.timer
EOF
