# Security

relrotate runs as root and installs software, so security reports matter.

## Reporting a vulnerability

Please report it privately through GitHub's
[private vulnerability reporting](https://github.com/raatti/relrotate/security/advisories/new),
not in a public issue. Include the relrotate version (`relrotate --version`),
the recipe involved, and how to reproduce it.

## Supported versions

Only the latest release gets fixes.

## Scope notes

- Recipes are shell sourced as root: whoever can write
  `/etc/relrotate/apps.d/` can run code as root. That is by design.
- relrotate honours `RELROTATE_*` environment variables (`RELROTATE_LIB_DIR`,
  `RELROTATE_CURL`, `RELROTATE_SYSTEMCTL`, `RELROTATE_PODMAN`,
  `RELROTATE_SENDMAIL`, ...) and runs what they name as root. Sudo rules
  that let a user run relrotate must not keep the caller's environment:
  no `SETENV`, no `-E`, and no `env_keep` for `RELROTATE_*`.
- `VERIFY` checks downloaded release assets. Container images are pulled
  by tag (`PIN_DIGEST=yes` then pins what was pulled); verify them with a
  podman signature policy (`containers-policy.json(5)`).
- `NOTIFY` destination files hold secrets (a Discord webhook URL, a Telegram
  bot token): keep them root-only, like the token files. relrotate passes
  them to curl on stdin and never logs them. Message text comes partly from
  upstream release data (tags); Discord mentions are disabled.
