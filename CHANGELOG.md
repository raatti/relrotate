# Changelog

## Unreleased

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
