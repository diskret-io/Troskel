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
# A later change added a liveness heartbeat to the non-debug
# captured path (_run_capture_with_heartbeat). Long stages used to
# print one progress line then fall silent for minutes, which
# operators read as a hang (recorded near-miss: an operator pressed
# Enter into the silence, which a later prompt could have consumed
# as confirmation of a destructive step). Tests 6-9 below guard that
# heartbeat and the failure modes the heartbeat itself could
# introduce (leaking into the captured failure dump; an orphaned
# ticker printing after the stage returns).
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
#   5. POSTCOND one-shot (does not leak to next call).
#   6. Long stage emits a heartbeat to the terminal.
#   7. Heartbeat never leaks into the captured output, and a failing
#      long stage's captured dump stays clean while its exit status
#      propagates.
#   8. Sub-interval stage emits no heartbeat.
#   9. No ticker output arrives after the helper returns (orphan check).
#
# Invocation: `bash tests/test-run-step.sh` (no privilege needed;
# no real files touched beyond mktemp scratch space).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_FILE="${PROJECT_ROOT}/scripts/lib/run-step.sh"

# shellcheck source=../scripts/lib/run-step.sh
# The directive above tells shellcheck where to find the file we
# source in the subshells below; the subshells use the $LIB_FILE
# variable for clarity but shellcheck cannot follow a variable, so
# the directive resolves the path statically. Applies to all
# `source "$LIB_FILE"` lines further down.

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
# DEBUG is set inside each subshell because the sourced library
# reads it. shellcheck does not see that consumption because the
# library is sourced via a variable path, so we suppress SC2034
# per use.

# ── Test 1: happy path ───────────────────────────────────────────────────────

step "Test 1: happy path (sub-script exits zero, no POSTCOND)"

OUT_FILE="$(mktemp)"
RC=0
(
    # shellcheck disable=SC2034
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
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck source=../scripts/lib/run-step.sh
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
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck source=../scripts/lib/run-step.sh
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
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck source=../scripts/lib/run-step.sh
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
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck source=../scripts/lib/run-step.sh
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

# ── Test 6: long stage emits a heartbeat ─────────────────────────────────────
#
# Regression: non-debug long stages used to be silent for their whole
# duration, which operators read as a hang. run_step now routes the
# captured invocation through _run_capture_with_heartbeat, which prints
# a liveness line to the terminal every HEARTBEAT_INTERVAL seconds. The
# interval is overridden to 1s here so the test runs quickly; the stage
# sleeps past it. The heartbeat goes to the subshell's stdout (the
# terminal fd the helper saves), which this test captures in $OUT_FILE.

step "Test 6: long stage emits a heartbeat to the terminal"

OUT_FILE="$(mktemp)"
RC=0
(
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck disable=SC2034
    HEARTBEAT_INTERVAL=1
    # shellcheck source=../scripts/lib/run-step.sh
    source "$LIB_FILE"
    run_step "long stage" bash -c 'sleep 2.5; echo done'
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -ne 0 ]; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Long happy stage should exit zero, got $RC"
fi
if ! grep -q "still working" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Long stage should emit at least one heartbeat line (looks-hung regression)"
fi
if ! grep -q "long stage" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Heartbeat line should carry the stage label"
fi
rm -f "$OUT_FILE"
pass "Long stage emits a labelled heartbeat"

# ── Test 7: heartbeat never leaks into captured output ───────────────────────
#
# The helper's contract is that the heartbeat reaches the terminal only,
# never the captured $OUT, so the on-failure dump (and, for the boot
# wrapper, the passphrase-extraction awk) reads clean command output.
# This calls _run_capture_with_heartbeat directly so the captured file
# is inspectable separately from the terminal. A failing long command
# is used so we also confirm the exit status propagates and the captured
# file holds the command's own stderr but no heartbeat lines.

step "Test 7: heartbeat stays out of the captured output; exit status propagates"

OUT_FILE="$(mktemp)"   # subshell stdout (the "terminal")
CAP_FILE="$(mktemp)"   # the helper's captured command output
RC=0
(
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck disable=SC2034
    HEARTBEAT_INTERVAL=1
    # shellcheck source=../scripts/lib/run-step.sh
    source "$LIB_FILE"
    _run_capture_with_heartbeat "$CAP_FILE" "capture stage" \
        bash -c 'sleep 2.5; echo "stderr detail here" >&2; exit 7'
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -ne 7 ]; then
    cat "$OUT_FILE"; echo "--- captured ---"; cat "$CAP_FILE"
    rm -f "$OUT_FILE" "$CAP_FILE"
    fail "Helper should propagate the command's exit status (expected 7, got $RC)"
fi
if grep -q "still working" "$CAP_FILE"; then
    echo "--- captured ---"; cat "$CAP_FILE"
    rm -f "$OUT_FILE" "$CAP_FILE"
    fail "Heartbeat leaked into the captured output — would corrupt the failure dump and passphrase extraction"
fi
if ! grep -q "stderr detail here" "$CAP_FILE"; then
    echo "--- captured ---"; cat "$CAP_FILE"
    rm -f "$OUT_FILE" "$CAP_FILE"
    fail "Captured output should hold the command's own stderr for the dump"
fi
if ! grep -q "still working" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE" "$CAP_FILE"
    fail "Heartbeat should still have reached the terminal during the long stage"
fi
rm -f "$OUT_FILE" "$CAP_FILE"
pass "Heartbeat reaches the terminal only; capture stays clean; exit status propagates"

# ── Test 8: sub-interval stage emits no heartbeat ────────────────────────────
#
# A stage shorter than one interval must not print a heartbeat. The
# helper re-checks the command is still alive after each sleep before
# printing, so a command that finishes within the interval produces no
# beat at all.

step "Test 8: sub-interval stage emits no heartbeat"

OUT_FILE="$(mktemp)"
RC=0
(
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck disable=SC2034
    HEARTBEAT_INTERVAL=5
    # shellcheck source=../scripts/lib/run-step.sh
    source "$LIB_FILE"
    run_step "quick stage" true
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -ne 0 ]; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Quick stage should exit zero, got $RC"
fi
if grep -q "still working" "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "A stage shorter than the interval should emit no heartbeat"
fi
rm -f "$OUT_FILE"
pass "Sub-interval stage stays silent"

# ── Test 9: no ticker output after the helper returns (orphan check) ─────────
#
# The most dangerous failure mode the heartbeat could introduce: a
# background ticker that outlives the foreground command and keeps
# printing after the stage's ok/fail line, corrupting subsequent output.
# The helper kills and reaps the ticker before returning. This test runs
# a long stage, prints a marker the instant the helper returns, then
# idles longer than the interval; any heartbeat appearing after the
# marker means an orphan survived.

step "Test 9: no ticker output arrives after the helper returns"

OUT_FILE="$(mktemp)"
RC=0
(
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck disable=SC2034
    HEARTBEAT_INTERVAL=1
    # shellcheck source=../scripts/lib/run-step.sh
    source "$LIB_FILE"
    CAP="$(mktemp)"
    _run_capture_with_heartbeat "$CAP" "orphan stage" bash -c 'sleep 2.5; echo done'
    rm -f "$CAP"
    echo "AFTER_RETURN_MARKER"
    sleep 2.5
) > "$OUT_FILE" 2>&1 || RC=$?

if [ "$RC" -ne 0 ]; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Orphan-check stage should exit zero, got $RC"
fi
if awk '/AFTER_RETURN_MARKER/{after=1} after && /still working/{found=1} END{exit !found}' "$OUT_FILE"; then
    cat "$OUT_FILE"
    rm -f "$OUT_FILE"
    fail "Orphaned ticker printed a heartbeat after the helper returned"
fi
rm -f "$OUT_FILE"
pass "No ticker output after return; ticker is killed and reaped cleanly"

# ── Test 10: confirm_destructive accepts y and Y ─────────────────────────────
#
# The explicit-assent path. Both lower and upper case confirm.

step "Test 10: confirm_destructive accepts 'y' and 'Y'"

for ANS in y Y; do
    RC=0
    (
        # shellcheck disable=SC2034
        DEBUG=0
        # shellcheck source=../scripts/lib/run-step.sh
        source "$LIB_FILE"
        printf '%s\n' "$ANS" | { confirm_destructive "confirm? "; }
    ) >/dev/null 2>&1 || RC=$?
    if [ "$RC" -ne 0 ]; then
        fail "confirm_destructive should accept '$ANS' as assent, returned $RC"
    fi
done
pass "Both 'y' and 'Y' confirm"

# ── Test 11: bare Enter does not confirm ─────────────────────────────────────
#
# Regression: the old [Y/n] gates defaulted to yes on empty input, so a
# stray Enter confirmed a destructive write. confirm_destructive must
# NOT proceed on empty input. Empty re-asks, so a stream of bare Enters
# followed by EOF must end without ever returning 0. We feed only blank
# lines; the read loop exhausts stdin and the final read fails (EOF),
# which must not be treated as assent.

step "Test 11: bare Enter does not confirm (looks-hung keystroke regression)"

RC=0
(
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck source=../scripts/lib/run-step.sh
    source "$LIB_FILE"
    # Three blank lines then EOF. None must confirm.
    printf '\n\n\n' | { confirm_destructive "confirm? "; }
) >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then
    fail "Bare Enter must never confirm a destructive step (got exit 0)"
fi
pass "Bare Enter does not confirm; empty input re-asks rather than proceeding"

# ── Test 12: non-y input declines ────────────────────────────────────────────

step "Test 12: a non-empty non-y answer declines"

RC=0
(
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck source=../scripts/lib/run-step.sh
    source "$LIB_FILE"
    printf 'n\n' | { confirm_destructive "confirm? "; }
) >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then
    fail "A non-y answer ('n') should decline, got exit 0"
fi
pass "Non-y input declines cleanly"

# ── Test 13: stray Enter before the prompt does not confirm ──────────────────
#
# The safety property, stated as the outcome the operator cares about: a
# stray Enter arriving ahead of the prompt does not proceed the
# destructive step. There is no stdin drain; the property holds because
# the empty line is read as the answer, fails the y/Y check, and
# re-asks (then declines at EOF) rather than confirming. A genuine 'y'
# typed deliberately still works (test 10); this guards the stray case.

step "Test 13: stray Enter before the prompt does not confirm"

RC=0
(
    # shellcheck disable=SC2034
    DEBUG=0
    # shellcheck source=../scripts/lib/run-step.sh
    source "$LIB_FILE"
    # Simulate a stray Enter buffered before the gate, then EOF.
    printf '\n' | { confirm_destructive "confirm? "; }
) >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then
    fail "A stray Enter buffered before the prompt must not confirm (got exit 0)"
fi
pass "Stray pre-prompt input does not confirm the destructive step"

# ── Test 14: stage plan matches the orchestrator's stage_header calls ─────────
#
# Anti-drift. The "Stage N of M" plan lives in scripts/lib/stage-plan.sh
# (compute_stage_plan), and the orchestrator calls stage_header with one
# label per planned stage. If the two drift — a stage renamed in one
# place, added or removed in the other — the operator sees a wrong count
# or a mislabelled stage. This test enforces agreement statically (no
# need to run the privileged orchestrator):
#
#   (a) For every run mode, compute_stage_plan (the real function, not a
#       reparse) yields a non-empty plan, and feeding that plan through
#       stage_plan + one stage_header per label ends with N == M and
#       never exceeds M. That exercises the runtime counter guard.
#
#   (b) Every distinct label compute_stage_plan can emit appears as a
#       stage_header "<label>" call in scripts/troskel-build.sh. This is
#       the label-drift check: rename a stage in one place only and this
#       fails.
#
# The reverse direction (a stage_header with no plan slot) is covered by
# (a): an extra call makes N exceed M and the guard fires.

step "Test 14: stage plan and orchestrator stage_header calls agree"

PLAN_LIB="${PROJECT_ROOT}/scripts/lib/stage-plan.sh"
ORCH="${PROJECT_ROOT}/scripts/troskel-build.sh"
[ -f "$PLAN_LIB" ] || fail "stage-plan.sh not found: $PLAN_LIB"
[ -f "$ORCH" ]     || fail "orchestrator not found: $ORCH"

# (a) counter guard holds for every mode/update combination.
for COMBO in "all 0" "data 0" "boot 0" "all 1" "data 1" "boot 1"; do
    set -- $COMBO
    MODE="$1"; UPD="$2"
    RC=0
    OUT="$(
        # shellcheck source=../scripts/lib/run-step.sh
        source "$LIB_FILE"
        # shellcheck source=../scripts/lib/stage-plan.sh
        source "$PLAN_LIB"
        mapfile -t P < <(compute_stage_plan "$MODE" "$UPD")
        [ "${#P[@]}" -gt 0 ] || { echo "EMPTY_PLAN"; exit 1; }
        stage_plan "${P[@]}"
        for lbl in "${P[@]}"; do
            stage_header "$lbl" >/dev/null || { echo "GUARD_FIRED"; exit 1; }
        done
        # After consuming exactly the plan, current must equal total.
        [ "$_STAGE_CURRENT" -eq "$_STAGE_TOTAL" ] || { echo "N_NE_M:${_STAGE_CURRENT}/${_STAGE_TOTAL}"; exit 1; }
        echo "OK ${#P[@]}"
    )" || RC=$?
    if [ "$RC" -ne 0 ]; then
        fail "Stage-plan counter guard failed for mode='$MODE' update=$UPD: ${OUT}"
    fi
done
pass "Counter guard holds for every run mode (final N == M, never exceeds)"

# (b) every label the plan can emit has a matching stage_header call.
ALL_LABELS="$(
    # shellcheck source=../scripts/lib/stage-plan.sh
    source "$PLAN_LIB"
    { compute_stage_plan all 0
      compute_stage_plan data 0
      compute_stage_plan boot 0
      compute_stage_plan all 1; } | sort -u
)"
MISSING=0
while IFS= read -r LABEL; do
    [ -n "$LABEL" ] || continue
    # Look for stage_header "<LABEL>" in the orchestrator. Match the
    # label as a literal between the quote and a following quote or
    # space-paren (labels may carry runtime suffixes like device or
    # duration appended after the literal, so anchor on the start).
    if ! grep -qF "stage_header \"${LABEL}\"" "$ORCH"; then
        echo "[!] plan label has no matching stage_header call: '${LABEL}'" >&2
        MISSING=1
    fi
done <<< "$ALL_LABELS"
if [ "$MISSING" -ne 0 ]; then
    fail "Stage plan and orchestrator stage_header calls have drifted (see above)"
fi
pass "Every plan label has a matching stage_header call in the orchestrator"

# ── Done ─────────────────────────────────────────────────────────────────────

step "Result"
echo "[+] All assertions passed. run_step failure-mode discipline is correct."