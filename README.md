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

Or, on RHEL 9/10, their clones and Fedora, the RPM from the
[release page](https://github.com/raatti/relrotate/releases) (from 0.4.1 on):

```bash
sudo rpm --import https://raw.githubusercontent.com/raatti/relrotate/main/RPM-GPG-KEY-relrotate
rpm -K ./relrotate-X.Y.Z-1.noarch.rpm     # must say: digests signatures OK
sudo dnf install ./relrotate-X.Y.Z-1.noarch.rpm
```

`dnf` does not check the signature of a local file by default, so run the
`rpm -K` line. From 0.4.2 on the RPM is signed, and so is `SHA256SUMS`
(`SHA256SUMS.asc`), which also lists the tarball. The key is
`RPM-GPG-KEY-relrotate` in this repository, fingerprint
`4EBA 8E3A DBB7 F14E CAD7  54A2 829A F617 0A43 D845`; compare it with what
`gpg --show-keys RPM-GPG-KEY-relrotate` prints before you import the file.
The 0.4.1 RPM is unsigned: check it against `SHA256SUMS` from its release.
To check a download by hand:

```bash
gpg --import RPM-GPG-KEY-relrotate
gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS
```

It installs under `/usr` where `install.sh` uses `/usr/local`; recipes,
`relrotate.conf` and state are in the same places. Use one or the other:
an `install.sh` copy wins over the RPM (units in `/etc/systemd/system`,
`/usr/local/sbin` first in root's `PATH`), so remove it first (see
Uninstall, without the `rm -rf` of state and recipes). `relrotate setup`
is not run by the RPM.

### relrotate updates itself

`relrotate setup` asks "Update relrotate itself automatically from its
GitHub releases?" (default no). On yes it writes
`/etc/relrotate/apps.d/relrotate.conf` from the shipped example for your
kind of install and turns on `relrotate@relrotate.timer`. From then on
relrotate is one more app: `status`, `check`, `hold`, `rollback` and the
notifications work as for any other. Needs `gpgv` (package `gnupg2`).

- **What is trusted:** a release is installed only when `SHA256SUMS` carries
  a good signature from the key above and lists the file's hash. The
  keyring is `relrotate-keyring.gpg`, installed next to the examples.
- **Which releases:** `POLICY="minor"`, which for 0.x means patch releases
  only, installed as soon as the timer sees them. To let a release settle
  first, set `MIN_AGE_DAYS` in the recipe.
- **`install.sh` install** (0.4.2 or newer): `install.sh` keeps the tree it
  installed in `PREFIX/lib/relrotate-releases/<version>`, with
  `PREFIX/lib/relrotate-current` pointing at the live one. An update unpacks
  the new release there and runs its `install.sh`; a rollback runs the old
  one again.
- **RPM install:** the release RPM is installed with `dnf`. relrotate keeps
  each RPM it installed, so a rollback has the previous one; the version you
  installed by hand before the first update is not kept, so that first
  update cannot be rolled back automatically.
- **Unit files:** every update installs the shipped `relrotate@.service` and
  `relrotate-digest.service` again. Keep local changes in drop-ins
  (`systemctl edit`), not in the files.
- **Off again:** `relrotate disable relrotate`, and remove the recipe.

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
sudoedit /etc/relrotate/apps.d/headscale.conf   # paths; uncomment the backup hook if you want it
sudo relrotate check headscale
sudo relrotate update --dry-run headscale     # download + verify only
sudo relrotate enable headscale               # relrotate@headscale.timer
```

If `check` reports the installed version as `unknown`, either add a
`current_version()` function to the recipe or record it once:

```bash
sudo relrotate adopt headscale 0.29.7
```

## Taking over an existing install

`relrotate adopt <app>` looks at the host and gets an app that is already
running under relrotate's care, without touching the app:

```bash
sudo relrotate adopt headscale                              # a shipped example exists
sudo relrotate adopt --source github:owner/repo myapp       # no example: say where releases are
```

- **Recipe.** If `/etc/relrotate/apps.d/<app>.conf` is missing it is written,
  from the shipped example when there is one, else from `--source`. An
  existing recipe is never changed.
- **What is read from the host.** A quadlet `<app>.container` in
  `/etc/containers/systemd`: container layout, `QUADLET` and `IMAGE` with
  the tag as `${TAG}` or `${VERSION}`. Else the unit `<app>.service`: its
  `ExecStart` program is the `TARGET` of a binary layout, or, when it sits
  under a link to a directory named like a version (`current -> 1.2.3`),
  that link is the `TARGET` of a symlink layout. Else a quadlet in root's or
  a user's `~/.config/containers/systemd` (with `QUADLET_USER`).
- **What is not taken.** A unit that starts a program under `/usr/bin`,
  `/usr/sbin` or `/usr/lib` (a wrapper such as `podman`, `java` or `env`,
  or a packaged binary); a quadlet that is a symlink or does not belong to
  the owner of its directory; a value with characters outside
  `A-Z a-z 0-9 . _ / : @ + -`. An image tag that is not a plain version
  (`latest`, `1.2.3-alpine`) is reported for you to check.
- **Download file.** Without an example, `ASSET` is written only when exactly
  one file of the newest release fits this host, and `VERIFY` only when the
  release API gives a digest. Otherwise the candidates are listed in the
  recipe and `adopt` stops until you have filled them in.
- **Version.** The installed version is read and recorded. When it cannot be
  read (a binary without `current_version`, a quadlet on `:latest`, a web
  root that is still a plain directory) `adopt` says what to do and exits 2.
- **Old updaters.** Timers, update services and cron files that mention the
  app, and `AutoUpdate=` in the quadlet, are listed with the command to turn
  them off. `adopt` does not turn them off.
- **Backups** stay off; a hook from the example is there, commented out.

It ends with the `doctor` checks for the app. Then run
`relrotate update --dry-run <app>` and `relrotate enable <app>`.

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
relrotate adopt <app>          take over an install that is already there:
                               see "Taking over an existing install"
relrotate hold <app> [reason]  no updates until unhold (rollback and adopt
                               still work); status shows HELD(reason)
relrotate unhold <app>
relrotate enable <app>         turn on the app's timer: systemctl enable --now
                               relrotate@<app>.timer
relrotate disable <app>        turn the timer off
relrotate setup                ask where notifications go (mail, discord,
                               ntfy, webhook) when none are set, and whether
                               relrotate should update itself; install.sh
                               runs it on a terminal
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
`-n` is refused for `adopt`, `rollback`, `hold`, `unhold`, `enable`, `disable`, `setup` and `digest`. `relrotate` with no command
prints the usage and exits 2. App names start with a letter or digit.

## Recipe reference

Recipes are shell, sourced by relrotate. Templates use `${VERSION}`,
`${TAG}`, `${ARCH}` (amd64/arm64), `${MAJOR}`, `${MINOR}` and must be in
single quotes so relrotate expands them, not the shell.

| Variable | Default | Meaning |
|---|---|---|
| `SOURCE` | | `github:owner/repo` or `gitea:https://host/owner/repo` |
| `TAG_PREFIX` | `v` | stripped from tags to get the version |
| `VERSION_REGEX` | | jq regex for odd tag schemes: a named group `v` is the version; groups `v1`..`v4` are joined with dots, so a date tag `2026-11-18-r1` becomes `2026.11.18.1` (see the npmplus example; use `POLICY=major`) |
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

Backups are optional and off by default: relrotate takes one only when a
recipe's hook calls a helper. Some shipped examples (headscale, lldap,
vaultwarden, immich) carry such a hook commented out; uncomment it to turn
the backup on. `relrotate doctor <app>` says which it is.

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
| relrotate, relrotate-rpm | symlink, binary | relrotate itself (written by `relrotate setup`): signed checksum file, hooks that run an installer |
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
| npmplus | container | date tags (`2026-11-18-r1`) through `VERSION_REGEX` |
| paperless-ngx | container | `v` tag, plain image tag |
| jellyfin | container | two-part versions |
| home-assistant | container | date versions |
| authelia | container | patch-only for an auth gateway |
| lldap | container | image tag keeps the `v` (`${TAG}`) |
| uptime-kuma | container | plain tags |
| immich | container | two containers as one set, database dump first |

Paths, ports and hostnames in them are examples; adjust to your host.

## Notifications

`relrotate setup` asks for a mail address and one chat destination and
writes them for you, as long as none are set (it then asks about
self-update, see Install); `install.sh` runs it when it
is on a terminal. By hand:

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

An RPM install: disable the `relrotate@*.timer` units as in the first
lines below, then `dnf remove relrotate`. For `install.sh`:
paths below are the defaults; use your `PREFIX` if you changed it.
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
  rm -rf /usr/local/lib/relrotate /usr/local/lib/relrotate-releases /usr/local/share/relrotate
  rm -f /usr/local/lib/relrotate-current
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
