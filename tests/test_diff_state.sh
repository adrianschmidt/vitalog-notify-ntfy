#!/usr/bin/env bash
#
# Tests for the pure diff_state function in ../notify.sh.
# Each test feeds JSON fixtures into diff_state and checks the
# resulting (pings, new_state) tuple against expected output.

set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
source ../notify.sh

fail() {
    echo "FAIL: $1" >&2
    return 1
}

# Compares two JSON strings for semantic equality (key order and
# whitespace insensitive) using jq.
assert_json_eq() {
    local got="$1"
    local want="$2"
    local name="$3"
    local got_canonical want_canonical
    got_canonical=$(echo "$got" | jq -S -c .)
    want_canonical=$(echo "$want" | jq -S -c .)
    if [ "$got_canonical" != "$want_canonical" ]; then
        fail "$name: got $got_canonical, want $want_canonical"
        return 1
    fi
    echo "PASS: $name"
}

read_fixture() {
    cat "fixtures/$1"
}

test_empty_reminders_empty_state() {
    local current prev got want
    current=$(read_fixture status_no_reminders.json)
    prev=$(read_fixture state_empty.json)
    got=$(diff_state "$current" "$prev")
    want='{"pings":[],"new_state":{"effective_date":"2026-05-13","seen_due":{}}}'
    assert_json_eq "$got" "$want" "empty reminders + empty state"
}

test_one_due_no_prior_state() {
    local current prev got want
    current=$(read_fixture status_one_due.json)
    prev=$(read_fixture state_empty.json)
    got=$(diff_state "$current" "$prev")
    want='{"pings":[{"id":"lactic_acid","display":"Lactic acid training","streak":0,"days_past_due":1}],"new_state":{"effective_date":"2026-05-13","seen_due":{"lactic_acid":true}}}'
    assert_json_eq "$got" "$want" "one due + no prior state"
}

test_still_due_already_seen_same_day() {
    local current prev got want
    current=$(read_fixture status_one_due.json)
    prev=$(read_fixture state_one_seen_due.json)
    got=$(diff_state "$current" "$prev")
    want='{"pings":[],"new_state":{"effective_date":"2026-05-13","seen_due":{"lactic_acid":true}}}'
    assert_json_eq "$got" "$want" "still due + already seen same day → no ping"
}

test_flipped_false_after_log_same_day() {
    # User logged the activity; reminder now due=false. State carried
    # "true" from earlier in the day; new state should record "false".
    local current prev got want
    current='{"effective_date":"2026-05-13","reminders":[{"id":"lactic_acid","display":"Lactic acid training","interval_days":2,"last_done":"2026-05-13","days_since":0,"due":false,"not_before":null,"not_after":null,"streak":3,"days_past_due":0}]}'
    prev=$(read_fixture state_one_seen_due.json)
    got=$(diff_state "$current" "$prev")
    want='{"pings":[],"new_state":{"effective_date":"2026-05-13","seen_due":{"lactic_acid":false}}}'
    assert_json_eq "$got" "$want" "due flips false same day → state updates, no ping"
}

test_daily_reset_repings_overdue() {
    # Yesterday's state has lactic_acid:true. Today's reminders still
    # have it due=true (perpetually overdue). Because effective_date
    # changed, diff_state should treat prior state as empty and ping.
    local current prev got want
    current=$(read_fixture status_overdue_next_day.json)
    prev=$(read_fixture state_yesterday.json)
    got=$(diff_state "$current" "$prev")
    want='{"pings":[{"id":"lactic_acid","display":"Lactic acid training","streak":0,"days_past_due":2}],"new_state":{"effective_date":"2026-05-14","seen_due":{"lactic_acid":true}}}'
    assert_json_eq "$got" "$want" "daily reset re-pings overdue"
}

test_mixed_new_edge_seen_and_just_logged() {
    # A: lactic_acid due=true, prev=false → ping
    # B: brush_evening due=false (just logged), prev not present → no ping, state false
    # C: weigh_in due=true, prev=true → no ping, state stays true
    local current prev got want
    current=$(read_fixture status_overdue_same_day.json)
    prev='{"effective_date":"2026-05-13","seen_due":{"weigh_in":true}}'
    got=$(diff_state "$current" "$prev")
    want='{"pings":[{"id":"lactic_acid","display":"Lactic acid training","streak":0,"days_past_due":1}],"new_state":{"effective_date":"2026-05-13","seen_due":{"lactic_acid":true,"brush_evening":false,"weigh_in":true}}}'
    assert_json_eq "$got" "$want" "mixed: new edge + already-seen + just-logged"
}

test_reminder_removed_drops_from_state() {
    # Prior state has "old_reminder" but current reminders don't.
    # The new state should not contain "old_reminder".
    local current prev got
    current=$(read_fixture status_no_reminders.json)
    prev='{"effective_date":"2026-05-13","seen_due":{"old_reminder":true}}'
    got=$(diff_state "$current" "$prev")
    local want='{"pings":[],"new_state":{"effective_date":"2026-05-13","seen_due":{}}}'
    assert_json_eq "$got" "$want" "removed reminder drops from state"
}

test_corrupt_prior_state_treated_as_empty() {
    # The shell wrapper around diff_state (in Task 3) handles the
    # JSON-parse error and passes "{}" in. Here we exercise that
    # contract directly: diff_state with prev='{}' should behave
    # identically to prev being a well-formed empty state object.
    local current prev got want
    current=$(read_fixture status_one_due.json)
    prev='{}'
    got=$(diff_state "$current" "$prev")
    want='{"pings":[{"id":"lactic_acid","display":"Lactic acid training","streak":0,"days_past_due":1}],"new_state":{"effective_date":"2026-05-13","seen_due":{"lactic_acid":true}}}'
    assert_json_eq "$got" "$want" "prev='{}' → daily reset path → 1 ping"
}

# Run all tests. Bash 3 (default on macOS) doesn't have associative
# arrays in the right form, so we just list them.
tests=(
    test_empty_reminders_empty_state
    test_one_due_no_prior_state
    test_still_due_already_seen_same_day
    test_flipped_false_after_log_same_day
    test_daily_reset_repings_overdue
    test_mixed_new_edge_seen_and_just_logged
    test_reminder_removed_drops_from_state
    test_corrupt_prior_state_treated_as_empty
)

failed=0
for t in "${tests[@]}"; do
    if ! $t; then
        failed=$((failed + 1))
    fi
done

if [ "$failed" -gt 0 ]; then
    echo "FAILED: $failed test(s) in test_diff_state.sh" >&2
    exit 1
fi
