# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# relrotate: what a finished transaction records, and who is told.
#
#   outcome_nothing_changed REASON   a failure before the flip
#   outcome_already_live             stage found VERSION live, state behind
#   outcome_update_reverted REASON   after revert_to, for a failed update
#   outcome_rollback                 after revert_to, for relrotate rollback
#   outcome_recheck                  the unhealthy-version recheck in update
#   set_health VER                   mark VER unhealthy, or clear the mark
#
# A transaction only runs its steps; the markers (state.sh), the last-result
# text (commit_result) and the alert (notify) are decided here, from the
# REVERT_* result of revert_to: REVERT_SWITCHED, REVERT_INCOMPLETE,
# REVERT_UNHEALTHY (the health check failed) and REVERT_PROBLEMS.
# Needs commit_result, notify and log; the caller sets VERSION, OLD_VERSION, APP.
# A new kind of outcome (say "already live") is one more function here.

# revert_case: set REVERT_CASE from the REVERT_* result.
#   clean       nothing failed
#   incomplete  files changed but the revert did not finish: files may be mixed
#   unswitched  nothing changed: the files are where they were before the revert
#   problems    switched and healthy, but a hook or restart failed
#   unhealthy   switched, but the health check failed
revert_case() {
    if [[ -z "$REVERT_PROBLEMS" ]]; then REVERT_CASE=clean
    elif (( REVERT_INCOMPLETE )); then REVERT_CASE=incomplete
    elif (( ! REVERT_SWITCHED )); then REVERT_CASE=unswitched
    elif (( REVERT_UNHEALTHY )); then REVERT_CASE=unhealthy
    else REVERT_CASE=problems; fi
}

# set_health VER: after a revert, record whether VER (now live) failed its
# health check. Only the health check decides; a failed hook does not.
set_health() {
    if (( REVERT_UNHEALTHY )); then
        state_set unhealthy "$1"
    else
        state_clear unhealthy
    fi
}

# state_set_alert NAME VALUE ON_DISK: state_set for a record written after
# files changed. When it fails (full or read-only filesystem) the run would
# otherwise die under errexit with no log line and no mail while the state
# disagrees with the files: log it, alert, and return 1 so the caller stops.
state_set_alert() {
    local name="$1" value="$2" on_disk="$3" recorded
    state_set "$name" "$value" && return 0
    recorded="$(state_get installed)"
    log err event=state-write-failed marker="$name" live="$on_disk" recorded="${recorded:-none}"
    notify "state write FAILED for $APP, $on_disk is on disk" \
        "relrotate could not write $name in $STATE_DIR (full or read-only filesystem?). On disk: $on_disk. The state says ${recorded:-nothing}. Fix the filesystem, check what runs, then run: relrotate adopt $APP <version> (the version that is live)."
    return 1
}

# notify_once REASON SUBJECT BODY: a failure before the flip alerts once per
# version and reason (REASON is a fixed phrase, never a path or a time), like
# fetch_fail with check-failed. The "failed-notified" marker holds
# "VERSION REASON [STEP]" (STEP: what download_and_verify was doing, so a
# checksum mismatch is not hidden by an earlier download failure); a success clears it. Always returns 0.
notify_once() {
    local key="${VERSION:-?} $1${FAIL_STEP:+ $FAIL_STEP}"
    [[ "$(state_get failed-notified)" != "$key" ]] || return 0
    notify "$2" "$3"
    state_set failed-notified "$key" || true
}

# Failure before the flip: nothing changed. The caller exits.
outcome_nothing_changed() {
    local reason="$1"
    commit_result "failed ${VERSION:-?} ($reason), nothing changed"
    notify_once "$reason" "update to ${VERSION:-?} failed before install" \
        "relrotate could not update $APP to ${VERSION:-?}: $reason. Nothing was changed; $OLD_VERSION is still running. It will retry on the next timer run and does not alert again for the same failure."
}

# layout stage returned 3: VERSION is live but state names OLD_VERSION, and
# RELEASE_DIR is where it lives. Nothing was changed. The caller exits.
outcome_already_live() {
    log err event=state-behind live="$VERSION" recorded="$OLD_VERSION"
    commit_result "refused: $VERSION already live, state says $OLD_VERSION"
    notify "$VERSION is already live, state says $OLD_VERSION" \
        "relrotate update $APP: $TARGET already points at $RELEASE_DIR, but the recorded version is $OLD_VERSION (an earlier rollback probably failed). Nothing was changed. Check that $VERSION works, then run: relrotate adopt $APP $VERSION"
}

# Failure after the flip, after revert_to OLD_VERSION: OLD_VERSION is still
# recorded as installed.
outcome_update_reverted() {
    local reason="$1"
    revert_case
    case "$REVERT_CASE" in
    clean)
        set_health "$OLD_VERSION"
        commit_result "failed $VERSION ($reason), rolled back to $OLD_VERSION"
        notify "FAILED $VERSION, rolled back to $OLD_VERSION" \
            "relrotate tried to update $APP to $VERSION and it failed: $reason. Rolled back to $OLD_VERSION and the health check passes. Nothing else to do unless it keeps happening." ;;
    incomplete)
        # Files may be mixed. Block the timer: another update would back up
        # mixed files as $OLD_VERSION and lose the good backups.
        state_set_alert incomplete "$OLD_VERSION" "$VERSION or a mix of it with $OLD_VERSION" || return 0
        commit_result "failed $VERSION ($reason), ROLLBACK INCOMPLETE: $REVERT_PROBLEMS; updates blocked until: relrotate rollback $APP"
        notify "FAILED $VERSION and ROLLBACK INCOMPLETE" \
            "relrotate tried to update $APP to $VERSION and it failed: $reason. Rolling back to $OLD_VERSION was only partly done: $REVERT_PROBLEMS. Some files may still be on $VERSION, or systemd did not reload them. Updates are blocked; fix the cause and run: relrotate rollback $APP" ;;
    problems)
        set_health "$OLD_VERSION"
        commit_result "failed $VERSION ($reason), rolled back to $OLD_VERSION; $REVERT_PROBLEMS"
        notify "FAILED $VERSION, rolled back to $OLD_VERSION with problems" \
            "relrotate tried to update $APP to $VERSION and it failed: $reason. Rolled back to $OLD_VERSION and the health check passes, but: $REVERT_PROBLEMS. Check what the hook was meant to do." ;;
    unswitched)
        # The files are still on $VERSION while installed names $OLD_VERSION:
        # block, as for an incomplete revert, so the next update cannot back
        # up $VERSION's files as $OLD_VERSION.
        state_set_alert incomplete "$OLD_VERSION" "$VERSION (partly)" || return 0
        commit_result "failed $VERSION ($reason), ROLLBACK FAILED, files still (partly) on $VERSION: $REVERT_PROBLEMS; updates blocked until: relrotate rollback $APP"
        notify "FAILED $VERSION and ROLLBACK FAILED" \
            "relrotate tried to update $APP to $VERSION and it failed: $reason. Switching back to $OLD_VERSION failed too: $REVERT_PROBLEMS. The files are still on $VERSION, or partly so after a half-way flip. Updates are blocked; fix the cause and run: relrotate rollback $APP" ;;
    unhealthy)
        set_health "$OLD_VERSION"
        commit_result "failed $VERSION ($reason), ROLLBACK ALSO FAILED: $REVERT_PROBLEMS"
        notify "FAILED $VERSION and ROLLBACK FAILED" \
            "relrotate tried to update $APP to $VERSION and it failed: $reason. Rolling back to $OLD_VERSION did not bring it back healthy: $REVERT_PROBLEMS. Manual attention needed; every timer run checks its health again." ;;
    esac
}

# outcome_maintenance REASON PAGE_RC: a security release failed after the
# flip and was not reverted (#131). installed stays OLD_VERSION and nothing
# is skipped: every timer run tries VERSION again; a pass clears the marker.
outcome_maintenance() {
    local reason="$1" page="the maintenance page is up"
    (( $2 == 0 )) || page="the maintenance page could NOT be put up, so $VERSION is still live"
    state_set_alert maintenance "$VERSION" "$VERSION or the maintenance page" || return 0
    # A symlink app may have no recorded version (it is read from the link,
    # which now names the page): record it, for the retry and for rollback.
    state_set_alert installed "$OLD_VERSION" "the maintenance page" || return 0
    commit_result "failed $VERSION ($reason): security release, MAINTENANCE instead of $OLD_VERSION; $page; retried on every timer run"
    notify_once maintenance "MAINTENANCE: security release $VERSION failed" \
        "relrotate updated $APP to $VERSION, a security release, and it failed: $reason. It was not rolled back to $OLD_VERSION, which that release fixes: $page. Every timer run tries $VERSION again, and the app is back once it passes. Fix the cause, or wait for a newer release. To serve $OLD_VERSION anyway: relrotate rollback $APP (it skips $VERSION)."
}

# Manual rollback from VERSION (installed) to OLD_VERSION (previous), after
# revert_to OLD_VERSION. Once the files are on OLD_VERSION the state says so,
# even when the restart or health check then fails. Returns the exit status
# of the command: 0 only when nothing failed. Mails only on failure.
outcome_rollback() {
    # An unreadable current version (broken binary) is "unknown": never recorded.
    local cur="${VERSION:-unknown}" prev="$OLD_VERSION"
    revert_case
    case "$REVERT_CASE" in
    unswitched)
        if state_blocked >/dev/null; then
            # A retry that changed nothing: the earlier partial revert still stands.
            log err event=manual-rollback-failed reason="$REVERT_PROBLEMS" incomplete="$prev"
            commit_result "manual rollback to $prev INCOMPLETE, retry changed nothing ($REVERT_PROBLEMS); updates blocked until: relrotate rollback $APP"
            notify "manual rollback to $prev still INCOMPLETE" \
                "relrotate rollback $APP: retrying the incomplete rollback to $prev changed nothing: $REVERT_PROBLEMS. Files may still be partly on $cur. Updates stay blocked; fix the cause and run: relrotate rollback $APP"
            echo "$APP: retrying the rollback to $prev changed nothing ($REVERT_PROBLEMS); files may still be mixed." >&2
        else
            log err event=manual-rollback-failed reason="$REVERT_PROBLEMS" live="$cur"
            commit_result "manual rollback to $prev FAILED ($REVERT_PROBLEMS); $cur still live"
            notify "manual rollback to $prev FAILED" \
                "relrotate rollback $APP: $REVERT_PROBLEMS. Nothing was switched; $cur is still live. Check the stored versions under $STATE_DIR and the layout target."
            echo "$APP: rollback to $prev failed ($REVERT_PROBLEMS); $cur is still live." >&2
        fi
        return 1 ;;
    incomplete)
        # Files may be mixed: keep installed/previous/skip as they were, so
        # running rollback again retries the same revert.
        state_set incomplete "$prev"
        log err event=manual-rollback-incomplete to="$prev" problems="$REVERT_PROBLEMS"
        commit_result "manual rollback to $prev INCOMPLETE: $REVERT_PROBLEMS; updates blocked until: relrotate rollback $APP"
        notify "manual rollback to $prev INCOMPLETE" \
            "relrotate rollback $APP was only partly done: $REVERT_PROBLEMS. Some files may still be on $cur, or systemd did not reload them. Updates are blocked; fix the cause and run: relrotate rollback $APP"
        echo "$APP: rollback to $prev incomplete ($REVERT_PROBLEMS). Fix the cause and run rollback again." >&2
        return 1 ;;
    esac

    local moved=0
    [[ "$cur" == unknown || "$prev" == "$cur" ]] || moved=1
    # Skip first, so a crash after "installed" never leaves the timer free to
    # reinstall the version we rolled away from; a newer release clears it.
    # --no-skip (a test rollback) leaves it free on purpose.
    if (( moved && ! ${NO_SKIP:-0} )); then state_set skip "$cur"; fi
    state_set installed "$prev"
    if (( moved )); then state_set previous "$cur"; fi
    # Last: a crash before this leaves updates blocked, never unblocked
    # with installed still naming the version we rolled away from.
    state_clear incomplete failed-notified maintenance
    # prev == cur: finishing an automatic rollback that was left incomplete.
    local what="manual rollback $cur -> $prev" skipped="; $cur will be skipped until a newer release appears (relrotate unskip $APP clears that)"
    [[ "$prev" != "$cur" ]] || { what="finished rollback to $prev"; skipped=""; }
    [[ "$cur" != unknown ]] && (( ! ${NO_SKIP:-0} )) || skipped=""
    set_health "$prev"
    case "$REVERT_CASE" in
    clean)
        commit_result "$what"
        log info event=rolled-back to="$prev" skip="${skipped:+$cur}"
        echo "$APP rolled back to $prev$skipped."
        return 0 ;;
    problems)
        # Healthy, but a hook or restart reported a problem.
        commit_result "$what, with problems: $REVERT_PROBLEMS"
        log err event=rolled-back-with-problems to="$prev" problems="$REVERT_PROBLEMS"
        notify "manual rollback to $prev: with problems" \
            "relrotate rollback $APP switched back to $prev and the health check passes, but: $REVERT_PROBLEMS."
        echo "$APP: rolled back to $prev, but $REVERT_PROBLEMS." >&2
        return 1 ;;
    unhealthy)
        commit_result "$what, UNHEALTHY: $REVERT_PROBLEMS"
        log err event=rolled-back-unhealthy to="$prev" skip="${skipped:+$cur}" problems="$REVERT_PROBLEMS"
        notify "manual rollback to $prev: UNHEALTHY" \
            "relrotate rollback $APP switched back to $prev, but: $REVERT_PROBLEMS. $prev is now live and recorded as installed$skipped. Every timer run checks its health again and mails when it passes. Fix $prev, or go forward by hand (relrotate adopt after a manual install)."
        echo "$APP: rolled back to $prev, but $REVERT_PROBLEMS." >&2
        return 1 ;;
    esac
}

# The live version CUR is recorded as unhealthy: after run_healthcheck
# (HEALTHY), record that it recovered or still fails. Always returns 0.
outcome_recheck() {
    local cur="$1"
    if (( HEALTHY )); then
        state_clear unhealthy
        state_set last-result "healthy again: $cur passes its health check"
        log info event=healthy-again version="$cur"
        notify "$cur healthy again" "relrotate: $APP $cur, recorded as unhealthy, passes its health check again." info
    else
        state_set last-result "still UNHEALTHY: $cur fails its health check (checked $(date -Is))"
        log err event=still-unhealthy version="$cur"
    fi
}
