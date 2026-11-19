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
year). Leading zeros are decimal (`2024.08.1` is 2024.8.1). Tags that are
not plain numbers after `TAG_PREFIX` (betas, `-rc.1`,
`Last-Python2-release`) are ignored, unless `ALLOW_PRERELEASE=yes`: then
`X.Y(.Z)-<suffix>` tags count, a prerelease sorts below its final release
(`1.3.0-rc1` < `1.3.0`), and `POLICY` looks at the numeric part only.
The newest 100 GitHub releases (50 on Gitea) are read. Releases with no
tag name are skipped. For layouts that download, a release without the
`ASSET` is passed over (older eligible releases are used, a warning names
the newest one lacking it).

If the release list cannot be fetched, is empty, or has releases but none
with a usable version (upstream changed its tag scheme), `update` exits 1,
writes `check failed: <reason>` to `last-result` and mails once; it does
not mail again until a check succeeds. `check` and `update -n` change no state.

## Install

```bash
git clone https://github.com/raatti/relrotate.git
cd relrotate
sudo ./install.sh
```

Needs bash 5.1 or newer (the bash of RHEL 9), `curl`, `jq`, `coreutils` (incl. `timeout`), `tar`, `util-linux` (flock, runuser);
optional: `gpgv` for signature checks, `unzip`/`xz`/`bzip2` for those
asset formats, `sendmail` (any MTA) for mail.

relrotate identifies itself as `relrotate/<version>`. Some forges sit
behind bot shields (code.forgejo.org uses Anubis) that challenge
browser-like User-Agents but let plain API clients through. Tested shape:
RHEL 9/10 and clones; Debian and Ubuntu with the same paths
(unverified).

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
                               rolled-back version until a newer one appears;
                               retries a rollback left incomplete
relrotate adopt <app> <ver>    record the installed version (clears an
                               incomplete-rollback block)
relrotate hold <app> [reason]  no updates until unhold (rollback and adopt
                               still work); status shows HELD(reason)
relrotate unhold <app>
relrotate status [app]         one line per app; --json for scripts
relrotate doctor [app]         check recipes, the newest release's assets,
                               paths, keyrings and notifications; also the
                               owner and mode of the config, recipes, keyring
                               and token/notify files; changes nothing; exit 1
                               on any FAIL
relrotate digest               send the queued summary (see Notifications)
relrotate list | update-all
```

`status` shows flags before `last=`: `INCOMPLETE(...)`, `UNHEALTHY(v)`,
`HELD(reason)`, `CHECK-FAILED` (the last release check failed; `last-check`
is the time of the last good one), `SKIP(v)` and `WAITING(v until date)`.
`status --json` prints one array with the same fields (`null` when unset).

Unknown options and extra arguments are an error (exit 2, with the usage);
`-n` is refused for `adopt`, `rollback`, `hold`, `unhold` and `digest`. `relrotate` with no command
prints the usage and exits 2. App names start with a letter or digit.

## Recipe reference

Recipes are shell, sourced by relrotate. Templates use `${VERSION}`,
`${TAG}`, `${ARCH}` (amd64/arm64), `${MAJOR}`, `${MINOR}` and must be in
single quotes so relrotate expands them, not the shell.

| Variable | Default | Meaning |
|---|---|---|
| `SOURCE` | | `github:owner/repo` or `gitea:https://host/owner/repo` |
| `TAG_PREFIX` | `v` | stripped from tags to get the version |
| `VERSION_REGEX` | | jq regex with a named group `v`, for odd tag schemes |
| `ALLOW_PRERELEASE` | `no` | `yes` accepts `X.Y.Z-rc1` style tags |
| `ASSET` | | asset name template, or `@tarball` for the source archive |
| `VERIFY` | | space-separated methods, see above |
| `CHECKSUM_ASSET` | `<asset>.sha256` | for `sha256-sidecar` / `checksums-file` |
| `CHECKSUM_SIG_ASSET` | | `checksums-file` only: a detached signature of the checksum file (`SHA256SUMS.asc`), checked with gpgv against `GPG_KEYRING` before the hash; for projects that sign only their checksum file |
| `GPG_SIG_ASSET`, `GPG_KEYRING` | `<asset>.asc` | for `gpg` (checked with gpgv); the keyring must be an absolute path, and any key in it is accepted, so use one keyring per app |
| `POLICY` | `minor` | `patch`: same X.Y; `minor`: same X; `major`: anything |
| `MAJOR_ACTION` | `mail` | `mail` or `ignore` for out-of-policy releases |
| `MIN_AGE_DAYS` | 0 (or the global value) | install a release only once it is this many days old; a younger one waits (`status`: `WAITING`) and an older eligible one may install meanwhile. A release with no publish date waits |
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
| `PIN_DIGEST` | `no` | container: `yes` writes `Image=name:tag@sha256:...`, so a re-pushed tag cannot change what runs |
| `SERVICE`, `RESTART` | , `yes` | unit(s) to restart after the flip, space-separated, in order |
| `HEALTH_URL` | | checked with curl; else `healthcheck()`; else `is-active` |
| `BACKUP_DIR`, `BACKUP_KEEP` | state dir`/backups`, 5 | where the backup helpers write, and how many backups per name they keep |
| `HEALTH_RETRIES`, `HEALTH_DELAY` | 5, 3 | retries (1 or more) and the pause between them (`sleep` syntax: `3`, `2.5`, `30s`, `1m`); validated |

Global settings (`/etc/relrotate/relrotate.conf`): `GITHUB_TOKEN_FILE` and
`GITEA_TOKEN_FILE` hold API tokens. A token is never sent over `http://`,
and a token file that is set but unreadable is an error. The one Gitea
token goes to every Gitea host a recipe names, unless `GITEA_TOKEN_HOSTS`
(space-separated host names) is set: then only to those. curl is limited
to https (plus http when a recipe's own `SOURCE` is http), never follows a
redirect to http, and gets `--` before every URL from release data.
An empty `VERIFY` fails the download (`VERIFY=none` is the opt-out).

Hooks (all optional shell functions): `current_version`, `post_extract`,
`pre_update`, `post_flip`, `healthcheck`, `on_rollback`. They see
`APP`, `VERSION`, `TAG`, `OLD_VERSION`, `RELEASE_DIR`, `DOWNLOAD`, `TARGET`.
A failing `post_extract`/`pre_update` aborts before anything changes; a
failing `post_flip`, restart or health check triggers a rollback. During
any rollback a failing `on_rollback` does not stop it: relrotate still
restarts and health-checks the old version and reports the hook failure
in the log, the mail and `relrotate status`.

Hooks (all but `current_version`) run in a subshell with `set -e`: the
first failing step fails the hook, and the steps after it do not run. A
step that may fail ends in `|| true`. Commands in a condition (`if`, `&&`,
`||`) do not count as failures, as usual with `set -e`. Being a subshell, a
hook cannot set variables for relrotate or for a later hook.
Hooks run with the run lock closed (fd 9), so a daemon they start does not
keep `relrotate` locked.

Two helpers back up a database from a hook, usually `pre_update`, so the
update stops before anything changes when the backup fails:

```bash
BACKUP_DIR=/var/lib/vaultwarden/backups
pre_update() { backup_sqlite /var/lib/vaultwarden/db.sqlite3 db; }
# or: pre_update() { backup_pg immich-postgres postgres immich; }
```

- `backup_sqlite DB [NAME]` takes a consistent copy with `sqlite3 .backup`
  (safe while the app runs) and checks it with `PRAGMA integrity_check`. A
  database that does not exist yet (a fresh install) is a warning, not a
  failure.
- `backup_pg CONTAINER [DBUSER] [NAME]` runs `pg_dumpall` in the container
  (as `QUADLET_USER` when set) and gzips it; an empty or broken dump fails.

Backups are named `NAME-<old version>-<YYYYmmddHHMMSS>`, written as `.part`
and renamed when complete; the newest `BACKUP_KEEP` per name are kept.
`doctor` checks that `sqlite3` or `podman` is there when a hook calls them.

For container apps relrotate records, before each update, the digest of the
image every quadlet runs (next to the quadlet backup in the state
directory). A rollback points the tag back at that image, pulling it by
digest if it is gone, so it runs the old image even when upstream re-pushed
the tag. If that fails, it is a warning and the tag stays as it is.

relrotate traps `TERM` and `INT` (a `systemctl stop`, `TimeoutStartSec`)
during `update` and `rollback`, and exits 143 or 130. Before anything
changed it records "interrupted before install of <version>, nothing
changed". Once files may have started to change (the flip, or any rollback)
it writes the `incomplete` marker described below, so updates stay blocked
and `relrotate rollback <app>` puts the old version back. A signal after the
outcome is recorded (during the mail, say) leaves the record as it is.

`relrotate rollback` mails only when it fails. If the files switch back
but the health check fails, the old version is recorded as installed and
marked unhealthy, so the records match what runs: `status` shows
`UNHEALTHY(<version>)` (and `INCOMPLETE(...)` for a blocked rollback),
before `last=`. Every timer run checks its health again before looking for
releases. While it fails, last-result says "still UNHEALTHY" and, with
nothing newer to install, the run exits 1 and never records "ok"; a newer
release is still installed, and its own health check decides. When the
check passes, relrotate records "healthy again" and mails once. A
successful update or rollback, or `adopt`, clears the mark. A rollback whose
health check passes but whose hook failed is reported "with problems".

A container rollback can be left incomplete: some quadlets were put back,
then a copy or `daemon-reload` failed. relrotate then keeps the recorded
versions as they were, writes the target version to `incomplete` in the
app's state directory, mails, and refuses `update` (so the timer cannot
back up the half-reverted quadlets over the good backups). Fix the cause
and run `relrotate rollback <app>`: it retries the same rollback. After a
fix by hand, `relrotate adopt <app> <ver>` clears the block instead.
`relrotate status` shows `INCOMPLETE` in the app's last result meanwhile.

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

## Notifications

Each event goes to `MAIL_TO` and to every `NOTIFY` destination in
`/etc/relrotate/relrotate.conf`, as `kind:file`:

| Kind | The file holds |
|---|---|
| `discord` | the webhook URL (Server settings, Integrations, Webhooks) |
| `telegram` | the bot token on line 1, the chat id on line 2 |
| `ntfy` | the topic URL; the subject becomes the `Title` |
| `webhook` | a URL that gets `{"source":"relrotate","host","app","title","body"}` as JSON, for a bot of your own (Signal, Matrix, ...); `http://` is allowed for a local one |

```sh
( set -euo pipefail
  umask 077
  printf '%s\n' 'https://discord.com/api/webhooks/<id>/<token>' > /etc/relrotate/discord.url
  echo "NOTIFY=(discord:/etc/relrotate/discord.url)" >> /etc/relrotate/relrotate.conf
  relrotate doctor )
```

The file holds a secret: keep it root-only. relrotate hands the URL to
curl on stdin, never on its command line, and never logs it. A destination
that fails is a warning in the journal; it does not fail the update.
Chat messages are cut at 1900 characters.

`NOTIFY_POLICY` decides when messages go out:

- `each` (default): every event at once.
- `failures`: failures and blocks at once; updates, recoveries and
  "new major available" wait for the summary.
- `digest`: everything waits for the summary.

The summary is one message per host: the events needing attention first,
each with its full text, then one line per other event. It is sent by
`relrotate-digest.timer` (daily at 08:00; `systemctl edit
relrotate-digest.timer` for another time) and at the end of `update-all`.
Enable the timer when the policy is not `each`. A summary that cannot be
sent to every destination is kept and goes out with the next one.

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

Default: every 4 hours on the clock (00:00, 04:00, ...) plus up to 30
minutes of jitter. A run missed while the host was down is caught up once
at boot (`Persistent=true`). Per app:

```bash
sudo systemctl edit relrotate@forgejo.timer
```

```ini
[Timer]
OnCalendar=
OnCalendar=Mon 03:00
```

## Known limits

"Not confirmed" means nobody has run it on a real host yet.

- `ProtectControlGroups=yes` in the unit may stop `podman exec`, which the
  `backup_pg` helper uses. Not confirmed; if a Postgres dump fails with a
  permission error, relax that line with `systemctl edit relrotate@<app>.service`.
- `examples/strict.conf` lacks `/run/libpod` and your `BACKUP_DIR`; add them
  to `ReadWritePaths=` if you use that sandbox. Not confirmed on a real host.
- A rootless `QUADLET_USER` needs lingering enabled for that user
  (`loginctl enable-linger <user>`), or the user's systemd and its containers
  are not there when the timer runs.
- Debian 12 ships podman 4.3, which has no quadlet support: the container
  layout needs a newer podman there.
- `MIN_AGE_DAYS` counts from the release's publish date only. A file
  re-uploaded to an old release does not restart the wait.
- Symlink layout: after a crash right after the switch, the next run says
  "already live" and does nothing; run `relrotate adopt <app> <version>`
  once you have checked that version works.
- A container recipe with a constant tag such as `:latest` is not covered by
  the "quadlet is on another version" guard: the tag names the same version
  before and after, so a killed run cannot be told from a finished one.
- Downloads have no size cap.

## Uninstall

Paths below are the defaults; use your `PREFIX` if you changed it.
Add `rm -rf /var/lib/relrotate /etc/relrotate` to drop the state and your
recipes too; installed apps and their release directories stay as they are.

```bash
( set -euo pipefail
  systemctl list-units --plain --no-legend 'relrotate@*.timer' | awk '{print $1}' \
      | xargs -r systemctl disable --now
  systemctl disable --now relrotate-digest.timer 2>/dev/null || true
  rm -f /etc/systemd/system/relrotate@.service /etc/systemd/system/relrotate@.timer \
        /etc/systemd/system/relrotate-digest.service /etc/systemd/system/relrotate-digest.timer
  rm -f /usr/local/sbin/relrotate
  rm -rf /usr/local/lib/relrotate /usr/local/share/relrotate
  systemctl daemon-reload )
```

## Tests

```bash
tests/run.sh
```

Synthetic end-to-end tests against fake releases served from `file://`
URLs, with systemctl and podman stubbed. No root, no network.

`tests/check.sh` runs everything CI runs: `bash -n`, shellcheck on the
scripts and on the shell-sourced configs and recipes, then the tests.
`.github/workflows/checks.yml` runs it on every pull request and on
pushes to `main`. On Forgejo the tests take minutes on the runner, so
`.forgejo/workflows/checks.yml` runs only `tests/check.sh lint` there and
the whole of it once per release tag (or on request).

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
