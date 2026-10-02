#!/usr/bin/env bash

# Decide whether a unit test run actually proved anything.
#
# The test runner exits with the failure count, so a failing assertion already
# fails the job. What it cannot report is never having run: if the extension does
# not load, every script fails to parse, the scene never starts, and Godot exits
# zero with an empty log. CI called that a pass until this script existed.
#
# Usage: verify_test_log.sh <test-log> <godot-output>
#
#   <test-log>      log.txt written by run_tests.gd
#   <godot-output>  everything Godot printed, including script and loader errors
#                   that never reach the test log

set -uo pipefail

TEST_LOG="${1:?Usage: verify_test_log.sh <test-log> <godot-output>}"
GODOT_OUTPUT="${2:?Usage: verify_test_log.sh <test-log> <godot-output>}"

TESTS_DIR="$(dirname "${BASH_SOURCE[0]}")/../project/testing/tests"

fail() {
    # ::error:: puts the reason on the job summary rather than only in the log.
    printf '::error::%s\n' "$1" >&2
    exit 1
}

# Loader and parser failures are the ones that produce a silent pass, so they are
# checked first and against Godot's own output rather than the test log.
if [ -f "$GODOT_OUTPUT" ]; then
    if grep -q "Can't open dynamic library" "$GODOT_OUTPUT"; then
        printf '%s\n' "$(grep -m1 -A1 "Can't open dynamic library" "$GODOT_OUTPUT")" >&2
        fail "GDExtension library did not load, so no test ran"
    fi
    if grep -q "GDExtension dynamic library not found" "$GODOT_OUTPUT"; then
        fail "GDExtension library missing, so no test ran"
    fi
    if grep -q "SCRIPT ERROR" "$GODOT_OUTPUT"; then
        printf '%s\n' "$(grep -m3 "SCRIPT ERROR" "$GODOT_OUTPUT")" >&2
        fail "script errors during the run, so the suite is not trustworthy"
    fi
fi

[ -s "$TEST_LOG" ] || fail "no test log at $TEST_LOG, so the suite never started"

# How many tests exist on disk, so a test file that silently stops loading is
# caught rather than quietly reducing coverage.
expected="$(find "$TESTS_DIR" -maxdepth 1 -name '*.gd' -type f 2>/dev/null | wc -l | tr -d ' ')"
loaded="$(sed -n 's/^Loaded \([0-9]\{1,\}\) tests$/\1/p' "$TEST_LOG" | head -1)"

[ -n "$loaded" ] || fail "test log has no 'Loaded N tests' line, so the suite never started"
[ "$loaded" -gt 0 ] || fail "no tests loaded"

if [ "$expected" -gt 0 ] && [ "$loaded" -ne "$expected" ]; then
    fail "loaded $loaded tests but $expected exist in project/testing/tests"
fi

grep -q '^Finished!$' "$TEST_LOG" || fail "run did not reach 'Finished!', so it died partway"

summary="$(grep -E '^[0-9]+/[0-9]+ tests failed\.$' "$TEST_LOG" | tail -1)"
[ -n "$summary" ] || fail "no test summary line, so the run did not complete"

failed="${summary%%/*}"
[ "$failed" -eq 0 ] || fail "$summary"

printf 'Verified: %s tests loaded and ran, %s\n' "$loaded" "$summary"
