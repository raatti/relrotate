#!/usr/bin/env bash
# Run by .github/workflows/release.yml inside almalinux:9, with the repository
# at /src (read-only) and the release files in /dist. Builds
# relrotate-$v-1.noarch.rpm from /dist/relrotate-$v.tar.gz, signs it, writes
# SHA256SUMS and its detached signature SHA256SUMS.asc, then checks both
# signatures with nothing but the public key files in the repository.
#   v         version, X.Y.Z
#   GPG_KEY   armored private key (secret RPM_GPG_PRIVATE_KEY)
#   GPG_PASS  its passphrase (secret RPM_GPG_PASSPHRASE); empty for none
set -euo pipefail

: "${v:?}"
[[ -n "${GPG_KEY:-}" ]] || { echo "::error::secret RPM_GPG_PRIVATE_KEY is not set"; exit 1; }
pub=/src/RPM-GPG-KEY-relrotate
rpm="relrotate-$v-1.noarch.rpm"

dnf -y -q install rpm-build systemd-rpm-macros rpm-sign gnupg2

rpmbuild -ta "/dist/relrotate-$v.tar.gz" --define "_rpmdir /dist" \
    --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
    --define "dist %{nil}"
cd /dist
[[ -s "$rpm" ]] || { echo "::error::no RPM was built"; exit 1; }

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
printf '%s' "${GPG_PASS:-}" > "$GNUPGHOME/pass"
loopback=(--batch --pinentry-mode loopback --passphrase-file "$GNUPGHOME/pass")
gpg --quiet "${loopback[@]}" --import <<<"$GPG_KEY"
fpr="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')"
[[ -n "$fpr" ]] || { echo "::error::RPM_GPG_PRIVATE_KEY holds no private key"; exit 1; }

rpmsign --define "_gpg_name $fpr" --define "_gpg_sign_cmd_extra_args ${loopback[*]}" --addsign "$rpm"
sha256sum "relrotate-$v.tar.gz" "$rpm" > SHA256SUMS
gpg --quiet "${loopback[@]}" -u "$fpr" --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS

# The private key must be the one users are told to trust.
rpmkeys --import "$pub"
[[ "$(rpm -K "$rpm")" == *"signatures OK"* ]] \
    || { echo "::error::$rpm does not verify against RPM-GPG-KEY-relrotate"; exit 1; }
# With the keyring file installed hosts check it with, not a copy made here.
gpgv --keyring /src/relrotate-keyring.gpg SHA256SUMS.asc SHA256SUMS \
    || { echo "::error::SHA256SUMS.asc does not verify against relrotate-keyring.gpg"; exit 1; }
