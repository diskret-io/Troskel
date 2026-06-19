#!/usr/bin/env bash
# tests/test-verify-artefact.sh
# Unit test for scripts/lib/verify-artefact.sh.
#
# This module is the single implementation of the sidecar produce/verify
# protocol that decides whether a written USB is trustworthy. Its consumer
# must return a DISTINCT, correct result for each failure mode, and must be
# immune to the historical "sidecar absolute path" bug (bug 2), where a
# verifier followed an absolute path in the sidecar back to the source on the
# host and reported success against a USB that may never have been written.
#
# Every assertion below names the failure mode it guards. The absolute-path
# and traversal cases (tests 5-7) are the regression tests for bug 2: under
# the old per-site code, an absolute-path sidecar verified the source, not the
# copy; here it must be rejected outright as MALFORMED_SIDECAR before any
# hashing happens.
#
# Invocation: `bash tests/test-verify-artefact.sh` (no privilege, no device,
# no container; needs only bash + coreutils). Also intended to be wired into
# tests/test-build.sh so it runs under `make test-build`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE="${PROJECT_ROOT}/scripts/lib/verify-artefact.sh"

[ -f "$MODULE" ] || { echo "[!] module not found: $MODULE"; exit 1; }
# shellcheck source=../scripts/lib/verify-artefact.sh
source "$MODULE"

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
step() { echo ""; echo "=== $* ==="; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ""
echo "=== Tier 1: artefact verification ==="

# A "mount point" is just a directory here; the module never requires a real
# mount, only a directory to resolve the artefact under. This is what lets the
# test be hermetic.
MOUNT="$WORK/mount"
mkdir -p "$MOUNT"

# assert_result <expected-token> <expected-rc> <description>
# Runs verify_artefact_check against the current $MOUNT/$SIDECAR and checks
# both the printed token and the exit code. Both are required: a correct token
# with the wrong rc (or vice versa) is a failure, because callers key on the
# rc and logs show the token.
SIDECAR=""
assert_result() {
    local want_token="$1" want_rc="$2" desc="$3" got_token got_rc
    set +e
    got_token="$(verify_artefact_check "$MOUNT" "$SIDECAR" 2>/dev/null)"
    got_rc=$?
    set -e
    [ "$got_token" = "$want_token" ] \
        || fail "$desc: token was '$got_token', expected '$want_token'"
    [ "$got_rc" -eq "$want_rc" ] \
        || fail "$desc: rc was $got_rc, expected $want_rc"
    pass "$desc"
}

# ── Producer: emits a basename-only sidecar ──────────────────────────────────
step "Test 0: producer emits a safe, basename-only sidecar"
ART="$WORK/src/scanner-rootfs.ext4"
mkdir -p "$WORK/src"
printf 'pretend rootfs bytes\n' > "$ART"
verify_artefact_emit "$ART" || fail "emit returned non-zero on a valid artefact"
[ -f "${ART}.sha256" ] || fail "emit did not create the sidecar"
SIDE_LINE="$(cat "${ART}.sha256")"
# Must be '<64hex>  <basename>' with NO path.
printf '%s' "$SIDE_LINE" | grep -qE '^[0-9a-f]{64}  scanner-rootfs\.ext4$' \
    || fail "emitted sidecar is not basename-only: $SIDE_LINE"
# And must NOT contain the source directory path anywhere.
printf '%s' "$SIDE_LINE" | grep -q "$WORK" \
    && fail "emitted sidecar leaked an absolute path: $SIDE_LINE"
pass "producer emits '<hash>  <basename>' with no path"

# ── Test 1: VERIFIED ─────────────────────────────────────────────────────────
# Failure mode guarded: the happy path must actually pass. (Necessary but not
# sufficient on its own; the old code passed this too. The negative cases are
# the real test.)
step "Test 1: matching artefact -> VERIFIED"
cp "$ART" "$MOUNT/scanner-rootfs.ext4"
cp "${ART}.sha256" "$MOUNT/scanner-rootfs.ext4.sha256"
SIDECAR="$MOUNT/scanner-rootfs.ext4.sha256"
assert_result "$VERIFY_VERIFIED" 0 "matching artefact verifies"

# ── Test 2: MISMATCH_ON_DISK ─────────────────────────────────────────────────
# Failure mode guarded: a corrupted or truncated copy on the USB must be
# caught. This is the core reason the protocol exists. Flip a byte after the
# sidecar was written, exactly the negative-case-test-sidecar scenario.
step "Test 2: corrupted artefact -> MISMATCH_ON_DISK"
printf 'corruption' >> "$MOUNT/scanner-rootfs.ext4"
assert_result "$VERIFY_MISMATCH" 3 "corrupted artefact fails verification"

# ── Test 3: MISSING_FILE ─────────────────────────────────────────────────────
# Failure mode guarded: the sidecar names a file that is not on the medium
# (write never happened, or wrong USB). Must be distinct from a hash mismatch.
step "Test 3: artefact absent from mount -> MISSING_FILE"
rm -f "$MOUNT/scanner-rootfs.ext4"
assert_result "$VERIFY_MISSING" 4 "absent artefact reports missing, not mismatch"

# ── Test 4: MALFORMED_SIDECAR (empty) ────────────────────────────────────────
# Failure mode guarded: an empty or truncated sidecar must not silently pass
# or be treated as "missing artefact"; it is a broken sidecar.
step "Test 4: empty sidecar -> MALFORMED_SIDECAR"
: > "$MOUNT/scanner-rootfs.ext4.sha256"
# restore the artefact so we are isolating the sidecar problem
cp "$ART" "$MOUNT/scanner-rootfs.ext4"
assert_result "$VERIFY_MALFORMED" 5 "empty sidecar is malformed"

# ── Test 5: MALFORMED_SIDECAR (absolute path) — BUG 2 REGRESSION ─────────────
# Failure mode guarded: THE historical bug. A sidecar with an absolute path
# must be rejected, never resolved. Under the old code this path was followed
# back to the source and verification passed against the wrong file. Here it
# must be MALFORMED before any hashing.
step "Test 5: absolute-path sidecar -> MALFORMED_SIDECAR (bug 2 regression)"
GOOD_HASH="$(awk '{print $1}' "${ART}.sha256")"
printf '%s  /var/lib/troskel/scanner-rootfs.ext4\n' "$GOOD_HASH" \
    > "$MOUNT/scanner-rootfs.ext4.sha256"
assert_result "$VERIFY_MALFORMED" 5 "absolute-path sidecar is rejected, not followed"

# ── Test 6: MALFORMED_SIDECAR (subdirectory path) ────────────────────────────
# Failure mode guarded: any directory component in the filename field, even a
# relative one, breaks the "resolve under the caller's mount" guarantee.
step "Test 6: sidecar with a slash in the filename -> MALFORMED_SIDECAR"
printf '%s  subdir/scanner-rootfs.ext4\n' "$GOOD_HASH" \
    > "$MOUNT/scanner-rootfs.ext4.sha256"
assert_result "$VERIFY_MALFORMED" 5 "filename with a directory component is rejected"

# ── Test 7: MALFORMED_SIDECAR (parent traversal) ─────────────────────────────
# Failure mode guarded: '..' as the filename has no slash but is still a
# traversal out of the mount; the explicit check must catch it.
step "Test 7: sidecar filename of '..' -> MALFORMED_SIDECAR"
printf '%s  ..\n' "$GOOD_HASH" > "$MOUNT/scanner-rootfs.ext4.sha256"
assert_result "$VERIFY_MALFORMED" 5 "parent-traversal filename is rejected"

# ── Test 8: MALFORMED_SIDECAR (uppercase / wrong-length hash) ────────────────
# Failure mode guarded: a sidecar whose hash field is the wrong shape (here
# uppercase, which sha256sum never emits) indicates a hand-edited or corrupt
# sidecar; reject rather than attempt a comparison that can never match.
step "Test 8: malformed hash field -> MALFORMED_SIDECAR"
printf 'NOTAHASH  scanner-rootfs.ext4\n' > "$MOUNT/scanner-rootfs.ext4.sha256"
assert_result "$VERIFY_MALFORMED" 5 "malformed hash field is rejected"

# ── Test 9: producer refuses a missing artefact ──────────────────────────────
# Failure mode guarded: emit() on a nonexistent file must fail loudly, not
# write an empty or bogus sidecar that would later read as malformed/missing.
step "Test 9: producer on a missing artefact fails"
set +e
verify_artefact_emit "$WORK/does-not-exist.bin" 2>/dev/null
EMIT_RC=$?
set -e
[ "$EMIT_RC" -ne 0 ] || fail "emit returned 0 for a missing artefact"
[ ! -f "$WORK/does-not-exist.bin.sha256" ] || fail "emit wrote a sidecar for a missing artefact"
pass "producer refuses a missing artefact and writes no sidecar"

# ── Test 10: round-trip through --check stays interoperable ───────────────────
# Failure mode guarded: the module's sidecar must remain consumable by plain
# `sha256sum --check`, so the swap can be gradual and existing USBs keep
# working. Emit, then verify with coreutils directly.
step "Test 10: emitted sidecar is interoperable with sha256sum --check"
cp "$ART" "$MOUNT/scanner-rootfs.ext4"
verify_artefact_emit "$MOUNT/scanner-rootfs.ext4"
( cd "$MOUNT" && sha256sum --check scanner-rootfs.ext4.sha256 >/dev/null 2>&1 ) \
    || fail "coreutils sha256sum --check rejected our sidecar"
pass "emitted sidecar passes plain sha256sum --check"

step "Result"
echo "[+] All ${PASS} assertions passed. Verification protocol module is correct."
echo ""
echo "[+] Tier 1 artefact verification passed."