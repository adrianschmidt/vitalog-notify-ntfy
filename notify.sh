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
                | {id: .id, display: .display}
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

# send_ping: POST to ntfy with the reminder's display as the title.
# Returns 0 on success, non-zero on failure. ntfy uses the request
# body as the message; a Title header overrides that for the
# notification title. We send the title via header and an empty body.
send_ping() {
    local display="$1"
    curl -fsS \
        -H "Title: $display" \
        -d "" \
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
        echo "$pings" | jq -r '.[] | "  - \(.id): \(.display)"'
        return 0
    fi

    # Real run: POST each ping. If a POST fails, flip that reminder's
    # new_state.seen_due back to whatever the previous state had (or
    # to false if it wasn't there). That way the next run will see
    # the same false→true edge and retry.
    local ping_count
    ping_count=$(echo "$pings" | jq 'length')

    if [ "$ping_count" -gt 0 ]; then
        local i=0
        while [ "$i" -lt "$ping_count" ]; do
            local id display
            id=$(echo "$pings" | jq -r ".[$i].id")
            display=$(echo "$pings" | jq -r ".[$i].display")
            if send_ping "$display"; then
                echo "pinged: $id ($display)"
            else
                warn "ping failed for $id; will retry next run"
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
            i=$((i + 1))
        done
    fi

    # Ensure the state directory exists, then write.
    mkdir -p "$(dirname "$STATE_FILE")"
    write_state "$new_state"
}

# Only run main flow when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
