# shellcheck shell=bash
# relrotate: the per-app state markers under $STATE_DIR.
#
#   state_set NAME VALUE   atomic write of one marker
#   state_get NAME         print its value (nothing when unset or empty)
#   state_has NAME         is it set
#   state_clear NAME...    remove markers
#   state_blocked          are updates blocked by an incomplete rollback
#
# One file per marker: installed, previous, last-check, last-result, waiting,
# notified, check-failed, failed-notified, skip, held, unhealthy, incomplete. Meaning:
# "failed-notified" is "VERSION REASON" of the last alert for a failure before
# the install (one alert per version and reason). "incomplete" blocks updates, "held" skips them, "unhealthy" names a live
# version that failed its health check, "skip" names a version not to install.

# state_set NAME VALUE: atomic write of one state file; every state write
# goes through it, so a crash never leaves an empty "installed".
state_set() {
    printf '%s\n' "$2" > "$STATE_DIR/$1.tmp" && mv -f "$STATE_DIR/$1.tmp" "$STATE_DIR/$1"
}

# state_has NAME: set and not empty (state_set never writes an empty file).
state_has() { [[ -s "$STATE_DIR/$1" ]]; }

# state_get NAME: the value, or nothing; always returns 0 (safe under errexit).
state_get() { if state_has "$1"; then cat "$STATE_DIR/$1"; fi; }

# state_clear NAME...: remove markers; absent ones are fine.
state_clear() {
    local n
    for n in "$@"; do rm -f -- "$STATE_DIR/$n"; done
}

# state_blocked: when an incomplete rollback blocks updates, print the version
# it was going to and return 0; otherwise return 1.
state_blocked() { state_has incomplete && state_get incomplete; }
