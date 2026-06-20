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
#   4b. passphrase banner round-trip (scripts/lib/passphrase-banner.sh)
#   4c. load-scanner banner + rootfs verification (host-scripts/load-scanner)
#   5. SBOM.json product version matches versions.env
#   6. Deprecated make aliases fail with a rename pointer; no phony
#      target is declared without a recipe.
#
# This tier runs on any Linux host with butane and shellcheck installed,
# including inside the troskel-build container without --privileged.
# It is the fast feedback loop for config and script changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

# Pass/fail tally. Both counters are read by the summary block at the end
# of the script, which exits non-zero if FAIL is greater than zero. The
# result() helper records a check's outcome and continues rather than
# exiting, so a single run reports every failing check at once instead of
# stopping at the first; the final summary is what makes the suite
# load-bearing. Do not convert checks to exit-on-first-failure: that would
# lose the report-everything property this design exists to provide.
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

# --- 4b. passphrase banner round-trip test -----------------------------------
# Exercises the producer/consumer contract in scripts/lib/passphrase-banner.sh:
# prepare-boot-usb.sh prints the banner, troskel-build.sh extracts the passphrase
# from it. Both halves live in the one module so the banner layout and the awk
# that parses it cannot drift apart; this test is what makes that guarantee
# load-bearing. Hermetic (no root, no container, sub-second), so it lives in
# Tier 1 alongside the run_step tests. See tests/test-passphrase-banner.sh
# header for the drift risk it guards.
echo "[*] Running passphrase banner round-trip test..."
if bash "${SCRIPT_DIR}/test-passphrase-banner.sh" > /tmp/pb-out.txt 2>&1; then
    result "ok" "passphrase banner round-trip"
else
    result "passphrase banner round-trip failed — see output below" "passphrase banner round-trip"
    cat /tmp/pb-out.txt | sed 's/^/         /'
fi

# --- 4c. load-scanner banner + rootfs-verification test ----------------------
# Exercises config/host-scripts/load-scanner against fixture directories via its
# DATA_USB/DEST/MOUNT/ETC_ISSUE env seams: host-side rootfs verification (a
# failed verification is fatal and removes the bad copy) and pre-login banner
# generation (a good load writes /etc/issue agreeing with $DEST; a fatal load
# leaves the Butane default standing). Hermetic (no root, no device, no
# container, sub-second), so it belongs in Tier 1. See tests/test-load-scanner.sh
# header for the bug history it guards.
echo "[*] Running load-scanner unit tests..."
if bash "${SCRIPT_DIR}/test-load-scanner.sh" > /tmp/ls-out.txt 2>&1; then
    result "ok" "load-scanner unit tests"
else
    result "load-scanner unit tests failed — see output below" "load-scanner unit tests"
    cat /tmp/ls-out.txt | sed 's/^/         /'
fi

# --- 5. SBOM version matches versions.env --------------------------------
# SBOM.json is generated on the build station, not in CI. A TROSKEL_VERSION
# bump committed without regenerating SBOM.json leaves the committed SBOM
# stale. This check re-derives the expected version and asserts BOTH forms
# the product version takes in the SBOM agree:
#   - the purl/ref form: troskel@X.Y.Z   (component purl, dependency ref,
#     composition assembly)
#   - the bare field form: "version": "X.Y.Z" inside the product component
# Both must be checked. An earlier version of this check keyed only on the
# purl form and passed against an SBOM whose bare "version" field had
# drifted to a stale value — a decorative check that could not detect the
# failure it claimed to. See bug history below.
#
# CONTRACT (consumer side): reads TROSKEL_VERSION from config/versions.env,
# the same value generate-build-records.sh interpolates. Disagreement means
# the SBOM was not regenerated after a bump: rebuild on the build station
# and recommit.
#
# What this reports if broken: the offending stale line(s) and a FAIL. It
# cannot pass on a stale SBOM because it counts both expected forms and
# rejects any same-shaped occurrence carrying a different version.
echo "[*] Checking SBOM version agreement..."
# shellcheck source=../config/versions.env
EXPECTED_VERSION="$(. config/versions.env && echo "$TROSKEL_VERSION")"
if [ -z "$EXPECTED_VERSION" ]; then
    result "versions.env did not yield TROSKEL_VERSION" "SBOM version agreement"
elif [ ! -f SBOM.json ]; then
    result "SBOM.json not found at repo root" "SBOM version agreement"
else
    # Stale purl/ref form: any troskel@<semver> that is not the expected one.
    STALE_PURL="$(grep -nE 'troskel@[0-9]+\.[0-9]+\.[0-9]+' SBOM.json \
        | grep -vF "troskel@${EXPECTED_VERSION}" || true)"
    # The product component's bare "version" field. It is the "version" line
    # immediately following the "name": "troskel" line (the top-level
    # metadata.component, type application). Extract it directly rather than
    # grepping all "version" lines (upstream components legitimately carry
    # other versions).
    PRODUCT_VERSION="$(grep -A2 '"name": "troskel"' SBOM.json \
        | grep '"version"' | head -1 \
        | sed -E 's/.*"version": *"([^"]*)".*/\1/')"
    PRESENT_PURL="$(grep -cF "troskel@${EXPECTED_VERSION}" SBOM.json || true)"
    if [ -n "$STALE_PURL" ]; then
        result "stale troskel purl/ref(s) in SBOM.json:
$STALE_PURL
expected troskel@${EXPECTED_VERSION} — regenerate SBOM on the build station" \
            "SBOM version agreement"
    elif [ "$PRESENT_PURL" -lt 1 ]; then
        result "no troskel@${EXPECTED_VERSION} purl found in SBOM.json — regenerate on the build station" \
            "SBOM version agreement"
    elif [ "$PRODUCT_VERSION" != "$EXPECTED_VERSION" ]; then
        result "product component \"version\" field is \"${PRODUCT_VERSION}\", expected \"${EXPECTED_VERSION}\" — SBOM not fully regenerated (the bug the purl-only check missed)" \
            "SBOM version agreement"
    else
        result "ok" "SBOM version agreement (version field and ${PRESENT_PURL} purl refs all ${EXPECTED_VERSION})"
    fi
fi


# --- 6. Deprecated make aliases fail loudly (static check) --------------------
# build, scan, and all were renamed. They are retained in the Makefile
# only to emit a rename pointer and exit non-zero. This check validates
# that by parsing the Makefile statically rather than invoking make:
# `make` is not installed in the troskel-build container this script runs
# in, and the check is about a repo artefact (the Makefile text), not
# runtime behaviour, so a hermetic parse is both sufficient and more
# robust than shelling out.
#
# For each alias we extract its recipe block (the target line plus the
# tab-indented recipe lines beneath it, skipping blank/comment lines) and
# assert the block:
#   (a) exists at all — guards the alias being dropped from the Makefile,
#       which would give a bare "No rule to make target" at the operator's
#       terminal, reading as a broken checkout;
#   (b) contains the literal replacement command (e.g. "make test-build")
#       — guards the pointer text going missing or wrong;
#   (c) contains a non-zero `exit` in the recipe — guards the alias being
#       given a succeeding recipe, which would let a stale caller of the
#       old name succeed and mask the rename.
# (a)+(c) together are what the runtime invocation used to prove (alias
# exits non-zero); (b) is the pointer text. A purely textual check cannot
# observe make's exit code, so (c) asserts the recipe shape that produces
# it; if the recipe form that guarantees non-zero exit ever changes,
# update this assertion alongside it.
echo "[*] Checking deprecated make aliases (static)..."
ALIAS_FAIL=0

# Extract the recipe block for a target from the Makefile: the lines from
# the "target:" line up to (not including) the next line that is neither
# blank, nor a comment, nor tab-indented. Recipe lines in make are
# tab-indented; we keep those.
alias_recipe_block() {
    local target="$1"
    awk -v t="$target" '
        $0 ~ "^" t ":" { grab=1; next }
        grab {
            # A tab-indented line is part of the recipe.
            if ($0 ~ /^\t/) { print; next }
            # Blank lines and comment lines may sit inside/after; tolerate
            # blanks but stop at the first non-recipe content line.
            if ($0 ~ /^[[:space:]]*$/) { next }
            if ($0 ~ /^#/)            { next }
            grab=0
        }
    ' Makefile
}

check_alias_static() {
    local target="$1" expect="$2" block
    block="$(alias_recipe_block "$target")"
    if [ -z "$block" ]; then
        printf "    FAIL %s: no recipe found in Makefile (alias dropped?)\n" "$target"
        ALIAS_FAIL=1
        return
    fi
    if ! printf '%s' "$block" | grep -qF "$expect"; then
        printf "    FAIL %s: recipe does not name replacement '%s'\n" "$target" "$expect"
        ALIAS_FAIL=1
        return
    fi
    # A non-zero exit: `exit N` with N != 0. Match `exit` followed by a
    # non-zero digit. `exit 0` (or a bare `exit`, which is exit-of-last-
    # status) does not count as a deliberate failure.
    if ! printf '%s' "$block" | grep -qE 'exit[[:space:]]+[1-9][0-9]*'; then
        printf "    FAIL %s: recipe does not exit non-zero (would succeed and mask the rename)\n" "$target"
        ALIAS_FAIL=1
        return
    fi
    printf "    ok  %s -> names %s and exits non-zero\n" "$target" "$expect"
}
check_alias_static build "make test-build"
check_alias_static scan  "make test-scan"
check_alias_static all   "make test"

# Belt-and-braces: no .PHONY name may lack a recipe. A phony name with no
# recipe gives "No rule to make target" at runtime, the same broken-
# checkout symptom as a dropped alias. Parse the .PHONY declaration
# (which may span several lines via trailing backslash continuations,
# as it does here), then confirm each listed target has a "target:" rule
# line in the Makefile. The continuation handling matters: the deprecated
# aliases live on the continuation line, so a parser that read only the
# first .PHONY line would silently skip the very targets this guards.
PHONY_NAMES="$(awk '
    /^\.PHONY:/      { collecting=1; sub(/^\.PHONY:/, "") }
    collecting {
        cont = (/\\[[:space:]]*$/)   # does this line continue?
        gsub(/\\/, "")
        print
        if (!cont) collecting=0
    }
' Makefile | tr -s ' ' '\n' | sed '/^$/d' | sort -u)"
for t in $PHONY_NAMES; do
    if ! grep -qE "^${t}:" Makefile; then
        printf "    FAIL .PHONY lists '%s' but no '%s:' rule defines it\n" "$t" "$t"
        ALIAS_FAIL=1
    fi
done

if [ "$ALIAS_FAIL" -eq 0 ]; then
    result "ok" "deprecated make aliases name replacement and exit non-zero; no recipe-less phony targets"
else
    result "one or more make-alias checks failed — see above" \
        "deprecated make aliases name replacement and exit non-zero; no recipe-less phony targets"
fi

# ── Summary and exit gate ─────────────────────────────────────────────────────
# The script reaches here having run every check and recorded each via
# result(). This is the load-bearing step: the suite exits non-zero if any
# check failed, which is what makes `make validate` an actual CI gate
# rather than a log that scrolls past green regardless. Before this block
# existed, FAIL was incremented but never read and the script exited zero
# no matter what, so every Tier 1 check was decorative (see the
# validate-suite-never-fails card for the history).
#
# Self-test hook. The gate above is itself a success indicator, and a
# success indicator must be able to fail (QUALITY.md principle 2). Setting
# VALIDATE_SELFTEST_FORCE_FAIL=1 injects one synthetic failed check here,
# so an operator (or a CI meta-check) can confirm the suite exits non-zero
# when something is wrong without having to break a real input. With the
# variable unset this is inert. The hook exists so the gate cannot
# silently regress to always-zero again: a one-line invocation
# (`VALIDATE_SELFTEST_FORCE_FAIL=1 bash tests/test-validate.sh; echo $?`)
# proves the gate bites and must print a non-zero status.
if [ "${VALIDATE_SELFTEST_FORCE_FAIL:-0}" -eq 1 ]; then
    result "self-test: forced failure injected (VALIDATE_SELFTEST_FORCE_FAIL=1)" \
        "self-test gate liveness"
fi

echo ""
echo "=== Tier 1 summary: ${PASS} passed, ${FAIL} failed ==="
echo ""
if [ "$FAIL" -ne 0 ]; then
    echo "[!] Tier 1 static validation failed. See the [FAIL] lines above."
    exit 1
fi
echo "[+] Tier 1 static validation passed."
echo ""
exit 0