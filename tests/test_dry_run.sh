#!/usr/bin/env bash
#
# Integration smoke test for the main --dry-run flow. Uses a temp HOME so
# the real config/state is untouched, and a stub vitalog that emits a
# canned status JSON with one live-streak and one past-due reminder.

set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/vitalog"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "effective_date": "2026-07-12",
  "reminders": [
    {"id":"lactic_acid","display":"Lactic acid training","interval_days":2,"last_done":"2026-07-10","days_since":2,"due":true,"not_before":null,"not_after":null,"streak":6,"days_past_due":0},
    {"id":"deadlifts","display":"Heavy deadlifts","interval_days":7,"last_done":"2026-07-02","days_since":10,"due":true,"not_before":null,"not_after":null,"streak":0,"days_past_due":3},
    {"id":"mobility","display":"Mobility work","interval_days":3,"last_done":"2026-07-07","days_since":5,"due":true,"not_before":null,"not_after":null,"streak":null,"days_past_due":2},
    {"id":"weigh_in","display":"Daily weigh-in","interval_days":1,"last_done":null,"days_since":null,"due":true,"not_before":null,"not_after":null,"streak":null,"days_past_due":null}
  ]
}
JSON
EOF
chmod +x "$stub"

mkdir -p "$tmp/.config/vitalog-notify"
cat > "$tmp/.config/vitalog-notify/config" <<EOF
NTFY_TOPIC_URL="https://ntfy.example/unused-in-dry-run"
VITALOG_BIN="$stub"
EOF

out=$(HOME="$tmp" bash ../notify.sh --dry-run)

failed=0
check() {
    if echo "$out" | grep -qF "$1"; then
        echo "PASS: $2"
    else
        echo "FAIL: $2 (missing: $1)" >&2
        failed=1
    fi
}

check "lactic_acid: Lactic acid training | 🔥 6 day streak! Don't break it now." "streak body rendered"
check "deadlifts: Heavy deadlifts | ⏰ 3 days overdue — jump back in!" "overdue body rendered"
# Regression guard: streak:null + days_past_due>=1 must render the overdue
# body, not a streak. jq @tsv renders null as an empty field, which `read`
# collapses (TAB is IFS-whitespace), shifting days_past_due into the streak
# slot and mis-rendering "🔥 N day streak!". Exercises the real ping_rows→read
# path where the bug lived.
check "mobility: Mobility work | ⏰ 2 days overdue — jump back in!" "overdue body rendered for streak:null"

if echo "$out" | grep -F "mobility" | grep -qF "streak"; then
    echo "FAIL: streak:null reminder mis-rendered as a streak body" >&2
    failed=1
else
    echo "PASS: streak:null reminder not mis-rendered as a streak"
fi

check "  - weigh_in: Daily weigh-in" "title-only line rendered for empty body"

if echo "$out" | grep -F "weigh_in" | grep -qF " | "; then
    echo "FAIL: title-only line has a body suffix (found ' | ')" >&2
    failed=1
else
    echo "PASS: title-only line has no body suffix"
fi

if [ "$failed" -ne 0 ]; then
    echo "--- dry-run output was: ---" >&2
    echo "$out" >&2
    exit 1
fi
echo "All dry-run cases passed."
