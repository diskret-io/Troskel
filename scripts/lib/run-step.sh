#!/usr/bin/env bash
# scripts/lib/run-step.sh
#
# Shared stage-runner used by scripts/troskel-build.sh and exercised
# by tests/test-run-step.sh. This file is sourced; it must not be
# executed directly.
#
# Exports:
#
#   - Colour helpers (C_RESET, C_BOLD, C_GREEN, C_YELLOW, C_RED, C_CYAN, C_DIM)
#     Set to empty strings when stdout is not a terminal.
#
#   - Output helpers: header(), progress(), ok(), warn(), fail().
#
#   - run_step(): the project's reference pattern for invoking a
#     sub-script as a named stage with full failure-mode discipline.
#     See QUALITY.md (principle 5: "exit codes are not the only signal
#     worth trusting") and the function's docstring below.
#
# Contract with callers:
#   - Callers must set DEBUG (0 or 1) before invoking run_step. When 1,
#     sub-script output streams live; when 0, output is captured and
#     dumped only on failure.
#   - The POSTCOND environment variable may be set to a function name
#     for a single run_step call; run_step consumes (unsets) it after
#     reading so it does not leak into the next call.
#   - run_step exits the calling shell on failure. Callers expecting
#     to recover from a stage failure must invoke run_step in a
#     subshell or restructure to detect failure differently.

# Source-vs-exec guard. Sourcing is the supported mode; executing this
# file directly is a usage error and almost certainly a mistake.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    echo "[!] scripts/lib/run-step.sh must be sourced, not executed." >&2
    echo "    Use: source scripts/lib/run-step.sh" >&2
    exit 1
fi

# ── Colour helpers ────────────────────────────────────────────────────────────
# Only emit colour codes if stdout is a terminal. Tests that capture
# stdout will get empty strings, which keeps assertion text clean.
if [ -t 1 ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_CYAN='\033[0;36m'
    C_DIM='\033[2m'
else
    C_RESET='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_DIM=''
fi

# ── Output helpers ────────────────────────────────────────────────────────────
header()   { echo ""; echo -e "${C_BOLD}${C_CYAN}══ $* ══${C_RESET}"; }
progress() { echo -e "  ${C_DIM}▸${C_RESET} $*"; }
ok()       { echo -e "  ${C_GREEN}✓${C_RESET} $*"; }
warn()     { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; }
fail()     { echo -e "  ${C_RED}✗${C_RESET} $*"; }

# Run a sub-script as a named stage. In normal mode suppress its output
# and show a single progress/ok line; in debug mode stream everything.
# Failure modes handled:
#
#   1. The sub-script exits non-zero. We fail loudly, dump the captured
#      output, and exit non-zero ourselves. set -e in the caller would
#      do this for us, but doing it explicitly lets us label the
#      failure with the stage name and dump the captured output, which
#      is the information the operator needs.
#
#   2. The sub-script exits zero but the work was not actually done.
#      This is the silent-success failure mode the project hit when
#      inner-script `|| true` patterns swallowed real errors. We guard
#      against it with an optional post-condition: the caller sets
#      POSTCOND=fn_name before the call, run_step invokes the named
#      function after the sub-script returns zero, and a non-zero
#      return from the post-condition fails the stage. The post-
#      condition exists so "exit code 0" is no longer the only signal
#      we trust.
#
# Usage:
#   run_step "Label" command args...
#   POSTCOND=fn_name run_step "Label" command args...
run_step() {
    local LABEL="$1"; shift
    local POSTCOND_FN="${POSTCOND:-}"
    unset POSTCOND   # one-shot; do not leak into the next call
    progress "${LABEL}..."
    if [ "${DEBUG:-0}" -eq 1 ]; then
        if ! "$@"; then
            fail "$LABEL"
            echo -e "${C_RED}Build failed at: ${LABEL}${C_RESET}"
            exit 1
        fi
        if [ -n "$POSTCOND_FN" ] && ! "$POSTCOND_FN"; then
            fail "${LABEL} — post-condition failed"
            echo -e "${C_RED}Build failed at: ${LABEL} (post-condition)${C_RESET}"
            echo "  The sub-script exited zero but the expected result is missing."
            echo "  This indicates a silent failure inside the sub-script."
            exit 1
        fi
        ok "$LABEL"
    else
        local OUT
        OUT="$(mktemp)"
        if ! "$@" > "$OUT" 2>&1; then
            fail "$LABEL"
            echo ""
            echo -e "${C_DIM}--- output ---${C_RESET}"
            cat "$OUT"
            echo -e "${C_DIM}--------------${C_RESET}"
            rm -f "$OUT"
            echo ""
            echo -e "${C_RED}Build failed at: ${LABEL}${C_RESET}"
            echo "  Run with --debug for full output."
            exit 1
        fi
        if [ -n "$POSTCOND_FN" ] && ! "$POSTCOND_FN"; then
            fail "${LABEL} — post-condition failed"
            echo ""
            echo -e "${C_DIM}--- output ---${C_RESET}"
            cat "$OUT"
            echo -e "${C_DIM}--------------${C_RESET}"
            rm -f "$OUT"
            echo ""
            echo -e "${C_RED}Build failed at: ${LABEL} (post-condition)${C_RESET}"
            echo "  The sub-script exited zero but the expected result is missing."
            echo "  This indicates a silent failure inside the sub-script."
            echo "  Run with --debug for full output."
            exit 1
        fi
        ok "$LABEL"
        rm -f "$OUT"
    fi
}