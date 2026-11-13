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
- `VERIFY` checks downloaded release assets. Container images are pulled
  by tag; verify them with a podman signature policy
  (`containers-policy.json(5)`).
