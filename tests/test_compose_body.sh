#!/usr/bin/env bash
#
# Tests for the pure compose_body function in ../notify.sh.
# Calls compose_body directly (no fixtures) and checks the rendered body.

set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
source ../notify.sh

assert_eq() {
    local got="$1" want="$2" name="$3"
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: got [$got], want [$want]" >&2
        return 1
    fi
    echo "PASS: $name"
}

failed=0

run() {
    local name="$1" want="$2" streak="$3" dpd="$4" got
    got=$(compose_body "$streak" "$dpd")
    assert_eq "$got" "$want" "$name" || failed=$((failed + 1))
}

run "streak plural"      "🔥 6 day streak! Don't break it now."   6    0
run "streak singular"    "🔥 1 day streak! Don't break it now."   1    0
run "overdue plural"     "⏰ 3 days overdue — jump back in!"       0    3
run "overdue singular"   "⏰ 1 day overdue — jump back in!"        0    1
run "both null → empty"  ""                                       null null
run "streak0 dpd null"   ""                                       0    null
run "streak null dpd0"   ""                                       null 0
run "both zero → empty"  ""                                       0    0
run "streak wins"        "🔥 6 day streak! Don't break it now."   6    3

if [ "$failed" -gt 0 ]; then
    echo "FAILED: $failed case(s)" >&2
    exit 1
fi
echo "All compose_body cases passed."
