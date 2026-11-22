#!/usr/bin/env bash
# Install relrotate into /usr/local and /etc. Re-run to upgrade; existing
# config and recipes are never overwritten.
set -Eeuo pipefail

PREFIX="${PREFIX:-/usr/local}"
# PREFIX goes into a sed replacement and the unit file: a plain absolute path only.
[[ "$PREFIX" =~ ^/[A-Za-z0-9._/-]*$ ]] || { echo "PREFIX must be a plain absolute path: $PREFIX" >&2; exit 1; }
ETC="${ETC:-/etc/relrotate}"
UNITDIR="${UNITDIR:-/etc/systemd/system}"
STATEDIR="${STATEDIR:-/var/lib/relrotate}"
# -P: relrotate runs this through the PREFIX/lib/relrotate-current symlink.
src="$(cd "$(dirname "$0")" && pwd -P)"

# ALLOW_NONROOT=yes: a staged install into directories of your own (the tests).
[[ $EUID -eq 0 || "${ALLOW_NONROOT:-}" == yes ]] || { echo "run as root" >&2; exit 1; }
# The version names a directory below: digits and dots only.
ver="$(sed -n 's/^RELROTATE_VERSION="\(.*\)"$/\1/p' "$src/relrotate")"
[[ "$ver" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "cannot read the version from $src/relrotate" >&2; exit 1; }

missing=()
for t in curl jq sha256sum tar flock timeout; do command -v "$t" >/dev/null || missing+=("$t"); done
if (( ${#missing[@]} )); then
    echo "missing tools: ${missing[*]}" >&2
    # package names: sha256sum and timeout are coreutils, flock is util-linux
    pkgs=("${missing[@]/sha256sum/coreutils}")
    pkgs=("${pkgs[@]/timeout/coreutils}")
    pkgs=("${pkgs[@]/flock/util-linux}")
    if command -v dnf >/dev/null; then
        echo "  dnf install ${pkgs[*]}" >&2
    elif command -v apt-get >/dev/null; then
        echo "  apt-get install ${pkgs[*]}" >&2
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
# The key relrotate's own releases are signed with (README: Install).
install -m 0644 "$src/relrotate-keyring.gpg" "$PREFIX/share/relrotate/relrotate-keyring.gpg"

# The units name /usr/local/sbin; point them at the configured PREFIX.
for u in relrotate@.service relrotate-digest.service; do
    sed "s|^ExecStart=/usr/local/sbin/|ExecStart=$PREFIX/sbin/|" "$src/systemd/$u" > "$UNITDIR/$u"
    chmod 0644 "$UNITDIR/$u"
done
install -m 0644 "$src/systemd/relrotate@.timer" "$src/systemd/relrotate-digest.timer" "$UNITDIR/"
install -d -m 0750 "$STATEDIR"

# Keep what was installed as a release directory, with a symlink to the live
# one: relrotate can then update itself as a symlink-layout app and has an
# install.sh to run for every version it can roll back to (README).
rel="$PREFIX/lib/relrotate-releases/$ver"
install -d -m 0755 "$PREFIX/lib/relrotate-releases"
if [[ "$src" != "$(readlink -f "$rel")" ]]; then
    rm -rf -- "$rel.new"
    install -d -m 0755 "$rel.new"
    cp -r "$src/relrotate" "$src/install.sh" "$src/lib" "$src/etc" "$src/systemd" "$src/examples" \
        "$src/relrotate-keyring.gpg" "$rel.new/"
    # Two renames, so a kill in between cannot leave no release here.
    rm -rf -- "$rel.old"
    [[ ! -e "$rel" ]] || mv -T "$rel" "$rel.old"
    mv -T "$rel.new" "$rel"
    rm -rf -- "$rel.old"
fi
ln -sfn "$rel" "$PREFIX/lib/relrotate-current.new"
mv -Tf "$PREFIX/lib/relrotate-current.new" "$PREFIX/lib/relrotate-current"

if command -v restorecon >/dev/null && command -v selinuxenabled >/dev/null && selinuxenabled; then
    restorecon -R "$PREFIX/sbin/relrotate" "$PREFIX/lib/relrotate" "$PREFIX/lib/relrotate-releases" \
        "$PREFIX/lib/relrotate-current" "$PREFIX/share/relrotate" "$ETC" \
        "$UNITDIR"/relrotate@.* "$UNITDIR"/relrotate-digest.* "$STATEDIR" \
        || echo "warning: restorecon failed; check labels with: ls -Z $PREFIX/sbin/relrotate $UNITDIR/relrotate@.*" >&2
fi
if ! systemctl daemon-reload; then
    cat >&2 <<EOF
relrotate is installed ($PREFIX/sbin/relrotate, $PREFIX/lib/relrotate, units in $UNITDIR,
config in $ETC), but 'systemctl daemon-reload' failed. Run it by hand:
  systemctl daemon-reload
EOF
    exit 1
fi

cat <<EOF
relrotate installed.

Next:
  relrotate adopt <app>                          # an app that is already installed: writes its recipe
  cp $PREFIX/share/relrotate/examples/apps.d/<app>.conf $ETC/apps.d/   # or by hand, then edit
  relrotate check <app>
  relrotate adopt <app> <installed-version>      # only if check shows 'unknown'
  relrotate update --dry-run <app>
  relrotate enable <app>                         # turns on relrotate@<app>.timer
  relrotate setup                                # notifications and self-update, if not set below
  relrotate doctor                               # checks every recipe, changes nothing
  systemctl enable --now relrotate-digest.timer  # only with NOTIFY_POLICY=failures|digest
EOF

# On a terminal: ask where notifications go and whether relrotate updates
# itself (setup only asks what is not set yet).
if [[ -t 0 && -t 1 ]]; then
    echo
    "$PREFIX/sbin/relrotate" setup || echo "notifications not set up; run later: relrotate setup" >&2
fi
