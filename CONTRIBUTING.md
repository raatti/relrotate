# Contributing

Thanks for helping. For what relrotate does and how recipes work, read
[README.md](README.md). Security problems go through
[SECURITY.md](SECURITY.md), never a public issue.

## Setup

You need `bash`, `shellcheck`, `jq`, `curl`, `bzip2`, `xz`, `unzip` and `zip` (the zip test is skipped without it).
No root and no network are needed: the tests serve fake releases from
`file://` URLs and stub `systemctl` and `podman`.

```bash
tests/check.sh
```

`tests/check.sh` is the one check (`bash -n`, shellcheck, then
`tests/run.sh`). Run it before you open a pull request: on Forgejo, CI
runs only its lint part on a pull request and the tests once per release.
Add a line to [CHANGELOG.md](CHANGELOG.md) under `Unreleased` for
anything a user would notice.

## Module map

- `relrotate`: the CLI, argument parsing and the commands.
- `lib/common.sh`: logging, config, locking, mail, version helpers.
- `lib/source.sh`: release sources (GitHub, Gitea/Forgejo/Codeberg).
- `lib/verify.sh`: download and verification (`VERIFY=` methods).
- `lib/layout.sh`: layout dispatch; each op calls `layout_<name>_<op>`.
  Adapters: `lib/layout-binary.sh`, `lib/layout-symlink.sh`,
  `lib/layout-container.sh`.
- `lib/transaction.sh`: the update and rollback transactions. Before the
  flip a failure changes nothing; after it, every failure reverts.
- `tests/run.sh`: end-to-end tests. `examples/apps.d/`: example recipes.

## Recipe pull requests

A recipe is checked against the real project's releases, not just the
stubbed tests. In the pull request, show:

- the OS and host type you ran it on;
- a real `relrotate update <app>` run and a real `relrotate rollback <app>`
  run for that app;
- the relevant log lines from both;
- no secrets: remove tokens, hostnames you do not want public and mail
  addresses.
