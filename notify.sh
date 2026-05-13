#!/usr/bin/env bash
#
# vitalog-notify-ntfy: bash notifier that reads `vitalog status --json`
# and POSTs new-edge reminders to an ntfy.sh topic.

set -euo pipefail

# diff_state: pure function over the current vitalog status JSON
# and the previous state JSON. Returns (on stdout) a JSON object:
#   {
#     "pings":     [{"id":"…","display":"…"}, …],
#     "new_state": {"effective_date":"…","seen_due":{…}}
#   }
#
# Behaviour:
#   - If prev.effective_date != current.effective_date, prior
#     seen_due is wiped (daily reset).
#   - Each reminder whose current .due is true but whose prior
#     seen_due[id] was false (or absent) is added to .pings.
#   - new_state.seen_due is rebuilt from the current reminders
#     (any removed-from-config reminders drop out).
#
# The function does no I/O; it shells out to jq for the actual
# transformation.
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

main() {
    # Implemented in Task 3.
    echo "notify.sh stub: not yet implemented" >&2
    exit 1
}

# Only run main flow when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
