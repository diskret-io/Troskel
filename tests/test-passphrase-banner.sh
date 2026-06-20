#!/usr/bin/env bash
# tests/test-passphrase-banner.sh
# Unit test for scripts/lib/passphrase-banner.sh.
#
# The per-build scanner passphrase is shown once and never stored. The producer
# (prepare-boot-usb.sh) prints it in a banner; the consumer (troskel-build.sh)
# captures that output and extracts the passphrase for its final summary box.
# These two scripts are coupled by the banner's exact layout, and before this
# module that coupling was an uncommented inline awk in the consumer matching an
# uncommented set of echo lines in the producer. A layout change in one would
# silently break extraction in the other, surfacing only when a full boot-USB
# build aborted on the emptiness guard in front of an operator.
#
# This test guards the round trip. The positive case proves the producer's
# output is extractable by the consumer. The negative cases prove the consumer
# reports a MISS (non-zero, no output) rather than silently emitting the wrong
# line, for each way the contract can be violated. The negative cases are the
# real test: the emptiness guard in the orchestrator only fires on a MISS, so a
# wrong-but-non-empty capture would slip past it. The "text before passphrase"
# case (Test 4) is exactly the regression that a careless banner reword would
# introduce.
#
# Invocation: `bash tests/test-passphrase-banner.sh` (no privilege, no device,
# no container, no network; needs only bash + awk + coreutils). Wired into
# tests/test-validate.sh so it runs under `make validate` (Tier 1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE="${PROJECT_ROOT}/scripts/lib/passphrase-banner.sh"

[ -f "$MODULE" ] || { echo "[!] module not found: $MODULE"; exit 1; }
# shellcheck source=../scripts/lib/passphrase-banner.sh
source "$MODULE"

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
step() { echo ""; echo "=== $* ==="; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ""
echo "=== Tier 1: passphrase banner round trip ==="

# Trim leading whitespace the way troskel-build.sh's summary does, so the
# assertion compares the passphrase itself, not its indentation. The contract
# preserves leading whitespace on purpose; trimming is the caller's job.
trim() { sed 's/^[[:space:]]*//'; }

# ── Test 1: round trip ────────────────────────────────────────────────────────
# Failure mode guarded: the producer's banner must be extractable by the
# consumer. This is the whole point of co-locating them. The passphrase shape
# (four hyphen-joined words) matches what prepare-boot-usb.sh generates.
step "Test 1: producer output round-trips through the consumer"
PHRASE="correct-horse-battery-staple"
BANNER="$WORK/banner.txt"
emit_passphrase_banner "$PHRASE" > "$BANNER" \
    || fail "producer returned non-zero on a valid passphrase"
GOT="$(extract_passphrase "$BANNER" | trim)" \
    || fail "consumer returned non-zero extracting a valid banner"
[ "$GOT" = "$PHRASE" ] \
    || fail "round trip: extracted '$GOT', expected '$PHRASE'"
pass "passphrase survives producer -> consumer unchanged"

# ── Test 2: extra surrounding output ──────────────────────────────────────────
# Failure mode guarded: in production the banner is not the whole captured
# stream. prepare-boot-usb.sh prints progress lines before the banner, and the
# capture may carry trailing output. The extractor must find the passphrase
# inside a larger stream, not only when the banner is the entire input.
step "Test 2: passphrase found amid surrounding output"
{
    echo "[*] Generating scanner-user passphrase..."
    echo "[+] Boot USB written to /dev/sdX."
    emit_passphrase_banner "$PHRASE"
    echo "[*] Done."
} > "$BANNER"
GOT="$(extract_passphrase "$BANNER" | trim)" \
    || fail "consumer returned non-zero on a banner embedded in a stream"
[ "$GOT" = "$PHRASE" ] \
    || fail "embedded banner: extracted '$GOT', expected '$PHRASE'"
pass "passphrase extracted from a realistic captured stream"

# ── Test 3: no banner at all -> MISS ──────────────────────────────────────────
# Failure mode guarded: debug mode (run_step streams instead of capturing) and
# any total-failure case leave the captured file with no banner. The consumer
# must report a MISS so the orchestrator's emptiness guard fires, rather than
# printing an empty or garbage line in the summary box.
step "Test 3: no banner present -> miss (non-zero, no output)"
printf '[*] some unrelated output\n[+] no banner here\n' > "$BANNER"
set +e
GOT="$(extract_passphrase "$BANNER")"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "consumer returned 0 with no banner present"
[ -z "$GOT" ] || fail "consumer emitted output with no banner: '$GOT'"
pass "absent banner reports a miss"

# ── Test 4: text wrongly placed before the passphrase -> wrong line ───────────
# Failure mode guarded: THE regression a banner reword introduces. If
# explanatory text is moved above the passphrase (between the header rule and
# the passphrase line), the extractor captures that text instead, because the
# contract defines the passphrase as the FIRST non-empty line after the header
# rule. The test proves the contract is what we think it is: a violating layout
# does NOT yield the passphrase. This is why invariant 2 forbids text there.
step "Test 4: explanatory text before the passphrase breaks extraction"
{
    echo "============================================================"
    echo "  SCANNER PASSPHRASE"
    echo "============================================================"
    echo ""
    echo "  Record this now, it is not stored anywhere:"
    echo ""
    echo "    $PHRASE"
    echo "============================================================"
} > "$BANNER"
GOT="$(extract_passphrase "$BANNER" | trim)" \
    || fail "consumer returned non-zero (expected it to capture the wrong line)"
[ "$GOT" != "$PHRASE" ] \
    || fail "extractor returned the passphrase despite text placed before it; contract invariant 2 is not being enforced as the test claims"
pass "text before the passphrase yields a non-passphrase line (invariant 2 holds)"

# ── Test 5: producer refuses an empty passphrase ──────────────────────────────
# Failure mode guarded: an empty passphrase would print a banner that extracts
# to nothing, tripping the orchestrator's emptiness guard with a misleading
# "format changed" message when the real fault is upstream. The producer must
# refuse at the source and write nothing.
step "Test 5: producer refuses an empty passphrase"
set +e
emit_passphrase_banner "" > "$BANNER" 2>/dev/null
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "producer returned 0 for an empty passphrase"
[ ! -s "$BANNER" ] || fail "producer wrote a banner for an empty passphrase"
pass "empty passphrase is refused with no output"

# ── Test 6: consumer on a missing file -> MISS ────────────────────────────────
# Failure mode guarded: a mktemp that never got written (an earlier stage
# failed) must read as a clean miss, not an unbound-variable crash or a
# spurious success.
step "Test 6: consumer on a missing capture file -> miss"
set +e
GOT="$(extract_passphrase "$WORK/does-not-exist.txt")"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "consumer returned 0 for a missing file"
[ -z "$GOT" ] || fail "consumer emitted output for a missing file: '$GOT'"
pass "missing capture file reports a miss"

step "Result"
echo "[+] All ${PASS} assertions passed. Passphrase banner protocol is correct."