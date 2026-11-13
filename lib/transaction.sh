# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate: the update and rollback transactions.
#
#   transaction_apply      install VERSION over OLD_VERSION (what update runs)
#   transaction_rollback   make OLD_VERSION live again (what rollback runs)
#
# The rule: before the flip, a failure changes nothing and says so; after
# the flip, every failure reverts. A revert carries on past a failing
# on_rollback hook, restart or health check and reports all of them.
# installed, previous, skip and last-result change only here (and adopt).

# state_set NAME VALUE: atomic write of one state file; every state write
# goes through it, so a crash never leaves an empty "installed".
state_set() {
    printf '%s\n' "$2" > "$STATE_DIR/$1.tmp" && mv -f "$STATE_DIR/$1.tmp" "$STATE_DIR/$1"
}

# revert_to VER: make VER live, then hook, restart, health check.
# Sets REVERT_SWITCHED=1 once the files are on VER and REVERT_PROBLEMS to a
# "; "-joined list of what failed. Returns 0 only if nothing failed.
revert_to() {
    local to="$1"
    REVERT_SWITCHED=0 REVERT_PROBLEMS=""
    if ! layout revert "$to"; then
        REVERT_PROBLEMS="switching back to $to failed"
        return 1
    fi
    REVERT_SWITCHED=1
    if declare -F on_rollback >/dev/null && ! on_rollback; then
        log err msg="on_rollback hook failed"
        revert_problem "on_rollback hook failed"
    fi
    restart_service || revert_problem "restart failed"
    run_healthcheck || revert_problem "health check failed"
    [[ -z "$REVERT_PROBLEMS" ]]
}
revert_problem() { REVERT_PROBLEMS+="${REVERT_PROBLEMS:+; }$1"; }

# Failure before the flip: nothing changed. Exits.
fail_update() {
    local reason="$1"
    log err event=update-failed version="${VERSION:-?}" reason="$reason"
    (( ! DRY_RUN )) || exit 1
    state_set last-result "failed ${VERSION:-?} ($reason), nothing changed"
    notify "update to ${VERSION:-?} failed before install" \
        "relrotate could not update $APP to ${VERSION:-?}: $reason. Nothing was changed; $OLD_VERSION is still running. It will retry on the next timer run."
    exit 1
}

# Failure after the flip: go back to OLD_VERSION, which is still recorded
# as installed. Returns 1.
revert_update() {
    local reason="$1"
    log err event=rollback reason="$reason" from="$VERSION" to="$OLD_VERSION"
    if revert_to "$OLD_VERSION"; then
        state_set last-result "failed $VERSION ($reason), rolled back to $OLD_VERSION"
        notify "FAILED $VERSION, rolled back to $OLD_VERSION" \
            "relrotate tried to update $APP to $VERSION and it failed: $reason. Rolled back to $OLD_VERSION and the health check passes. Nothing else to do unless it keeps happening."
    elif (( REVERT_SWITCHED )) && [[ "$REVERT_PROBLEMS" != *"health check failed"* ]]; then
        state_set last-result "failed $VERSION ($reason), rolled back to $OLD_VERSION; $REVERT_PROBLEMS"
        notify "FAILED $VERSION, rolled back to $OLD_VERSION with problems" \
            "relrotate tried to update $APP to $VERSION and it failed: $reason. Rolled back to $OLD_VERSION and the health check passes, but: $REVERT_PROBLEMS. Check what the hook was meant to do."
    else
        state_set last-result "failed $VERSION ($reason), ROLLBACK ALSO FAILED: $REVERT_PROBLEMS"
        notify "FAILED $VERSION and ROLLBACK FAILED" \
            "relrotate tried to update $APP to $VERSION and it failed: $reason. Rolling back to $OLD_VERSION did not bring it back healthy: $REVERT_PROBLEMS. Manual attention needed."
    fi
    return 1
}

transaction_apply() {
    log info event=update-start from="$OLD_VERSION" to="$VERSION"
    WORK="$(mktemp -d "$STATE_DIR/work.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT

    if layout needs_download; then
        download_and_verify || fail_update "download/verification failed"
    fi
    if (( DRY_RUN )); then
        log info event=dry-run version="$VERSION" note="verified, not installed"
        return 0
    fi

    layout stage || fail_update "staging failed"
    if declare -F post_extract >/dev/null; then
        post_extract || fail_update "post_extract hook failed"
    fi
    if declare -F pre_update >/dev/null; then
        pre_update || fail_update "pre_update hook failed"
    fi

    local flip_rc=0
    layout flip || flip_rc=$?
    case "$flip_rc" in
        0) ;;
        1) fail_update "flip failed" ;;
        *) revert_update "flip failed half-way"; return 1 ;;
    esac
    # --- past the flip: every failure reverts ---
    if declare -F post_flip >/dev/null; then
        post_flip || { revert_update "post_flip hook failed"; return 1; }
    fi
    restart_service || { revert_update "restart failed"; return 1; }
    run_healthcheck || { revert_update "health check failed"; return 1; }

    state_set previous "$OLD_VERSION"
    state_set installed "$VERSION"
    state_set last-result "updated $OLD_VERSION -> $VERSION"
    layout prune
    log info event=updated from="$OLD_VERSION" to="$VERSION"
    notify "updated $OLD_VERSION -> $VERSION" \
        "relrotate updated $APP on $(hostname -f 2>/dev/null || hostname) from $OLD_VERSION to $VERSION (policy=$POLICY, layout=$LAYOUT)."
}

# Manual rollback from VERSION (installed) to OLD_VERSION (previous).
# Once the files are on OLD_VERSION the state says so, even when the
# restart or health check then fails. Mails only on failure.
transaction_rollback() {
    local cur="$VERSION" prev="$OLD_VERSION"
    log info event=manual-rollback from="$cur" to="$prev"
    if revert_to "$prev"; then
        :
    elif (( ! REVERT_SWITCHED )); then
        log err event=manual-rollback-failed reason="$REVERT_PROBLEMS" live="$cur"
        state_set last-result "manual rollback to $prev FAILED ($REVERT_PROBLEMS); $cur still live"
        notify "manual rollback to $prev FAILED" \
            "relrotate rollback $APP: $REVERT_PROBLEMS. Nothing was switched; $cur is still live. Check the stored versions under $STATE_DIR and the layout target."
        echo "$APP: rollback to $prev failed ($REVERT_PROBLEMS); $cur is still live." >&2
        return 1
    fi

    state_set installed "$prev"
    state_set previous "$cur"
    # Skip the version we rolled away from so the timer does not
    # immediately reinstall it; a newer release clears this.
    state_set skip "$cur"
    if [[ -z "$REVERT_PROBLEMS" ]]; then
        state_set last-result "manual rollback $cur -> $prev"
        log info event=rolled-back to="$prev" skip="$cur"
        echo "$APP rolled back to $prev; $cur will be skipped until a newer release appears."
        return 0
    fi
    state_set last-result "manual rollback $cur -> $prev, UNHEALTHY: $REVERT_PROBLEMS"
    log err event=rolled-back-unhealthy to="$prev" skip="$cur" problems="$REVERT_PROBLEMS"
    notify "manual rollback to $prev: UNHEALTHY" \
        "relrotate rollback $APP switched back to $prev, but: $REVERT_PROBLEMS. $prev is now live and recorded as installed; $cur is skipped until a newer release appears. Fix $prev, or go forward by hand (relrotate adopt after a manual install)."
    echo "$APP: rolled back to $prev, but $REVERT_PROBLEMS." >&2
    return 1
}
