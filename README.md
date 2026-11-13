# relrotate

logrotate, but for releases.

relrotate keeps self-hosted applications that live outside the distro
package manager up to date: the Go binary in `/usr/local/bin`, the PHP app
under `/var/www`, the pinned container tag in a podman quadlet. It checks
GitHub or Gitea/Forgejo releases on a systemd timer, installs what your
policy allows, verifies every downloaded asset, health-checks the result,
rolls back when the health check disagrees, and sends a mail either way.

It is plain bash with `curl` and `jq`, so the person reading it at 3 a.m.
does not need to learn a new language first.

## What it does per run

1. Read the recipe `/etc/relrotate/apps.d/<app>.conf`.
2. Ask the release API for recent releases; ignore drafts, pre-releases
   and tags that are not plain `X.Y[.Z]`.
3. Pick the newest version that `POLICY` allows (`patch`, `minor`, `major`).
   A newer release outside the policy gets one mail, not an install.
4. Download the asset and verify it (`api-digest`, `sha256-sidecar`,
   `checksums-file`, `gpg`, several at once, or an explicit `none`).
5. Stage it: a new release directory, a stored binary, or a pulled image.
6. Run hooks (`post_extract`, `pre_update`), then flip atomically:
   symlink swap, `mv` over the binary, or rewrite `Image=` and daemon-reload.
7. Restart `SERVICE`, run the health check, retry a few times.
8. Healthy: record the version, prune old releases, mail "updated".
   Any failure after the flip (`post_flip`, restart, health check): flip
   back, restart, check again, mail "rolled back".

State is written only after a successful update, so a failed version is
retried next run instead of being silently skipped forever.

## Layouts

| LAYOUT      | TARGET                              | Old versions kept in            |
|-------------|-------------------------------------|---------------------------------|
| `symlink`   | symlink, e.g. `/var/www/element`    | `RELEASES_DIR/<version>/`       |
| `binary`    | file, e.g. `/usr/local/bin/forgejo` | `/var/lib/relrotate/<app>/bin/` |
| `container` | `Image=` line in one or more quadlets | the previous quadlet files    |

On SELinux systems new files get `restorecon` automatically. The binary
layout keeps a copy of the binary that was installed before the first run,
so even the first update can be rolled back.

Apps made of several containers that must share one version (Immich's
server and machine-learning images) list them in `CONTAINERS=()`. All
images are pulled before any quadlet changes, all quadlets flip together
with one daemon-reload, and all roll back together.

Container images are pulled by tag and are not checked by `VERIFY`; that
is the registry's and podman's job. To verify images, set a signature
policy for the registry in `/etc/containers/policy.json` (see
`containers-policy.json(5)`), and podman refuses unsigned pulls.

## Versions and policy

`POLICY=patch` stays within X.Y, `minor` within X, `major` takes anything.
Below 1.0 semver treats a minor bump as breaking, so for `0.x` versions
`minor` behaves like `patch` (0.19.0 -> 0.19.2, not 0.20.0). Two-part
versions (Jellyfin's 12.4) count as 12.4.0, and date versions work the
same way (Home Assistant's 2026.11.1: patch = this month, minor = this
year). Tags that are not plain numbers after `TAG_PREFIX` (betas,
`-rc.1`, `Last-Python2-release`) are ignored.

## Install

```bash
git clone https://github.com/raatti/relrotate.git
cd relrotate
sudo ./install.sh
```

Needs `curl`, `jq`, `coreutils`, `tar`, `util-linux` (flock, runuser);
optional: `gpgv` for signature checks, `unzip`/`xz`/`bzip2` for those
asset formats, `sendmail` (any MTA) for mail.

relrotate identifies itself as `relrotate/<version>`. Some forges sit
behind bot shields (code.forgejo.org uses Anubis) that challenge
browser-like User-Agents but let plain API clients through. Tested shape:
RHEL 9/10 and clones; Debian and Ubuntu with the same paths.

## First app

```bash
sudo cp /usr/local/share/relrotate/examples/apps.d/headscale.conf /etc/relrotate/apps.d/
sudoedit /etc/relrotate/apps.d/headscale.conf
sudo relrotate check headscale
sudo relrotate update --dry-run headscale     # download + verify only
sudo systemctl enable --now relrotate@headscale.timer
```

If `check` reports the installed version as `unknown`, either add a
`current_version()` function to the recipe or record it once:

```bash
sudo relrotate adopt headscale 0.29.7
```

## Commands

```
relrotate check <app>          installed / newest / candidate, changes nothing
relrotate update <app>         what the timer runs
relrotate update -n <app>      dry run: download and verify only; no state
                               change, no mail
relrotate rollback <app>       back to the previous version; skips the
                               rolled-back version until a newer one appears
relrotate adopt <app> <ver>    record the installed version
relrotate status [app]         one line per app
relrotate list | update-all
```

## Recipe reference

Recipes are shell, sourced by relrotate. Templates use `${VERSION}`,
`${TAG}`, `${ARCH}` (amd64/arm64), `${MAJOR}`, `${MINOR}` and must be in
single quotes so relrotate expands them, not the shell.

| Variable | Default | Meaning |
|---|---|---|
| `SOURCE` | | `github:owner/repo` or `gitea:https://host/owner/repo` |
| `TAG_PREFIX` | `v` | stripped from tags to get the version |
| `VERSION_REGEX` | | jq regex with a named group `v`, for odd tag schemes |
| `ALLOW_PRERELEASE` | `no` | |
| `ASSET` | | asset name template, or `@tarball` for the source archive |
| `VERIFY` | | space-separated methods, see above |
| `CHECKSUM_ASSET` | `<asset>.sha256` | for `sha256-sidecar` / `checksums-file` |
| `GPG_SIG_ASSET`, `GPG_KEYRING` | `<asset>.asc` | for `gpg` (checked with gpgv) |
| `POLICY` | `minor` | `patch`: same X.Y; `minor`: same X; `major`: anything |
| `MAJOR_ACTION` | `mail` | `mail` or `ignore` for out-of-policy releases |
| `LAYOUT` | | `symlink`, `binary`, `container` |
| `TARGET` | | symlink or binary path |
| `RELEASES_DIR` | `<TARGET>-releases` | symlink layout |
| `STRIP_COMPONENTS` | 1 (symlink), 0 (binary) | tar `--strip-components` |
| `ARCHIVE_MEMBER` | | binary inside an archive, if it holds more than one file |
| `OWNER`, `MODE` | , `0755` | chown / binary mode |
| `LINKS`, `COPY` | | arrays of `'path/in/release:/source/path'` |
| `KEEP` | 3 | old releases to keep |
| `QUADLET`, `IMAGE` | | container layout, one container |
| `CONTAINERS` | | array of `'quadlet-path|image-template'`, updated as a set |
| `QUADLET_USER` | | owner of rootless quadlets (pull and systemctl run as them) |
| `SERVICE`, `RESTART` | , `yes` | unit(s) to restart after the flip, space-separated, in order |
| `HEALTH_URL` | | checked with curl; else `healthcheck()`; else `is-active` |
| `HEALTH_RETRIES`, `HEALTH_DELAY` | 5, 3 | |

Hooks (all optional shell functions): `current_version`, `post_extract`,
`pre_update`, `post_flip`, `healthcheck`, `on_rollback`. They see
`APP`, `VERSION`, `TAG`, `OLD_VERSION`, `RELEASE_DIR`, `DOWNLOAD`, `TARGET`.
A failing `post_extract`/`pre_update` aborts before anything changes; a
failing `post_flip`, restart or health check triggers a rollback. During
any rollback a failing `on_rollback` does not stop it: relrotate still
restarts and health-checks the old version and reports the hook failure
in the log, the mail and `relrotate status`.

`relrotate rollback` mails only when it fails. If the files switch back
but the restart or health check fails, the old version is recorded as
installed and `status` shows `UNHEALTHY`, so the records match what runs.

## Example recipes

In `examples/apps.d/`, each checked against the project's real releases:

| Recipe | Layout | Shows |
|---|---|---|
| headscale | binary | API digest + checksums.txt, SQLite backup hook, rkhunter |
| forgejo | binary | Gitea/Forgejo API (Codeberg), sha256 sidecar |
| forgejo-runner | binary | code.forgejo.org behind Anubis |
| hugo | binary | binary inside a tarball (`ARCHIVE_MEMBER`), 0.x with `major` |
| restic | binary | single `.bz2` file, `SHA256SUMS` |
| rclone | binary | zip with a top directory |
| element-web | symlink | GPG signature, config copied into each release |
| cinny | symlink | GPG signature |
| freshrss | symlink | no release assets (`@tarball`), data dirs linked in |
| roundcube | symlink | upstream migration script before the flip |
| adminer | symlink | single PHP file renamed to index.php |
| tuwunel | container | rootless quadlet (`QUADLET_USER`) |
| vaultwarden | container | tag without `v`, SQLite backup |
| paperless-ngx | container | `v` tag, plain image tag |
| jellyfin | container | two-part versions |
| home-assistant | container | date versions |
| authelia | container | patch-only for an auth gateway |
| lldap | container | image tag keeps the `v` (`${TAG}`) |
| uptime-kuma | container | plain tags |
| immich | container | two containers as one set, database dump first |

Paths, ports and hostnames in them are examples; adjust to your host.

## Logs

Every event is one `key=value` line in the journal:

```
relrotate level=info app=forgejo event=updated from=17.0.0 to=17.0.1
```

```bash
journalctl -u 'relrotate@*' -o cat
```

In Loki: `{unit=~"relrotate@.*"} | logfmt | level="err"` makes a decent
alert rule.

## Schedule

Default: every 4 hours with up to 30 minutes of jitter. Per app:

```bash
sudo systemctl edit relrotate@forgejo.timer
```

```ini
[Timer]
OnUnitActiveSec=
OnCalendar=Mon 03:00
```

## Tests

```bash
tests/run.sh
```

Synthetic end-to-end tests against fake releases served from `file://`
URLs, with systemctl and podman stubbed. No root, no network.

`tests/check.sh` runs everything CI runs: `bash -n`, shellcheck on the
scripts and on the shell-sourced configs and recipes, then the tests.
The workflows `.github/workflows/checks.yml` and
`.forgejo/workflows/checks.yml` run it on every pull request and on
pushes to `main`.

## Contributing

Issues and pull requests are welcome on
[GitHub](https://github.com/raatti/relrotate). Run `tests/check.sh`
before you open one; CI runs the same checks and must pass. Pull
requests are squash-merged, so one tidy description matters more than
tidy commits. A new recipe is welcome too: check it against the
project's real releases first, as the ones in `examples/apps.d/` are.
Security problems go through [SECURITY.md](SECURITY.md), not issues.

## License

MIT, see [LICENSE](LICENSE). Changes are listed in
[CHANGELOG.md](CHANGELOG.md); report security problems as described in
[SECURITY.md](SECURITY.md).
