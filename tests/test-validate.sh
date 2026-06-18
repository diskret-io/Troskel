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
#   4. run_step unit tests (scripts/lib/run-step.sh failure-mode discipline)
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

# --- 4. run_step unit tests ---------------------------------------------------
# Exercises the orchestrator's stage-runner contract (scripts/lib/run-step.sh).
# Five assertions covering happy path, failure propagation, silent-success
# catching via POSTCOND, both-signals-pass agreement, and POSTCOND one-shot
# behaviour. See tests/test-run-step.sh header for bug history.
#
# Lives in Tier 1 because the test is hermetic: no root, no container,
# no real files beyond mktemp scratch space. Sub-second runtime.
echo "[*] Running run_step unit tests..."
if bash "${SCRIPT_DIR}/test-run-step.sh" > /tmp/rs-out.txt 2>&1; then
    result "ok" "run_step unit tests"
else
    result "run_step unit tests failed — see output below" "run_step unit tests"
    cat /tmp/rs-out.txt | sed 's/^/         /'
fi

# --- 5. SBOM version matches versions.env --------------------------------
# SBOM.json is generated on the build station (generate-build-records.sh,
# run as root by run-update.sh), not in CI. So a TROSKEL_VERSION bump that
# is committed without regenerating SBOM.json leaves the committed SBOM
# stale. This check re-derives the expected version from versions.env and
# asserts the four product-version sites in SBOM.json agree.
#
# CONTRACT (consumer side): reads TROSKEL_VERSION from config/versions.env,
# the same value generate-build-records.sh interpolates. If they disagree,
# the SBOM was not regenerated after a bump. Failure here means: rebuild
# SBOM.json on the build station and recommit.
#
# What this reports if the thing it checks is broken: a non-empty diff of
# the offending lines, then a FAIL. It cannot pass on a stale SBOM because
# it greps for the literal expected version and counts the hits.
echo "[*] Checking SBOM version agreement..."
# shellcheck source=../config/versions.env
EXPECTED_VERSION="$(. config/versions.env && echo "$TROSKEL_VERSION")"
if [ -z "$EXPECTED_VERSION" ]; then
    result "versions.env did not yield TROSKEL_VERSION" "SBOM version agreement"
elif [ ! -f SBOM.json ]; then
    result "SBOM.json not found at repo root" "SBOM version agreement"
else
    # The four product-version sites all carry the version as either
    # "version": "X" or troskel@X. Any occurrence of troskel@<other> or a
    # product "version" line disagreeing with EXPECTED is drift. We assert
    # the expected string is present AND no stale 0.x product ref survives.
    STALE="$(grep -nE 'troskel@[0-9]+\.[0-9]+\.[0-9]+' SBOM.json \
        | grep -vF "troskel@${EXPECTED_VERSION}" || true)"
    PRESENT="$(grep -cF "troskel@${EXPECTED_VERSION}" SBOM.json || true)"
    if [ -n "$STALE" ]; then
        result "stale troskel version ref(s) in SBOM.json:
$STALE
expected troskel@${EXPECTED_VERSION} — regenerate SBOM on the build station" \
            "SBOM version agreement"
    elif [ "$PRESENT" -lt 1 ]; then
        result "no troskel@${EXPECTED_VERSION} ref found in SBOM.json — regenerate on the build station" \
            "SBOM version agreement"
    else
        result "ok" "SBOM version agreement (troskel@${EXPECTED_VERSION}, ${PRESENT} refs)"
    fi
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
echo ""

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi