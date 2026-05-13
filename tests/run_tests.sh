#!/usr/bin/env bash
#
# Run every test_*.sh in this directory. Each test file is expected to
# print PASS/FAIL lines and exit 0 only if all its cases passed.

set -euo pipefail
cd "$(dirname "$0")"

failed=0
for f in test_*.sh; do
    echo "=== $f ==="
    if ! bash "$f"; then
        failed=$((failed + 1))
    fi
done

if [ "$failed" -gt 0 ]; then
    echo "FAILED: $failed test file(s)" >&2
    exit 1
fi
echo "All test files passed."
