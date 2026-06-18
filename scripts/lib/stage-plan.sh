#!/usr/bin/env bash
# scripts/lib/stage-plan.sh
#
# Single source of truth for the orchestrator's "Stage N of M" framing.
# Sourced by scripts/troskel-build.sh and exercised directly by
# tests/test-run-step.sh; this file must not be executed.
#
# Three pieces:
#
#   compute_stage_plan <mode> <update_only>
#       Echoes, one per line, the ordered set of stage labels that
#       will run for the given flags. This is the single place the
#       set-of-stages logic lives. The orchestrator builds its counter
#       from it; the test calls it directly to assert the labels match
#       the stage_header call sites in the orchestrator (no drift).
#
#   stage_plan <label>...
#       Registers the total stage count (M) and resets the counter.
#       Called once, before the first stage_header.
#
#   stage_header <label>
#       Prints "Stage N of M: <label>" and advances the counter. If
#       called more times than stage_plan registered, fails loudly
#       rather than printing an N that exceeds M.
#
# CONTRACT (producer side): the labels echoed by compute_stage_plan
# must be identical to the stage_header "<label>" calls in
# scripts/troskel-build.sh. The orchestrator does:
#
#     mapfile -t STAGES < <(compute_stage_plan "$USB_MODE" "$UPDATE_ONLY")
#     stage_plan "${STAGES[@]}"
#     ...
#     stage_header "Runtime detection"   # etc., one per planned stage
#
# tests/test-run-step.sh (case 14) enforces the agreement: every label
# compute_stage_plan can emit must appear as a stage_header call in the
# orchestrator source, and the counter guard (final N == M, never
# exceeding) must hold for every mode. Consumer of the contract: the
# test and the orchestrator both. Keep the labels here and the
# stage_header calls there in lockstep; the test fails the PR if they
# drift.

# Source-vs-exec guard.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    echo "[!] scripts/lib/stage-plan.sh must be sourced, not executed." >&2
    exit 1
fi

# Compute the ordered stage plan for a run.
# Args: $1 = USB_MODE (all|data|boot), $2 = UPDATE_ONLY (0|1)
# Echoes one stage label per line, in execution order.
#
# Note: 'all' and 'data' produce the same plan. In data mode the
# "Writing USBs" stage writes only the data USB, but it is still a
# single write stage followed by verification; the label stays generic
# because the stage heading is followed by per-device progress lines
# that name the specific device.
compute_stage_plan() {
    local mode="$1" update_only="$2"
    echo "Runtime detection"
    [ "$update_only" -eq 0 ] && echo "USB detection"
    echo "Preflight checks"
    echo "Updating artefacts"
    if [ "$update_only" -eq 0 ]; then
        case "$mode" in
            all|data) echo "Writing USBs"; echo "Verification" ;;
            boot)     echo "Writing USBs" ;;
        esac
    fi
}

_STAGE_TOTAL=0
_STAGE_CURRENT=0

# Register the total number of stages (M) and reset the counter.
stage_plan() {
    _STAGE_TOTAL="$#"
    _STAGE_CURRENT=0
}

# Print a numbered stage header and advance the counter. Relies on the
# colour vars and spacing convention from run-step.sh, which the
# orchestrator sources before this file. Returns non-zero (and prints a
# diagnostic) if called more times than stage_plan registered: that
# means the plan and the call sites have drifted, and printing
# "Stage 7 of 6" would be worse than failing.
stage_header() {
    local label="$1"
    _STAGE_CURRENT=$((_STAGE_CURRENT + 1))
    if [ "$_STAGE_TOTAL" -gt 0 ] && [ "$_STAGE_CURRENT" -gt "$_STAGE_TOTAL" ]; then
        echo -e "  ${C_RED:-}✗${C_RESET:-} internal: stage ${_STAGE_CURRENT} exceeds planned ${_STAGE_TOTAL} (plan/call drift)" >&2
        return 1
    fi
    echo ""
    echo -e "${C_BOLD:-}${C_CYAN:-}══ Stage ${_STAGE_CURRENT} of ${_STAGE_TOTAL}: ${label} ══${C_RESET:-}"
}