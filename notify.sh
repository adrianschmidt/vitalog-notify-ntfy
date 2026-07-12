#!/usr/bin/env bash
#
# vitalog-notify-ntfy: bash notifier that reads `vitalog status`
# and POSTs new-edge reminders to an ntfy.sh topic.
#
# Run via launchd every 15 min (see com.vitalog-notify.plist.example).
#
# Surface:
#   ./notify.sh              normal run
#   ./notify.sh --dry-run    print "would ping: <id>" lines, do not curl
#                            or write state

set -euo pipefail

CONFIG_FILE="${HOME}/.config/vitalog-notify/config"
STATE_FILE="${HOME}/.config/vitalog-notify/state.json"

die() {
    echo "vitalog-notify: $*" >&2
    exit 1
}

warn() {
    echo "vitalog-notify: $*" >&2
}

# diff_state: see implementation below.
diff_state() {
    local current="$1"
    local prev="$2"
    jq -n -c \
        --argjson current "$current" \
        --argjson prev "$prev" \
        '
        ($current.effective_date) as $today |
        (
            if ($prev.effective_date // null) == $today
            then ($prev.seen_due // {})
            else {}
            end
        ) as $seen_due |
        {
            pings: [
                $current.reminders[]
                | select(.due == true)
                | select(($seen_due[.id] // false) == false)
                | {id: .id, display: .display, streak: .streak, days_past_due: .days_past_due}
            ],
            new_state: {
                effective_date: $today,
                seen_due: (
                    [$current.reminders[] | {key: .id, value: .due}]
                    | from_entries
                )
            }
        }
        '
}

# read_state: prints either the parsed state JSON or "{}" if missing
# / corrupt. Warns on corruption.
read_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "{}"
        return
    fi
    local raw
    raw=$(cat "$STATE_FILE")
    if echo "$raw" | jq -e . >/dev/null 2>&1; then
        echo "$raw"
    else
        warn "state file $STATE_FILE is corrupt; starting fresh"
        echo "{}"
    fi
}

# write_state: atomic replacement of the state file.
write_state() {
    local content="$1"
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# compose_body: render the ntfy message body from a reminder's streak
# and days_past_due (raw JSON values as strings: a number, or "null").
# Streak takes precedence; either being a positive integer wins; anything
# else (incl. "null", 0, non-numeric) yields an empty body. Total — no errors.
compose_body() {
    local streak="$1"
    local dpd="$2"
    if [[ "$streak" =~ ^[0-9]+$ ]] && [ "$streak" -ge 1 ]; then
        printf "🔥 %s day streak! Don't break it now." "$streak"
    elif [[ "$dpd" =~ ^[0-9]+$ ]] && [ "$dpd" -ge 1 ]; then
        local unit="days"
        [ "$dpd" -eq 1 ] && unit="day"
        printf "⏰ %s %s overdue — jump back in!" "$dpd" "$unit"
    fi
}

# ping_rows: emit one TSV row per ping — id<TAB>display<TAB>body — with the
# body already composed via compose_body. Both the dry-run and real-run loops
# consume this, so the pings→fields→body extraction lives in exactly one place:
# adding a future body-driver field means touching diff_state's ping projection
# (where the field is carried onto each ping), the jq projection here, and this
# helper — but not every loop. A single jq pass replaces the old per-field forks.
ping_rows() {
    local pings="$1"
    local id display streak dpd body
    # Coalesce JSON null to the literal string "null" so every field is
    # non-empty. @tsv renders JSON null as an empty field, and because TAB is
    # IFS-whitespace, `read` collapses consecutive empty fields and drops them
    # — so a {streak:null, days_past_due:N} row would shift N into $streak and
    # leave $dpd empty, mis-rendering an overdue reminder as a streak. The
    # "null" sentinel keeps fields aligned, and compose_body's ^[0-9]+$ guard
    # already rejects the literal "null".
    while IFS=$'\t' read -r id display streak dpd; do
        body=$(compose_body "$streak" "$dpd")
        printf '%s\t%s\t%s\n' "$id" "$display" "$body"
    done < <(echo "$pings" | jq -rc '.[] | [.id, .display, (.streak // "null"), (.days_past_due // "null")] | @tsv')
}

# format_ping_line: print a log line for one ping. Appends " | <body>"
# only when body is non-empty, so the title-only (empty-body) line stays
# byte-identical to the pre-body-feature format. The " | " separator is
# deliberately not an em-dash: the overdue body itself contains an em-dash
# ("⏰ N days overdue — jump back in!"), so a shared em-dash separator would
# make the line ambiguous to split.
format_ping_line() {
    local base="$1"
    local body="$2"
    if [ -n "$body" ]; then
        printf '%s | %s\n' "$base" "$body"
    else
        printf '%s\n' "$base"
    fi
}

# send_ping: POST to ntfy with the reminder's display as the title and
# `body` as the message. Returns 0 on success, non-zero on failure. An
# empty body produces the same request as before this feature.
send_ping() {
    local display="$1"
    local body="$2"
    curl -fsS \
        -H "Title: $display" \
        -d "$body" \
        "$NTFY_TOPIC_URL" \
        >/dev/null
}

main() {
    local dry_run=0
    if [ "${1:-}" = "--dry-run" ]; then
        dry_run=1
    fi

    # Dependency check.
    command -v jq >/dev/null 2>&1 \
        || die "jq is required; install with: brew install jq"
    command -v curl >/dev/null 2>&1 \
        || die "curl is required (should be on every macOS)"

    # Config check.
    [ -r "$CONFIG_FILE" ] \
        || die "config not found at $CONFIG_FILE; run install.sh first"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [ -n "${NTFY_TOPIC_URL:-}" ] \
        || die "NTFY_TOPIC_URL is unset in $CONFIG_FILE"
    [ -n "${VITALOG_BIN:-}" ] \
        || die "VITALOG_BIN is unset in $CONFIG_FILE"
    [ -x "$VITALOG_BIN" ] \
        || die "VITALOG_BIN ($VITALOG_BIN) is not executable"

    # Pull the current status. A non-zero exit or invalid JSON aborts
    # the run with no state write; launchd will retry in 15 min.
    local current
    if ! current=$("$VITALOG_BIN" status 2>/dev/null); then
        die "vitalog status failed (exit non-zero)"
    fi
    if ! echo "$current" | jq -e . >/dev/null 2>&1; then
        die "vitalog status produced invalid JSON"
    fi

    # Compute the diff.
    local prev result pings new_state
    prev=$(read_state)
    result=$(diff_state "$current" "$prev")
    pings=$(echo "$result" | jq -c '.pings')
    new_state=$(echo "$result" | jq -c '.new_state')

    # Dry run: print what we'd do; do not curl, do not write state.
    if [ "$dry_run" -eq 1 ]; then
        local count
        count=$(echo "$pings" | jq 'length')
        echo "would ping ($count):"
        local id display body
        while IFS=$'\t' read -r id display body; do
            format_ping_line "  - $id: $display" "$body"
        done < <(ping_rows "$pings")
        return 0
    fi

    # Real run: POST each ping. If a POST fails, flip that reminder's
    # new_state.seen_due back to whatever the previous state had (or
    # to false if it wasn't there). That way the next run will see
    # the same false→true edge and retry.
    local id display body
    while IFS=$'\t' read -r id display body; do
        if send_ping "$display" "$body"; then
            format_ping_line "pinged: $id ($display)" "$body"
        else
            warn "ping failed for $id ($display); will retry next run"
            # Revert new_state.seen_due[id] to its prior value so
            # the next run sees the same false→true edge.
            local prior
            prior=$(echo "$prev" | jq -c --arg id "$id" '.seen_due[$id] // false')
            new_state=$(
                echo "$new_state" \
                    | jq -c --arg id "$id" --argjson prior "$prior" \
                        '.seen_due[$id] = $prior'
            )
        fi
    done < <(ping_rows "$pings")

    # Ensure the state directory exists, then write.
    mkdir -p "$(dirname "$STATE_FILE")"
    write_state "$new_state"
}

# Only run main flow when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
