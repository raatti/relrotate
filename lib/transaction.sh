# shellcheck shell=bash
# shellcheck disable=SC2153  # recipe variables are set in load_recipe()
# shellcheck disable=SC2034  # REVERT_* are read in lib/outcome.sh
# relrotate: the update and rollback transactions.
#
#   transaction_apply      install VERSION over OLD_VERSION (what update runs)
#   transaction_rollback   make OLD_VERSION live again (what rollback runs)
#
# The rule: before the flip, a failure changes nothing and says so; after
# the flip, every failure reverts. A revert carries on past a failing
# on_rollback hook, restart or health check and reports all of them.
# The transactions run the steps; lib/outcome.sh decides what to record and
# who to tell. installed, previous, skip, incomplete, unhealthy and last-result
# change only there (and in adopt).
# "incomplete" holds the version a partial revert was going to; while it
# exists updates refuse and rollback retries that revert.
# "unhealthy" names a live version whose health check failed; while it
# exists every update run checks health again and never records plain "ok".

# revert_to VER: make VER live, then hook, restart, health check.
# layout revert returns 0 done, 1 nothing changed, 2 changed but incomplete.
# Sets REVERT_SWITCHED=1 once files changed, REVERT_INCOMPLETE=1 when the layout
# changed files but did not finish (rc 2), REVERT_UNHEALTHY=1 when the health
# check failed, and REVERT_PROBLEMS to a "; "-joined list of what failed (empty:
# nothing failed). lib/outcome.sh turns these into markers, record and alert. Always returns 0, and must be
# called as a plain statement: its hooks run with errexit (see run_hook).
revert_to() {
    local to="$1"
    REVERT_SWITCHED=0 REVERT_INCOMPLETE=0 REVERT_UNHEALTHY=0 REVERT_PROBLEMS=""
    local rc=0
    layout revert "$to" || rc=$?
    case "$rc" in
        0) ;;
        2) REVERT_INCOMPLETE=1
           revert_problem "switching back to $to incomplete" ;;
        *) REVERT_PROBLEMS="switching back to $to failed"; return 0 ;;
    esac
    REVERT_SWITCHED=1
    run_hook on_rollback
    if (( HOOK_RC != 0 )); then
        log err msg="on_rollback hook failed" rc="$HOOK_RC"
        revert_problem "on_rollback hook failed"
    fi
    restart_service all || revert_problem "restart failed"
    run_healthcheck
    (( HEALTHY )) || { REVERT_UNHEALTHY=1; revert_problem "health check failed"; }
    return 0
}
revert_problem() { REVERT_PROBLEMS+="${REVERT_PROBLEMS:+; }$1"; }

# Failure before the flip: nothing changed. Exits.
fail_update() {
    local reason="$1"
    log err event=update-failed version="${VERSION:-?}" reason="$reason"
    (( ! DRY_RUN )) || exit 1
    outcome_nothing_changed "$reason"
    exit 1
}

# Failure after the flip: go back to OLD_VERSION, which is still recorded
# as installed. Returns 1.
revert_update() {
    local reason="$1"
    log err event=rollback reason="$reason" from="$VERSION" to="$OLD_VERSION"
    revert_to "$OLD_VERSION"
    outcome_update_reverted "$reason"
    return 1
}

# TERM/INT (systemctl stop, TimeoutStartSec) during an update or rollback.
# TXN_PHASE: pre (nothing changed yet), switched (files may be between
# OLD_VERSION and VERSION), done (the outcome is recorded). Writing
# last-result is the commit point of every outcome, so commit_result moves
# to done and a later signal (say during the mail) leaves the record alone.
TXN_PHASE=pre
commit_result() { state_set last-result "$1"; TXN_PHASE="done"; }
on_signal() {
    local sig="$1" rc=143; [[ "$sig" == INT ]] && rc=130
    log err event=interrupted signal="$sig" from="${OLD_VERSION:-?}" to="${VERSION:-?}" phase="$TXN_PHASE"
    (( ! DRY_RUN )) || exit "$rc"
    case "$TXN_PHASE" in
        switched)
            state_set incomplete "$OLD_VERSION"
            state_set last-result "interrupted while switching between $OLD_VERSION and $VERSION; updates blocked until: relrotate rollback $APP"
            notify "INTERRUPTED while switching to $VERSION" \
                "relrotate was stopped while switching $APP between $OLD_VERSION and $VERSION, after files started to change. Updates are blocked. Run: relrotate rollback $APP (it reverts to $OLD_VERSION), or relrotate adopt $APP <version> if you fixed it by hand." ;;
        pre) state_set last-result "interrupted before install of ${VERSION:-?}, nothing changed"
            notify_once interrupted "INTERRUPTED before install of ${VERSION:-?}" \
                "relrotate was stopped while updating $APP to ${VERSION:-?}, before anything changed; ${OLD_VERSION:-?} is still running. It will retry on the next timer run and does not alert again for the same interruption." ;;
    esac
    exit "$rc"
}
set_signal_traps() { trap 'on_signal TERM' TERM; trap 'on_signal INT' INT; }

transaction_apply() {
    log info event=update-start from="$OLD_VERSION" to="$VERSION"
    # Under the app lock (cmd_update): work dirs of a killed run are nobody's.
    # A dry run changes nothing, so it leaves them for the next real run.
    if (( ! DRY_RUN )); then
        find "$STATE_DIR" -maxdepth 1 -name 'work.*' -exec rm -rf -- {} + || true
        layout sweep
    fi
    WORK="$(mktemp -d "$STATE_DIR/work.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT
    TXN_PHASE=pre; set_signal_traps

    if layout needs_download; then
        download_and_verify || fail_update "download/verification failed"
    fi
    if (( DRY_RUN )); then
        log info event=dry-run version="$VERSION" note="verified, not installed"
        return 0
    fi

    local stage_rc=0
    layout stage || stage_rc=$?
    case "$stage_rc" in
        0) ;;
        3) outcome_already_live; exit 1 ;;
        *) fail_update "staging failed" ;;
    esac
    run_hook post_extract
    (( HOOK_RC == 0 )) || fail_update "post_extract hook failed"
    run_hook pre_update
    (( HOOK_RC == 0 )) || fail_update "pre_update hook failed"

    local flip_rc=0
    TXN_PHASE=switched   # before the flip: a signal during it may leave files half-way
    layout flip || flip_rc=$?
    case "$flip_rc" in
        0) ;;
        1) TXN_PHASE=pre; fail_update "flip failed" ;;
        *) revert_update "flip failed half-way"; return 1 ;;
    esac
    # --- past the flip: every failure reverts ---
    run_hook post_flip
    (( HOOK_RC == 0 )) || { revert_update "post_flip hook failed"; return 1; }
    restart_service || { revert_update "restart failed"; return 1; }
    run_healthcheck
    (( HEALTHY )) || { revert_update "health check failed"; return 1; }

    state_set_alert previous "$OLD_VERSION" "$VERSION" || return 1
    state_set_alert installed "$VERSION" "$VERSION" || return 1
    state_clear unhealthy failed-notified
    commit_result "updated $OLD_VERSION -> $VERSION"
    layout prune
    log info event=updated from="$OLD_VERSION" to="$VERSION"
    notify "updated $OLD_VERSION -> $VERSION" \
        "relrotate updated $APP on $(host_name) from $OLD_VERSION to $VERSION (policy=$POLICY, layout=$LAYOUT)." info
}

# Manual rollback from VERSION (installed) to OLD_VERSION (previous).
# Once the files are on OLD_VERSION the state says so, even when the
# restart or health check then fails. Mails only on failure.
transaction_rollback() {
    log info event=manual-rollback from="$VERSION" to="$OLD_VERSION"
    TXN_PHASE=switched; set_signal_traps   # revert_to starts changing files at once
    revert_to "$OLD_VERSION"
    outcome_rollback
}
