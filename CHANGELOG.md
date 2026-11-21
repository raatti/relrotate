# Changelog

## Unreleased

- `tests/check.sh` builds the RPM only on an RPM build host; it failed on
  Ubuntu, which has `rpmbuild` but none of the build packages (#113).

## 0.4.1 (2026-11-21)

- Releases carry `relrotate-X.Y.Z-1.noarch.rpm` for RHEL 9/10, their clones
  and Fedora, built from `relrotate.spec` by the release workflow; unsigned,
  listed in `SHA256SUMS` (#109).

## 0.4.0 (2026-11-20)

- `VERSION_REGEX` with groups `v1`..`v4` reads date-style tags
  (`2026-11-18-r1` is version `2026.11.18.1`); the container layout reads the
  installed version from the quadlet with the same rule. New example recipe:
  npmplus (#92).
- `relrotate adopt <app>` without a version takes over an existing install:
  it writes the recipe (shipped example or `--source`) from the quadlet or
  unit found on the host, records the installed version, lists old updaters
  and runs the `doctor` checks (#88).
- The backup hooks in the headscale, lldap, vaultwarden and immich examples
  are commented out: backups are opt-in (#88).
- Security: with `QUADLET_USER` set, the quadlet is read and written by that
  account, never by root. Before, root created and renamed files in the
  owner's directory, where a planted symlink could redirect them (#105).
- `relrotate enable <app>` / `disable <app>` turn the app's timer on and off,
  so the unit name `relrotate@<app>.timer` need not be typed (#87).
- The release check no longer hangs for minutes on a large release list
  (headscale's is 2.5 MB); `doctor` says when it asks the release API (#90).
- `doctor` says whether a recipe takes a backup before updates and how to
  turn that off; the README says backups are optional (#93).
- `install.sh` and `relrotate enable` remind that mail and chat notifications
  are off until `MAIL_TO` or `NOTIFY` is set (#95).
- `relrotate setup` asks for a mail address and a chat destination (discord,
  ntfy, webhook) and writes them; `install.sh` runs it on a terminal when
  no notifications are set (#97).

## 0.3.0 (2026-11-17)

Upgrade notes (behaviour that changes for existing setups):

- `relrotate` exits 2 on unknown options or extra arguments, and on a bare
  call; `-n` is refused for `adopt` and `rollback`.
- Recipes that fail to load now: `HEALTH_RETRIES=0`, a non-number `KEEP`
  or `HEALTH_DELAY`, a relative `GPG_KEYRING`, an app name starting with `.`.
- A token file that is set but missing is an error, not a silent
  unauthenticated request; tokens are never sent to an `http://` SOURCE.
- An empty release list (`[]`) is a failed check (mailed once), not
  "up to date".
- The timer runs at 00/04/08/... plus up to 30 min, and catches up after
  downtime; a drop-in that set `OnUnitActiveSec=` should set `OnCalendar=`.
- With `ALLOW_PRERELEASE=yes`, release dirs named like `1.3.0-rc1` count
  for `KEEP` pruning; without it, suffixed dirs are never touched.
- **Hooks now run with errexit** (`post_extract`, `pre_update`, `post_flip`,
  `healthcheck`, `on_rollback`): the first failing step fails the hook,
  where before only the last step counted. End a step that may fail with
  `|| true`. Hooks run in a subshell, so they can no longer set variables
  for relrotate or for a later hook, and `exit` in a hook fails only it.

- Notifications: `NOTIFY=(kind:file ...)` sends to Discord, Telegram, ntfy
  or a JSON webhook besides mail; the secret stays in a root-only file and
  reaches curl on stdin. `NOTIFY_POLICY=each|failures|digest` sends
  failures at once and the rest in one summary per host
  (`relrotate digest`, `relrotate-digest.timer`, and the end of
  `update-all`).
- `MIN_AGE_DAYS`: a release installs only once it is that many days old
  (per recipe or global; a release without a date waits).
- `relrotate hold <app> [reason]` / `unhold <app>`.
- `relrotate status`: `HELD`, `CHECK-FAILED`, `SKIP` and `WAITING` flags;
  `status --json`.
- `relrotate doctor [app]`: recipe, newest release assets and checksum or
  signature files, paths, keyrings and notification setup, without
  changing anything.
- Containers: the digest of the replaced image is recorded and a rollback
  points the tag back at it; `PIN_DIGEST=yes` writes
  `Image=name:tag@sha256:...`.
- Backup helpers for hooks: `backup_sqlite DB [NAME]` and
  `backup_pg CONTAINER [DBUSER] [NAME]`, with `BACKUP_DIR` and
  `BACKUP_KEEP`; a failed or empty backup stops the update. The headscale,
  lldap, vaultwarden and immich examples use them, in the same backup
  directories as before. Upgrade note for those recipes: the directory is
  made 0700 and new backups 0600; the newest `BACKUP_KEEP` (5) backups of
  the new shape are kept, which includes existing vaultwarden
  `db-<version>-<stamp>.sqlite3` and immich `immich-<version>-<stamp>.sql.gz`
  files, so older ones of those are pruned; headscale (`.sqlite`) and lldap
  (`.db`) backups of the old names are left alone.
- `CHECKSUM_SIG_ASSET`: verify a signed checksum file (`SHA256SUMS.asc`)
  with gpgv before its hash.
- An unhealthy live version (a rollback whose health check failed) is
  marked `unhealthy`: `status` shows it, each timer run checks its health
  again, a later "ok" no longer hides it, and recovery is recorded and
  mailed once. `status` shows `UNHEALTHY(v)` and `INCOMPLETE(...)` flags
  before `last=`. A failed release check is mailed once per episode via a
  `check-failed` marker, so results written in between cannot restart it.
  A rollback where only a hook failed says "with problems",
  not UNHEALTHY. An automatic rollback that cannot switch back at all
  leaves the files on the new version, so it now blocks updates like an
  incomplete one (`relrotate rollback` finishes it).
- CLI: unknown options and extra arguments are rejected with the usage
  (exit 2) instead of ignored (`update app --dryrun` no longer runs live);
  `-n` is refused for `adopt` and `rollback`; bare `relrotate` prints the
  usage and exits 2. App names must start with a letter or digit (`.` and
  `..` are refused), also for `status <name>`. `adopt` takes the app lock.
  `update-all` gives each child `</dev/null` and passes `-v`.
- `HEALTH_RETRIES`, `HEALTH_DELAY` and `KEEP` are validated (`HEALTH_RETRIES=0`
  used to revert every update).
- Log values escape newlines and carriage returns, so a value cannot forge a
  log line; `app=` is quoted like other values.
- The run lock (fd 9) is closed for hooks, `sendmail` and `podman`, so a
  daemon forked by them cannot hold it forever. `sendmail` has a 60 s timeout.
- `TERM`/`INT` are trapped in `update` and `rollback` (exit 143/130): before
  anything changed the run records that; once files may change (from the
  start of the flip, or any rollback) the `incomplete` marker is written
  (updates blocked, `relrotate rollback` reverts) and mail is sent; after the
  outcome is recorded a signal leaves it alone.
- Mail: no abort when `hostname` is missing (falls back to
  `/proc/sys/kernel/hostname`); `MAIL_TO` set without a sendmail is a warning.
- Docs: hooks run without errexit (chain with `&&`; example recipes fixed),
  `RELROTATE_*` and sudo in SECURITY.md, uninstall section, `timeout` listed.
- Timer: `OnCalendar=*-*-* 00/4:00:00` with `RandomizedDelaySec` and
  `Persistent=true` (it did nothing without `OnCalendar`).
- `install.sh`: units use the configured `PREFIX`; `restorecon` covers
  `share/` and a failure is a warning before `daemon-reload`; the missing-tool
  hint names `util-linux` for flock.
- `examples/strict.conf`: optional paths (`-`), quadlet dirs and
  `/usr/local/bin`, notes on what `ProtectHome` breaks. Untested on a host.
- Release checks: an API failure, an empty response, or a list with
  releases but none usable (changed tag scheme) now fails loudly: `update`
  records `check failed: <reason>` in `last-result` and mails once, not on
  every timer run. The newest 100 GitHub (50 Gitea) releases are read, not
  30. A release with a null tag name is skipped. A tag with a trailing
  newline no longer passes. For downloading layouts, releases without the
  `ASSET` are passed over and a warning names the newest one lacking it.
- Versions: leading zeros are decimal (`2024.08.1`, `1.010.0`).
  `ALLOW_PRERELEASE=yes` accepts `X.Y.Z-rc1` tags and sorts them below the
  final release; `POLICY` uses the numeric part. `&` in a tag or version
  no longer breaks template expansion on bash 5.2.
- Tokens and curl: a token is never sent over `http://`; new optional
  `GITEA_TOKEN_HOSTS` limits the Gitea token to named hosts; an unreadable
  token file is an error. curl gets `--proto =https` (http only for an
  http `SOURCE`), `--proto-redir =https` and `--` before URLs.
- Verification: an empty `VERIFY` fails closed; checksum and sidecar files
  with CRLF line ends or a `./name` entry work; `GPG_KEYRING` must be an
  absolute path.
- Tests: the curl wrapper drops relrotate's own `--proto`/`--proto-redir`/`--`
  arguments and still imposes `=file`; a proto setting in `--config` is
  still refused.
- Container layout: backups are named per quadlet path, so two
  `CONTAINERS` entries with the same file name in different directories
  no longer share one backup. Backups from 0.2.0 are still found.
- A rollback that put some files back but then failed (a copy or
  `daemon-reload` error) is now reported as incomplete, instead of
  "nothing was switched, <version> is still live". The recorded versions
  stay as they were, `update` is blocked, and `relrotate rollback` retries
  the same rollback; `adopt` clears the block. A shared 0.2.0 backup is not
  used for two quadlets with the same file name; their images are rebuilt
  from the templates instead.
- Tests: `tests/run.sh` re-runs itself under `env -i` with a fake HOME, a
  PATH of stubs plus a short allowlist of host tools, and a preflight that
  refuses to start if sudo, a package manager, ssh, or a real
  systemctl/podman/runuser/curl is reachable. A stale `RELROTATE_TEST_T`
  in the environment cannot skip the scrub. The curl wrapper ignores
  `~/.curlrc` and runs the real curl with `--proto =file`, so no URL from
  the arguments or a `--config` can reach the network.
- Archive safety: `extract_to` now decides the format once and lists tar
  and zip archives before extracting, whatever the asset is called
  (`EXTRACT=tgz` on an extensionless asset was never checked, zip never).
  A listing that fails refuses the archive. After extraction, a symlink
  that is absolute or resolves outside the release refuses it too (tar and
  zip alike; checked on disk, so odd member names cannot hide one), and the
  refused tree is removed. Hardlinks are contained by GNU tar, which strips
  `/` and `..` from their targets; the tests cover both.
- CI (Forgejo): pull requests and pushes to `main` run only
  `tests/check.sh lint`, installing shellcheck only if the runner lacks
  it; the tests run once per release tag or on request. (#81)
- CI: the Forgejo workflow pins `actions/checkout` to the same commit as
  GitHub's (v7.0.1 on both code.forgejo.org and github.com).
- Docs: `CONTRIBUTING.md`, issue forms and a pull request template.
- CI: read-only `contents` permission and no persisted checkout
  credentials; GitHub's checkout action pinned to a commit, kept current
  by Dependabot.
- Releases: pushing a `v*` tag on GitHub builds `relrotate-X.Y.Z.tar.gz`
  (unpacks to `relrotate-X.Y.Z/`) and `SHA256SUMS`, and opens a draft
  release with that version's changelog section.
- Docs: Debian and Ubuntu are marked unverified.
- Internal: `lib/state.sh` owns the per-app state markers (set, get, clear,
  what blocks updates); no behaviour change. (#33)
- Internal: `lib/outcome.sh` decides the markers, last-result and alert after a
  revert; the health check result is a flag, not matched from text; no
  behaviour change. (#34)
- Internal: the layout seam is sealed: `stage` reports "already live" to the
  transaction instead of exiting, and `doctor` is a layout operation; no
  behaviour change. (#35)
- Internal: `lib/verify.sh` owns the VERIFY method list and what each needs from
  the release; `doctor` shares it, and fetches the release list once; no
  behaviour change. (#36)
- Internal: `lib/notify.sh` owns the notification policy, the outbox and the
  digest; each chat kind is a small payload adapter and one function makes the
  curl call; no behaviour change. (#37)
- A `VERIFY` with no method or an unknown one (`VERIFY=" "`, `gpg bogus`) is a recipe
  error (exit 2) when the recipe loads; it used to install unverified or fail at download. (#43)
- A failing `current_version` no longer kills `update`, `check` or `doctor` without a
  log line: `update` and `check` exit 1 naming it, `doctor` reports a FAIL, and
  `rollback` uses the recorded installed version. (#44)
- The installed version must be a version: a leading `v` and surrounding
  whitespace are dropped (`v1.2.3`, a CR in a hand-edited `installed` file),
  anything else from `current_version`, the state or `adopt` (`app 1.0.0`,
  `latest`) is refused with exit 2 instead of making every run "up to date"
  forever. `rollback` falls back to the recorded version. (#45)
- Release asset names that are not plain file names (a `/`, `.`, `..`, empty)
  are refused before anything is downloaded, so a hostile release API cannot
  write outside the work directory; downloads run with `curl --globoff`. (#46)
- Version comparison: a release version with a component of more than 9 digits is
  dropped like any unparsable tag (it used to wrap around in the policy check),
  and versions that differ only in spelling (`1.9`, `1.9.0`, `01.9.0`) are equal
  for the newer-than test and for `skip`. Recorded names keep the tag spelling. (#47)
- Archives: an archive with a member that is not a file, directory or link (FIFO,
  device) is refused before extracting; tar runs with `--no-same-owner`
  so as root archive owners are not kept, and setuid/setgid bits are removed
  from the extracted tree; other modes are kept whatever the umask. (#48)
- Containers: an update refuses when a quadlet's `Image=` is not on the recorded
  version (a run killed after the flip), instead of overwriting the old
  version's backup with the new quadlet; the log says what was found and to
  run `relrotate adopt` or restore the quadlet by hand. Recipes with a constant tag (`:latest`), a digest-only
  `Image=` line or trailing blanks on it are not affected. (#49)
- `rollback` records `skip` before `installed` and `previous`, so a run killed
  in between cannot leave the timer reinstalling the version just rolled away from. (#50)
- When the state directory cannot be written after the flip (full or read-only
  filesystem), the update logs `event=state-write-failed` and sends an alert saying
  which version is live and to run `relrotate adopt` once fixed, instead of
  dying silently with exit 1. (#51)
- Binary layout: the backup of the running binary and the stored new version are
  written under a `.part` name and moved into place, so a kill mid-copy no longer
  leaves a truncated file that `rollback` would install. At the start of a real
  update (lock held) leftover `work.*` dirs in the state dir and, for the symlink
  layout, `*.relrotate-new` dirs in `RELEASES_DIR` are removed. (#52)
- Containers with a tag that never names the version (`:latest`): when a later pull
  fails, or the quadlet rewrite or `daemon-reload` fails after the pulls, the tags the
  pulls moved are pointed back at the digests recorded before the pull, so a
  restart or reboot does not run the image of an update that "changed nothing"
  (a retag that fails is logged as an error). (#53)
- With several units in `SERVICE`, a revert tries every unit even when one restart
  fails, so none is left stopped; the update itself still stops at the first
  failing restart, so later units never run the new version. (#54)
- The summary no longer stalls on a destination that keeps failing: every
  destination gets the events it has not had yet, once each; a failing one
  keeps what it missed (at most the newest 1000, with a warning when older
  ones are dropped) and gets it when it works again. A queue line that is JSON
  but no event is dropped like a torn one. (#55)
- A release whose asset or image is not there yet no longer alerts on every timer
  run: a failure before the install (and a run stopped before the switch) alerts
  once per version and reason, and again only when the reason changes or after a
  success (state file `failed-notified`). (#56)
- A hanging notification destination holds the app lock for at most 20 s per send
  (was 60 s: two dead destinations and two events kept an update busy for four
  minutes). The payload (chat id, message text) goes to curl on stdin with the
  URL, so it no longer shows in `ps`. (#57)
- `relrotate` finds its libraries in `PREFIX/lib/relrotate` when installed with a
  `PREFIX` other than `/usr/local`; `install.sh` says what is installed and what to
  run by hand when `systemctl daemon-reload` fails, instead of exiting silently. (#58)
- `doctor` fails (and names the file) for a config dir, `apps.d`, `relrotate.conf`,
  recipe or GPG keyring that is not owned by root or the invoking user, or is group- or world-writable, and for
  token and notify files that group or others can read. Updates still run. (#59)
- container layout: the quadlet edit follows a symlink (the link stays a link and the
  target is updated), rewrites only the last `Image=` of `[Container]` (the one systemd uses; a line continued with a trailing backslash is refused) (not comments or
  other sections), accepts `Image = x` with blanks around the `=` and no longer treats `&`
  or `\` in the image as sed syntax; one parser serves detect, the guard and the rewrite. (#60)
- Docs: README states the bash 5.1 floor and has a "Known limits" section (sandbox
  options not confirmed on a real host, lingering for `QUADLET_USER`, podman on Debian 12,
  `MIN_AGE_DAYS`, "already live" after a crash, constant tags, no download size cap). (#61)

## 0.2.1 (2026-11-14)

- symlink layout: refuse to restage a release that is already live. After
  a failed rollback the new release stays live while state still names the
  old version; the next run picked the live version again and `rm -rf`'d the
  directory being served. Now it changes nothing and mails the
  `relrotate adopt` command to run.

## 0.2.0 (2026-11-13)

First public release.

- Layouts: `symlink` (web apps in versioned release directories),
  `binary` (single executables, the pre-relrotate binary kept for
  rollback) and `container` (podman quadlet `Image=` tags).
- Container sets: `CONTAINERS=()` pulls every image first, flips all
  quadlets with one daemon-reload and rolls them back together.
- Release sources: GitHub and Gitea/Forgejo/Codeberg, with optional API
  tokens and a plain `relrotate/<version>` User-Agent.
- Verification: `api-digest`, `sha256-sidecar`, `checksums-file`, `gpg`,
  several at once, or an explicit `none`.
- Policy: `patch`, `minor`, `major`; for `0.x` versions `minor` means
  patches only. Out-of-policy releases get one mail, not an install.
- Every failure after the flip rolls back; a failing `on_rollback` hook,
  restart or health check during a rollback is reported, not hidden.
  `relrotate rollback` records what actually runs and skips the version
  it rolled away from until a newer release appears.
- Dry run (`update -n`) downloads and verifies only.
- Assets: tar (gz, xz, bz2, zst), zip, and single `.gz`/`.xz`/`.bz2` files.
- 20 example recipes, each checked against the project's real releases.
- systemd template service and timer, one per app.
