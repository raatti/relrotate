#!/usr/bin/env bash
# Every check CI runs, in one place, so a local run matches the runner:
# bash syntax, shellcheck on scripts and on shell-sourced configs, tests.
# Needs: bash, shellcheck, and what tests/run.sh needs (jq, curl, bzip2, ...).
#   tests/check.sh lint   only the syntax check and shellcheck (seconds)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

scripts=(relrotate install.sh lib/*.sh tests/*.sh)
# Recipes and the global config are sourced as bash. examples/strict.conf
# is a systemd drop-in, not shell, so it is left out.
configs=(etc/relrotate.conf examples/apps.d/*.conf)

echo "== bash -n"
for f in "${scripts[@]}" "${configs[@]}"; do
    bash -n "$f"
done

echo "== shellcheck $(shellcheck --version | sed -n 's/^version: //p')"
shellcheck -x "${scripts[@]}"
shellcheck -x -s bash "${configs[@]}"

[[ "${1:-}" != lint ]] || exit 0

echo "== tests"
bash tests/run.sh
