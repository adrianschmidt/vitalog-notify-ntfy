#!/usr/bin/env bash
#
# Integration test for the real-run POST loop in ../notify.sh — the one flow
# not exercised by the dry-run/unit tests. Covers both branches:
#   (a) success: logs "pinged: <id> (<display>) | <body>" to stdout and records
#       seen_due[id]=true in the written state;
#   (b) failure: logs the "ping failed" warn to stderr and reverts
#       seen_due[id] to its prior value (false, since no prior state) so the
#       next run sees the same false→true edge and retries.
#
# `curl` is stubbed via a bin dir prepended to PATH (exit 0 / exit 1), so no
# network is touched. A temp HOME keeps the real config/state untouched.

set -euo pipefail
cd "$(dirname "$0")"

tmp_ok=$(mktemp -d)
tmp_fail=$(mktemp -d)
trap 'rm -rf "$tmp_ok" "$tmp_fail"' EXIT

# Canned status: two due reminders — one live streak, one overdue.
make_vitalog() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "effective_date": "2026-07-12",
  "reminders": [
    {"id":"lactic_acid","display":"Lactic acid training","due":true,"streak":6,"days_past_due":0},
    {"id":"deadlifts","display":"Heavy deadlifts","due":true,"streak":0,"days_past_due":3}
  ]
}
JSON
EOF
    chmod +x "$1"
}

# Set up a temp HOME with a stub vitalog, a config, and a stub curl that
# exits with $2. Prints nothing; leaves everything ready for a real run.
setup_home() {
    local home="$1" curl_rc="$2" stub bin
    stub="$home/vitalog"
    make_vitalog "$stub"
    mkdir -p "$home/.config/vitalog-notify"
    cat > "$home/.config/vitalog-notify/config" <<EOF
NTFY_TOPIC_URL="https://ntfy.example/unused-curl-is-stubbed"
VITALOG_BIN="$stub"
EOF
    bin="$home/bin"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nexit %s\n' "$curl_rc" > "$bin/curl"
    chmod +x "$bin/curl"
}

failed=0

check_contains() {
    # haystack-file needle name
    if grep -qF "$2" "$1"; then
        echo "PASS: $3"
    else
        echo "FAIL: $3 (missing: $2)" >&2
        echo "--- $1 was: ---" >&2
        cat "$1" >&2
        failed=1
    fi
}

check_absent() {
    # haystack-file needle name
    if grep -qF "$2" "$1"; then
        echo "FAIL: $3 (unexpected: $2)" >&2
        cat "$1" >&2
        failed=1
    else
        echo "PASS: $3"
    fi
}

check_state() {
    # state-file jq-filter name
    if jq -e "$2" "$1" >/dev/null 2>&1; then
        echo "PASS: $3"
    else
        echo "FAIL: $3 (state: $(cat "$1" 2>/dev/null))" >&2
        failed=1
    fi
}

# --- Success path: curl exits 0 -------------------------------------------
setup_home "$tmp_ok" 0
PATH="$tmp_ok/bin:$PATH" HOME="$tmp_ok" bash ../notify.sh \
    >"$tmp_ok/out" 2>"$tmp_ok/err"

check_contains "$tmp_ok/out" \
    "pinged: lactic_acid (Lactic acid training) | 🔥 6 day streak! Don't break it now." \
    "success logs pinged line with streak body"
check_contains "$tmp_ok/out" \
    "pinged: deadlifts (Heavy deadlifts) | ⏰ 3 days overdue — jump back in!" \
    "success logs pinged line with overdue body"
check_state "$tmp_ok/.config/vitalog-notify/state.json" \
    '.seen_due.lactic_acid == true and .seen_due.deadlifts == true' \
    "success records seen_due=true for both reminders"

# --- Failure path: curl exits 1 -------------------------------------------
setup_home "$tmp_fail" 1
PATH="$tmp_fail/bin:$PATH" HOME="$tmp_fail" bash ../notify.sh \
    >"$tmp_fail/out" 2>"$tmp_fail/err"

check_contains "$tmp_fail/err" \
    "ping failed for lactic_acid (Lactic acid training); will retry next run" \
    "failure logs warn to stderr"
check_absent "$tmp_fail/out" "pinged:" \
    "failure logs no pinged line"
# Both reverted to their prior value — false, since this HOME had no state —
# so the next run re-sees the false→true edge and retries.
check_state "$tmp_fail/.config/vitalog-notify/state.json" \
    '.seen_due.lactic_acid == false and .seen_due.deadlifts == false' \
    "failure reverts seen_due to prior (false) for retry"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "All real-run cases passed."
