#!/usr/bin/env bash
# tests/test-run-step.sh
# Unit test for scripts/lib/run-step.sh's run_step function.
#
# Bug history: troskel-build.sh's run_step originally trusted the
# sub-script's exit code as the sole signal of success. Inner
# scripts using `|| true` patterns could swallow real failures and
# exit zero; the orchestrator reported a green tick against work
# that was not actually done. Concretely: a data USB write reported
# as "successful" while leaving the previous content (Fedora ISO)
# intact, because the inner script's umount-before-wipe failed
# silently and was swallowed.
#
# The fix added an optional POSTCOND mechanism: run_step calls a
# named function after the sub-script returns zero, and a non-zero
# return from the post-condition fails the stage. The lesson
# generalises to QUALITY.md principle 5: exit codes are not the
# only signal worth trusting.
#
# This test exercises:
#
#   1. Happy path. Sub-script exits zero, no POSTCOND. Stage passes.
#   2. Sub-script exits non-zero. Stage fails, captured output is
#      surfaced to the test (not buried), exit code propagates.
#   3. Sub-script exits zero but POSTCOND returns non-zero. The
#      silent-success failure mode. Stage must fail; surfacing this
#      is the test's primary purpose.
#   4. Happy path with passing POSTCOND. Both signals must agree.
#
# Invocation: `bash tests/test-run-step.sh` (no privilege needed;
# no real files touched beyond mktemp scratch space).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_FILE="${PROJECT_ROOT}/scripts/lib/run-step.sh"

[ -f "$LIB_FILE" ] || {
    echo "[!] Library not found: $LIB_FILE" >&2
    exit 1
}

step() { echo ""; echo "=== $* ==="; }
pass() { echo "[+] $*"; }
fail() { echo "[!] $*" >&2; exit 1; }

# Each run_step invocation is wrapped in a subshell so that its
# internal `exit 1` (on failure) terminates the subshell rather than
# the test. We capture the subshell's combined output and exit code
# separately so assertions can examine both.
#
# The pattern: run the subshell with the library sourced and
# DEBUG=0 (or 1 where the test specifies), execute run_step against
# a known input, capture stdout/stderr to a tempfile and the exit
# code into a variable. Then assert on both.

# ── Test 1: happy path ───────────────────────────────────────────────────────

step "Test 1: happy path (sub-script exits zero, no POSTCOND)"

OUT_FILE="$(mktemp)"
RC=0
(
    DEBUG=0
    # shellcheck source=../scripts/lib/run-step.sh
    source "$LIB_FILE"
    run_step "test stage" true
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -ne 0 ]; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Happy path should exit zero, got $RC"
fi
if ! grep -q "test stage" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Happy path output should mention the stage label"
fi
rm -f "$OUT_FILE"
pass "Happy path passes cleanly"

# ── Test 2: sub-script exits non-zero ────────────────────────────────────────

step "Test 2: sub-script exits non-zero"

OUT_FILE="$(mktemp)"
RC=0
(
    DEBUG=0
    source "$LIB_FILE"
    # Use a command that exits non-zero with output on stderr, so we
    # can also verify the output is surfaced.
    run_step "failing stage" bash -c 'echo "real error message here" >&2; exit 7'
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -eq 0 ]; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Sub-script failure should propagate non-zero exit, got 0"
fi
if ! grep -q "Build failed at: failing stage" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Failure output should name the failing stage"
fi
if ! grep -q "real error message here" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Failure output should surface the sub-script's stderr (not bury it)"
fi
rm -f "$OUT_FILE"
pass "Sub-script failure propagates and surfaces the error message"

# ── Test 3: silent-success (sub-script zero, POSTCOND non-zero) ──────────────
#
# This is the regression test. Under the pre-fix code (no POSTCOND
# mechanism) this scenario would report success despite the work
# not being done. The test asserts run_step now catches it.

step "Test 3: silent-success failure mode (POSTCOND catches it)"

OUT_FILE="$(mktemp)"
RC=0
(
    DEBUG=0
    source "$LIB_FILE"
    # The "sub-script" succeeds (exit 0) but does no observable work.
    # The post-condition checks whether work happened and reports the
    # absent artefact.
    silent_failure_postcond() {
        echo "[!] Post-condition: expected artefact is missing" >&2
        return 1
    }
    POSTCOND=silent_failure_postcond \
        run_step "silently-failing stage" bash -c 'echo "I lied about working"; exit 0'
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -eq 0 ]; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Silent-success scenario should fail the stage, got exit 0. This is the bug-class regression test."
fi
if ! grep -q "post-condition failed" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Failure output should identify the failure as a post-condition failure"
fi
if ! grep -q "silent failure inside the sub-script" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Failure output should explain the silent-success diagnostic to the operator"
fi
rm -f "$OUT_FILE"
pass "POSTCOND catches the silent-success failure mode"

# ── Test 4: happy path with passing POSTCOND ─────────────────────────────────

step "Test 4: happy path with passing POSTCOND (both signals agree)"

OUT_FILE="$(mktemp)"
RC=0
(
    DEBUG=0
    source "$LIB_FILE"
    passing_postcond() {
        return 0
    }
    POSTCOND=passing_postcond \
        run_step "passing stage" true
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -ne 0 ]; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Both-signals-pass should exit zero, got $RC"
fi
rm -f "$OUT_FILE"
pass "Both signals agreeing on success passes the stage"

# ── Test 5: POSTCOND is one-shot ─────────────────────────────────────────────
#
# The contract says POSTCOND must not leak into the next call. If
# the first call leaks its POSTCOND to a second call, the second
# call's behaviour becomes accidentally dependent on the first.

step "Test 5: POSTCOND is one-shot (does not leak to next call)"

OUT_FILE="$(mktemp)"
RC=0
(
    DEBUG=0
    source "$LIB_FILE"
    failing_postcond() {
        return 1
    }
    # First call: POSTCOND set, must fail.
    # If the first call consumes POSTCOND properly we never reach
    # the second call. If it does NOT consume POSTCOND, the leak
    # would only matter if run_step survived the first call —
    # which it does not (exit 1 on post-condition failure). So
    # the leak is not directly observable from outside a single
    # subshell. The robust assertion is on the unset itself:
    # source the library, set POSTCOND, run a passing stage, then
    # assert POSTCOND is unset after the call.
    POSTCOND=failing_postcond
    # Use a passing command and a passing-postcond context, but
    # set POSTCOND before run_step is invoked.
    POSTCOND=failing_postcond
    # Override the function name to a passing one for this test:
    failing_postcond() { return 0; }
    run_step "first stage" true
    # If POSTCOND leaked, it would be set to "failing_postcond"
    # here. Assert it is unset.
    if [ -n "${POSTCOND:-}" ]; then
        echo "[!] POSTCOND leaked after call: ${POSTCOND}" >&2
        exit 1
    fi
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -ne 0 ]; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "POSTCOND leak detected (test 5)"
fi
rm -f "$OUT_FILE"
pass "POSTCOND is correctly unset after the call"

# ── Done ─────────────────────────────────────────────────────────────────────

step "Result"
echo "[+] All assertions passed. run_step failure-mode discipline is correct."