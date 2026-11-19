# shellcheck shell=bash
# relrotate: who is told, when, and how.
#
#   notify SUBJECT BODY [info|alert]   one event for this app; never fails
#   notify_digest_wanted               true when NOTIFY_POLICY keeps a summary
#   digest_flush                       send the queued events, one message per destination
#   deliver TITLE BODY FOOTER          mail and every NOTIFY destination
#   deliver_to DEST TITLE BODY FOOTER  one of them
#   send_chat KIND FILE TITLE BODY     one chat destination
#   notify_<kind> FILE TITLE BODY      adapter: sets NOTIFY_URL, NOTIFY_DATA,
#                                      NOTIFY_CTYPE, NOTIFY_HDR (discord, telegram,
#                                      ntfy, webhook); a new kind is one more adapter
#   notify_curl PROTO ...              the one curl call; URL and payload go in on stdin
#   outbox_file, outbox_add            the queue for the summary
#
# NOTIFY_POLICY is decided only here (notify_queues, notify_digest_wanted).
# Needs log, host_name (common.sh) and USER_AGENT (source.sh); the caller sets
# APP, STATE_ROOT. Nothing here may change the result of an update.

# Policy, one place: does this event wait for the summary?
#   each      every event now (default)
#   failures  alerts now, info events (updates, recoveries) in the summary
#   digest    everything in the summary
notify_queues() { [[ "$NOTIFY_POLICY" == digest || ( "$NOTIFY_POLICY" == failures && "$1" == info ) ]]; }
# Is there ever a summary to send (so update-all should run one)?
notify_digest_wanted() { [[ "$NOTIFY_POLICY" != each ]]; }

# notify SUBJECT BODY [info|alert]: one event for this app, now or queued.
notify() {
    local subject="$1" body="$2" level="${3:-alert}"
    log info event=notify subject="$subject" level="$level"
    if notify_queues "$level"; then
        outbox_add "$level" "$subject" "$body"
        return 0
    fi
    deliver "$(host_name) $APP: $subject" "$body" "relrotate status $APP" || true
}

# notify_dests: one line per destination, mail first, then the NOTIFY entries.
notify_dests() {
    local d
    (( ${#NOTIFY[@]} )) || [[ -n "$MAIL_TO" ]] || log debug msg="no notification destination configured, skipping"
    [[ -z "$MAIL_TO" ]] || echo mail
    for d in "${NOTIFY[@]+"${NOTIFY[@]}"}"; do echo "$d"; done
}

# deliver_to DEST TITLE BODY FOOTER: one destination, "mail" or "kind:/file".
deliver_to() {
    if [[ "$1" == mail ]]; then send_mail "$2" "$3" "$4"; else send_chat "${1%%:*}" "${1#*:}" "$2" "$3"; fi
}

# deliver TITLE BODY FOOTER: send to mail and every NOTIFY destination.
# Returns 1 if any of them failed (each failure is logged).
deliver() {
    local rc=0 d
    while IFS= read -r d; do deliver_to "$d" "$1" "$2" "$3" || rc=1; done < <(notify_dests)
    return "$rc"
}

send_mail() {
    local title="$1" body="$2" footer="$3"
    [[ -n "$SENDMAIL" && -x "$SENDMAIL" ]] || { log warning msg="MAIL_TO is set but no sendmail found, mail not sent"; return 1; }
    {
        [[ -n "$MAIL_FROM" ]] && printf 'From: %s\n' "$MAIL_FROM"
        printf 'To: %s\n' "$MAIL_TO"
        printf 'Subject: [relrotate] %s\n' "${title//[$'\r\n']/ }"
        printf 'Content-Type: text/plain; charset=utf-8\n\n'
        printf '%s\n\n' "$body"
        printf -- '-- \n%s\n' "$footer"
    } | timeout 20 "$SENDMAIL" -t -oi 7>&- 9>&- || { log warning msg="sending mail failed"; return 1; }
}

# notify_cap VAR MAX KEEP: cut VAR to KEEP characters plus a marker when it
# is longer than MAX. Discord takes 2000 characters, Telegram and ntfy 4096;
# a webhook gets more, but one curl argument must stay well below 128 KiB.
notify_cap() {
    local -n _v="$1"
    (( ${#_v} <= $2 )) || _v="${_v:0:$3}"$'\n'"[cut; see relrotate status]"
}

# The message of the chat kinds with one text field. Sets NOTIFY_TEXT (not
# printed: $(...) would eat trailing newlines).
notify_text() {
    NOTIFY_TEXT="[relrotate] $1"$'\n'"$2"
    notify_cap NOTIFY_TEXT 1900 1870
}

# Adapters. FILE (root-only, like the token files) holds the secret part:
# the URL for discord, ntfy and webhook; the bot token and the chat id on two
# lines for telegram. TITLE has no newlines. Return 1 (logged) when FILE is
# unusable.
notify_discord() {
    notify_text "$2" "$3"
    NOTIFY_URL="$(head -n1 "$1")"
    NOTIFY_DATA="$(jq -nc --arg t "$NOTIFY_TEXT" '{content: $t, allowed_mentions: {parse: []}}')"
}
notify_telegram() {
    local tok chat
    notify_text "$2" "$3"
    { read -r tok; read -r chat; } < "$1" || true
    [[ -n "${tok:-}" && -n "${chat:-}" ]] || { log warning msg="telegram file needs the bot token and the chat id on two lines" file="$1"; return 1; }
    NOTIFY_URL="https://api.telegram.org/bot$tok/sendMessage"
    NOTIFY_DATA="$(jq -nc --arg c "$chat" --arg t "$NOTIFY_TEXT" '{chat_id: $c, text: $t, disable_web_page_preview: true}')"
}
notify_ntfy() {
    local body="$3"
    notify_cap body 3500 3470
    NOTIFY_URL="$(head -n1 "$1")"; NOTIFY_CTYPE="text/plain; charset=utf-8"
    NOTIFY_HDR=(-H "Title: [relrotate] $2"); NOTIFY_DATA="$body"
}
notify_webhook() {
    local body="$3"
    notify_cap body 60000 59970
    NOTIFY_URL="$(head -n1 "$1")"
    NOTIFY_DATA="$(jq -nc --arg h "$(host_name)" --arg a "$APP" --arg t "$2" --arg b "$body" \
        '{source: "relrotate", host: $h, app: $a, title: $t, body: $b}')"
}

# cfg_quote VAR: quote VAR for a curl config file ("..." value): backslash, double
# quote and the whitespace curl unescapes (\n \t \r), so curl reads back the same bytes.
cfg_quote() {
    local -n _q="$1"
    _q="${_q//\\/\\\\}"; _q="${_q//\"/\\\"}"
    _q="${_q//$'\n'/\\n}"; _q="${_q//$'\t'/\\t}"; _q="${_q//$'\r'/\\r}"
}

# notify_curl PROTO CTYPE DATA [-H HEADER]...: POST DATA to NOTIFY_URL. The URL,
# the payload and the extra headers reach curl on stdin (--config -), never on
# its command line (ps shows it), and are never logged. 20 s at most: the app
# lock is held. The lock fds are closed for the child.
notify_curl() {
    local proto="$1" ctype="$2" data="$3" url="$NOTIFY_URL" hdrs="" h; shift 3
    cfg_quote url; cfg_quote data
    while (( $# >= 2 )); do h="$2"; cfg_quote h; hdrs+="header = \"$h\""$'\n'; shift 2; done
    printf 'url = "%s"\ndata-raw = "%s"\n%s' "$url" "$data" "$hdrs" | timeout 20 "$CURL" -fsS --retry 2 --retry-delay 3 \
        --connect-timeout 10 --max-time 18 -o /dev/null \
        -A "$USER_AGENT" "${CURL_OPTS[@]+"${CURL_OPTS[@]}"}" --proto "$proto" --proto-redir "$proto" \
        -H "Content-Type: $ctype" --config - 7>&- 9>&-
}

# send_chat KIND FILE TITLE BODY: build the payload with the kind's adapter,
# check the URL scheme, send.
send_chat() {
    local kind="$1" file="$2" title="${3//[$'\r\n']/ }" body="$4"
    # Locals, seen by the adapter and notify_curl through dynamic scope: the
    # URL and token do not outlive the send (a hook runs in this process later).
    local NOTIFY_URL="" NOTIFY_DATA="" NOTIFY_TEXT="" NOTIFY_CTYPE=application/json
    local -a NOTIFY_HDR=()
    [[ -r "$file" ]] || { log warning msg="notify destination file is not readable" kind="$kind" file="$file"; return 1; }
    case "$kind" in
        discord|telegram|ntfy|webhook) "notify_$kind" "$file" "$title" "$body" || return 1 ;;
        *) log warning msg="unknown NOTIFY kind (discord|telegram|ntfy|webhook)" kind="$kind"; return 1 ;;
    esac
    NOTIFY_URL="${NOTIFY_URL//[[:space:]]/}"
    local proto="=https"
    case "$kind:$NOTIFY_URL" in
        *:https://*) ;;
        webhook:http://*) proto="=http,https" ;;   # a bot on the local network
        webhook:*) log warning msg="notify URL must be http(s)" kind="$kind" file="$file"; return 1 ;;
        *) log warning msg="notify URL must be https" kind="$kind" file="$file"; return 1 ;;
    esac
    notify_curl "$proto" "$NOTIFY_CTYPE" "$NOTIFY_DATA" "${NOTIFY_HDR[@]+"${NOTIFY_HDR[@]}"}" \
        || { log warning msg="sending notification failed" kind="$kind"; return 1; }
}

# Events waiting for the summary: one JSON line each, appended under a lock.
outbox_file() { printf '%s/.outbox' "$STATE_ROOT"; }
outbox_add() {
    local line
    line="$(jq -nc --arg t "$(date -Is)" --arg a "$APP" --arg l "$1" --arg s "$2" --arg b "$3" \
        '{t: $t, app: $a, level: $l, subject: $s, body: $b}')"
    { flock 8 && printf '%s\n' "$line" >&8; } 8>>"$(outbox_file)" \
        || log warning msg="could not queue the notification for the summary"
}

# digest_flush: send everything queued (NOTIFY_POLICY failures|digest) as one
# message per destination. The queue is moved under its lock into the batch
# (.outbox.sending), so runs that queue meanwhile are not lost. BATCH.sent
# holds "COUNT DEST" lines: how many batch lines each destination has. A
# destination that fails keeps its place and gets what it missed next time;
# the others are not held up. The batch stays only while one lacks events, and
# keeps at most DIGEST_KEEP of the newest ones.
DIGEST_KEEP=1000
digest_flush() {
    local q; q="$(outbox_file)"
    local batch="$q.sending" sent="$q.sending.sent"
    # The summary belongs to no app: its log lines and the webhook payload carry app=""
    local APP=""
    mkdir -p "$STATE_ROOT"
    exec 7>"$STATE_ROOT/.digest.lock"
    flock -n 7 || die 1 "another relrotate digest is running"
    local -A got=()
    local -a dests=()
    local n=0 line c d new n_in n_ok rc=0
    [[ ! -e "$batch" ]] || n="$(wc -l < "$batch")"
    (( n )) || rm -f -- "$sent"   # a .sent without its batch is left over from a kill
    if [[ -r "$sent" ]]; then
        while IFS= read -r line; do
            c="${line%% *}"; d="${line#* }"
            # an old BATCH.sent held bare destination names: they had the whole batch
            if [[ "$c" =~ ^[0-9]+$ && "$line" == *" "* ]]; then got["$d"]="$c"; else got["$line"]="$n"; fi
        done < "$sent"
    fi
    # shellcheck disable=SC2094  # fd 8 only holds the lock; writers append
    { flock 8 && if [[ -s "$q" ]]; then
        n_in="$(wc -l < "$q")"
        # A torn or edited line, or JSON that is no event, must not block the queue: keep what parses.
        if new="$(jq -cR 'fromjson? | select(type == "object" and (.subject | type) == "string" and (.app | type) == "string" and (.level | type) == "string") | .t //= "" | .body //= ""' < "$q")"; then
            [[ -z "$new" ]] || printf '%s\n' "$new" >> "$batch"
            : > "$q"
            n_ok=0; [[ -z "$new" ]] || n_ok="$(wc -l <<<"$new")"
            (( n_in == n_ok )) || log warning msg="dropped unreadable summary lines" lines="$(( n_in - n_ok ))"
        fi
    fi; } 8>>"$q"
    n=0; [[ ! -e "$batch" ]] || n="$(wc -l < "$batch")"
    (( n )) || { rm -f -- "$batch" "$sent"; log info event=digest-empty; return 0; }
    mapfile -t dests < <(notify_dests)
    for d in "${dests[@]}"; do
        c="${got[$d]:-0}"
        if (( c > n )); then
            log warning msg="summary progress larger than the batch is stale; sending the batch from the start" dest="$d"
            c=0
        fi
        (( c < n )) || continue
        if digest_send "$batch" "$c" "$d"; then got["$d"]="$n"; digest_sent_save "$sent"; else rc=1; fi
    done
    if (( rc == 0 )); then
        rm -f -- "$batch" "$sent"
        log info event=digest-sent events="$n"
        return 0
    fi
    log warning msg="summary not sent everywhere; retried next time for the rest" events="$n"
    if (( n > DIGEST_KEEP )); then
        local drop=$(( n - DIGEST_KEEP ))
        tail -n "$DIGEST_KEEP" "$batch" > "$batch.tmp" && mv -f "$batch.tmp" "$batch" || return 1
        for d in "${dests[@]}"; do c="${got[$d]:-0}"; got["$d"]=$(( c > drop ? c - drop : 0 )); done
        digest_sent_save "$sent"
        log warning msg="a destination keeps failing; dropped the oldest summary events" dropped="$drop" kept="$DIGEST_KEEP"
    fi
    return 1
}

# digest_sent_save FILE: write the counts of the current destinations (got, dests).
digest_sent_save() {
    local d
    for d in "${dests[@]}"; do [[ -z "${got[$d]:-}" ]] || printf '%s %s\n' "${got[$d]}" "$d"; done > "$1.tmp" \
        && mv -f "$1.tmp" "$1"
}

# digest_send BATCH FROM DEST: one message to DEST for the batch lines after
# the first FROM.
digest_send() {
    local slice n alerts title body
    slice="$(tail -n "+$(( $2 + 1 ))" "$1")"
    n="$(jq -s length <<<"$slice")"
    alerts="$(jq -s 'map(select(.level != "info")) | length' <<<"$slice")"
    title="$(host_name): $n event$( (( n == 1 )) || echo s)$( (( alerts == 0 )) || echo ", $alerts need attention")"
    # Alerts first, with their full text; then the rest, one line each.
    body="$(jq -rs '
        (map(select(.level != "info")) | map("\(.t) \(.app): \(.subject)\n    \(.body)")) +
        (map(select(.level == "info")) | map("\(.t) \(.app): \(.subject)"))
        | join("\n")' <<<"$slice")"
    deliver_to "$3" "$title" "$body" "relrotate status" && log info event=digest-sent events="$n" dest="$3"
}
