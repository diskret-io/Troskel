#!/usr/bin/env bash
# tests/test-validate.sh
# Tier 1 — static validation. No root or KVM required.
# Run from the project root:
#   bash tests/test-validate.sh
#
# Checks:
#   1. Butane config compiles without error (with dummy password hash)
#   2. shellcheck passes on all shell scripts in the project
#   3. guest/run-scan.sh uses only POSIX sh constructs (no bashisms)
#
# This tier runs on any Linux host with butane and shellcheck installed,
# including inside the troskel-build container without --privileged.
# It is the fast feedback loop for config and script changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

PASS=0
FAIL=0

result() {
    local STATUS="$1" DESC="$2"
    if [ "$STATUS" = "ok" ]; then
        printf "  [PASS] %s\n" "$DESC"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n" "$DESC"
        printf "         %s\n" "$STATUS"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== Tier 1: static validation ==="
echo ""

# --- 1. Butane config compiles -------------------------------------------
# Substitute the sentinel with a syntactically valid dummy hash so
# butane --strict does not reject the config as malformed.
echo "[*] Checking Butane config..."
TMP_CONFIG="$(mktemp --suffix=.bu)"
trap 'rm -f "$TMP_CONFIG"' EXIT
sed 's|@@SCANNER_PASSWORD_HASH@@|$6$dummysalt$dummyhashfortestingpurposesonly0000000000000000000000000000000000000000000000000000.|' \
    config/scanner-host.bu > "$TMP_CONFIG"

if butane --strict --files-dir config "$TMP_CONFIG" > /dev/null 2>&1; then
    result "ok" "Butane config compiles cleanly"
else
    result "$(butane --strict --files-dir config "$TMP_CONFIG" 2>&1 || true)" \
        "Butane config compiles cleanly"
fi

# --- 2. shellcheck -----------------------------------------------------------
echo "[*] Running shellcheck..."
# Collect all shell scripts in the project. We look for files with a shell
# shebang rather than relying on extension, because the host-scripts
# (troskel, scan-wrap, load-scanner, show-status, check-system-ready)
# have no extension by convention.
SHELL_SCRIPTS="$(grep -rl '^#!/.*sh' \
    scripts/ \
    config/host-scripts/ \
    tests/ \
    guest/run-scan.sh \
    2>/dev/null | sort)"

SC_FAIL=0
for SCRIPT in $SHELL_SCRIPTS; do
    if shellcheck --severity=warning "$SCRIPT" > /tmp/sc-out.txt 2>&1; then
        printf "    ok  %s\n" "$SCRIPT"
    else
        printf "    FAIL %s\n" "$SCRIPT"
        cat /tmp/sc-out.txt | sed 's/^/         /'
        SC_FAIL=1
    fi
done

if [ "$SC_FAIL" -eq 0 ]; then
    result "ok" "shellcheck (all scripts)"
else
    result "one or more shellcheck failures — see above" "shellcheck (all scripts)"
fi

# --- 3. POSIX sh compliance for the guest entrypoint ----------------------
# The guest runs busybox sh, not bash. The script must not use bashisms.
# checkbashisms (from devscripts) is preferred; fall back to a lighter
# heuristic if it is not installed.
echo "[*] Checking guest/run-scan.sh for bashisms..."
if command -v checkbashisms >/dev/null 2>&1; then
    if checkbashisms guest/run-scan.sh > /tmp/cb-out.txt 2>&1; then
        result "ok" "guest/run-scan.sh is POSIX sh compatible (checkbashisms)"
    else
        result "$(cat /tmp/cb-out.txt)" \
            "guest/run-scan.sh is POSIX sh compatible (checkbashisms)"
    fi
else
    # Lightweight heuristic: flag known bashisms that would break busybox sh.
    # This is not exhaustive; checkbashisms is preferred.
    BASHISMS="$(grep -En \
        'local [^=]+=|declare |typeset |\[\[|\]\]|<<<|&>>|[^$]\$\(\(|\becho -[eE]' \
        guest/run-scan.sh || true)"
    if [ -z "$BASHISMS" ]; then
        result "ok" "guest/run-scan.sh has no obvious bashisms (heuristic — install checkbashisms for full coverage)"
    else
        result "possible bashisms found: $BASHISMS" \
            "guest/run-scan.sh is POSIX sh compatible (heuristic)"
    fi
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
echo ""

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi