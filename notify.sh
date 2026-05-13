#!/usr/bin/env bash
#
# vitalog-notify-ntfy: bash notifier that reads `vitalog status --json`
# and POSTs new-edge reminders to an ntfy.sh topic.

set -euo pipefail

diff_state() {
    # Implemented in Task 2.
    echo '{"pings":[],"new_state":{"effective_date":null,"seen_due":{}}}'
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
