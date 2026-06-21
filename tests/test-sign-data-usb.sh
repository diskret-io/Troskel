#!/usr/bin/env bash
# tests/test-sign-data-usb.sh
# Unit test for scripts/lib/medium-manifest.sh, the shared logic behind the
# data-USB authenticity gate (scripts/sign-data-usb.sh on the offline signing
# machine; config/host-scripts/load-scanner on the air-gapped host).
#
# The module decides whether a TROSKEL-DATA medium is AUTHENTIC: signed by the
# admin's offline key, unmodified since signing, carrying exactly the files it
# claims. For an authenticity gate the only test that matters is whether it can
# DISTINGUISH a good medium from each way a medium can be forged or corrupted.
# A check that passes a tampered medium is not weaker security, it is no
# security. Every assertion below names the failure mode it guards, and each
# negative case is constructed to pass under a naive implementation and fail
# only under a correct one.
#
# Hermetic: a directory stands in for the mounted medium (the module never
# touches devices). Needs only bash, coreutils, openssl, jq. Wire into
# tests/test-build.sh so it runs under `make test-build`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE="${PROJECT_ROOT}/scripts/lib/medium-manifest.sh"
[ -f "$MODULE" ] || { echo "[!] module not found: $MODULE"; exit 1; }
# shellcheck source=../scripts/lib/medium-manifest.sh
source "$MODULE"

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
step() { echo ""; echo "=== $* ==="; }

# Both tools are host dependencies of the authenticity gate, asserted at
# runtime by check-system-ready and pinned via the CoreOS image. This test
# exercises the same primitives, so it requires them present. A hard fail (not
# a skip) is deliberate: a silently-skipped security test is a decorative
# green, exactly what the quality bar forbids. If this fails in CI, the build
# container is missing a tool it is supposed to have.
command -v openssl >/dev/null 2>&1 || fail "openssl required (authenticity-gate dependency)"
command -v jq      >/dev/null 2>&1 || fail "jq required (authenticity-gate dependency)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Two independent keypairs: the legitimate signer, and an attacker's key used
# to forge a validly-signed-but-wrong-key manifest.
openssl genpkey -algorithm ed25519 -out "$WORK/priv.pem"  2>/dev/null
openssl pkey -in "$WORK/priv.pem"  -pubout -out "$WORK/pub.pem"  2>/dev/null
openssl genpkey -algorithm ed25519 -out "$WORK/evil.pem"  2>/dev/null
openssl pkey -in "$WORK/evil.pem"  -pubout -out "$WORK/evilpub.pem" 2>/dev/null

# make_medium <dir>: a fresh directory standing in for a prepared (unsigned)
# TROSKEL-DATA medium, with the file set prepare-data-usb.sh writes.
make_medium() {
    local d="$1"; rm -rf "$d"; mkdir -p "$d"
    printf 'pretend rootfs bytes\n'      > "$d/scanner-rootfs.ext4"
    printf 'pretend kernel bytes\n'      > "$d/vmlinux"
    printf '2026-05-09T08:00:00+00:00\n' > "$d/signature-date"
    printf '2026-05-08T14:00:00+00:00\n' > "$d/yara-rules-date"
    printf 'CLAM_SIG_MAX_AGE_DAYS=30\n'  > "$d/scanner.env"
    jq -n '{generated_at:"2026-05-09T08:00:00+00:00",
            build_environment:{troskel_commit:"abc1234", troskel_dirty:false}}' \
        > "$d/build-manifest.json"
}

# sign_medium <dir> <privkey>: build + sign in place, as sign-data-usb.sh does.
sign_medium() {
    local d="$1" key="$2"
    medium_manifest_build "$d" "abc1234" "false" "2026-05-09T08:00:00+00:00" \
        > "$d/${MEDIUM_MANIFEST_NAME}"
    medium_manifest_sign "$d" "$key"
}

# assert_rc <expected-rc> <description> ; runs the staged command, compares rc.
# Set $LAST_CMD to a function call string is awkward in bash; instead each test
# calls the module directly and we compare rc inline.

MED="$WORK/medium"

# ── Test 0: producer builds a manifest enumerating exactly the medium ────────
# Failure mode guarded: the walk omits a file (it would then never be hash- or
# set-checked on the host) or invents one. The expected core set must appear.
step "Test 0: build enumerates exactly the prepared file set"
make_medium "$MED"
sign_medium "$MED" "$WORK/priv.pem"
GOT_SET="$(jq -r '.files[].name' "$MED/${MEDIUM_MANIFEST_NAME}" | LC_ALL=C sort | tr '\n' ' ')"
WANT_SET="build-manifest.json scanner-rootfs.ext4 scanner.env signature-date vmlinux yara-rules-date "
[ "$GOT_SET" = "$WANT_SET" ] || fail "manifest set was '$GOT_SET', expected '$WANT_SET'"
# The signature artefacts must NOT be self-referential.
echo "$GOT_SET" | grep -q "$MEDIUM_MANIFEST_NAME" && fail "manifest enumerates itself"
pass "manifest enumerates exactly the covered file set, excluding sig artefacts"

# ── Test 1: good medium verifies (sig, set, hashes all OK) ───────────────────
# Necessary but not sufficient: the happy path must pass. The negatives below
# are the real test.
step "Test 1: authentic medium -> OK on all three checks"
set +e
medium_manifest_verify_sig "$MED" "$WORK/pub.pem"  >/dev/null; R1=$?
medium_manifest_verify_set "$MED"                  >/dev/null; R2=$?
medium_manifest_verify_hashes "$MED"               >/dev/null; R3=$?
set -e
[ "$R1" -eq 0 ] || fail "good sig did not verify (rc=$R1)"
[ "$R2" -eq 0 ] || fail "good set did not verify (rc=$R2)"
[ "$R3" -eq 0 ] || fail "good hashes did not verify (rc=$R3)"
pass "authentic medium passes signature, set, and hash checks"

# ── Test 2: tampered manifest -> BAD_SIGNATURE ───────────────────────────────
# Failure mode guarded: an attacker edits the signed manifest (e.g. swaps in a
# malicious file's hash). The signature must no longer verify. THE core check.
step "Test 2: manifest altered after signing -> BAD_SIGNATURE"
make_medium "$MED"; sign_medium "$MED" "$WORK/priv.pem"
jq '.troskel_commit="deadbee"' "$MED/${MEDIUM_MANIFEST_NAME}" > "$MED/tmp" && mv "$MED/tmp" "$MED/${MEDIUM_MANIFEST_NAME}"
set +e; TOK="$(medium_manifest_verify_sig "$MED" "$WORK/pub.pem")"; RC=$?; set -e
[ "$RC" -eq 3 ] && [ "$TOK" = "$MM_BAD_SIG" ] || fail "altered manifest: rc=$RC tok=$TOK, expected 3/$MM_BAD_SIG"
pass "altered manifest fails signature verification"

# ── Test 3: wrong-key signature -> BAD_SIGNATURE ─────────────────────────────
# Failure mode guarded: THE substitution attack. An attacker presents a medium
# whose manifest is perfectly valid and correctly signed -- by THEIR key. It
# must fail against the host's embedded (legitimate) public key. A check that
# passes this is the whole vulnerability the card exists to close.
step "Test 3: manifest signed by attacker key -> BAD_SIGNATURE against host key"
make_medium "$MED"; sign_medium "$MED" "$WORK/evil.pem"
# Sanity: it DOES verify against the attacker's own pubkey (the forgery is
# internally consistent), proving the next assertion is meaningful.
medium_manifest_verify_sig "$MED" "$WORK/evilpub.pem" >/dev/null || fail "forgery not self-consistent; test is meaningless"
set +e; TOK="$(medium_manifest_verify_sig "$MED" "$WORK/pub.pem")"; RC=$?; set -e
[ "$RC" -eq 3 ] && [ "$TOK" = "$MM_BAD_SIG" ] || fail "wrong-key sig: rc=$RC tok=$TOK, expected 3/$MM_BAD_SIG"
pass "validly-signed-but-wrong-key manifest is rejected against the host key"

# ── Test 4: missing signature -> MISSING_SIGNATURE (distinct from bad) ───────
# Failure mode guarded: an unsigned or legacy medium must be distinguishable
# from a tampered one, so the host can message "unsigned medium" rather than
# "tampering detected". Distinct token, distinct rc.
step "Test 4: signature absent -> MISSING_SIGNATURE"
make_medium "$MED"; sign_medium "$MED" "$WORK/priv.pem"; rm -f "$MED/${MEDIUM_SIG_NAME}"
set +e; TOK="$(medium_manifest_verify_sig "$MED" "$WORK/pub.pem")"; RC=$?; set -e
[ "$RC" -eq 4 ] && [ "$TOK" = "$MM_MISSING_SIG" ] || fail "missing sig: rc=$RC tok=$TOK, expected 4/$MM_MISSING_SIG"
pass "absent signature reports MISSING_SIGNATURE, not BAD_SIGNATURE"

# ── Test 5: malformed manifest -> MALFORMED_MANIFEST (not hashed as valid) ───
# Failure mode guarded: a truncated/empty/wrong-shape manifest must be rejected
# as malformed before any verification treats it as authoritative.
step "Test 5: empty manifest -> MALFORMED_MANIFEST"
make_medium "$MED"; sign_medium "$MED" "$WORK/priv.pem"; : > "$MED/${MEDIUM_MANIFEST_NAME}"
set +e; TOK="$(medium_manifest_verify_sig "$MED" "$WORK/pub.pem")"; RC=$?; set -e
[ "$RC" -eq 5 ] && [ "$TOK" = "$MM_MALFORMED" ] || fail "empty manifest: rc=$RC tok=$TOK, expected 5/$MM_MALFORMED"
pass "empty manifest is MALFORMED, not silently passed or treated as missing"

# ── Test 6: injected file -> SET_MISMATCH ────────────────────────────────────
# Failure mode guarded: a correctly-signed medium with an EXTRA file added
# after signing (the manifest cannot name it, the signature is still valid).
# Signature passes; the set check must catch the injection.
step "Test 6: file injected after signing -> SET_MISMATCH"
make_medium "$MED"; sign_medium "$MED" "$WORK/priv.pem"
printf 'attacker payload\n' > "$MED/evil.sh"
medium_manifest_verify_sig "$MED" "$WORK/pub.pem" >/dev/null || fail "sig should still pass; only the set changed"
set +e; TOK="$(medium_manifest_verify_set "$MED")"; RC=$?; set -e
[ "$RC" -eq 6 ] && [ "$TOK" = "$MM_SET_MISMATCH" ] || fail "injected file: rc=$RC tok=$TOK, expected 6/$MM_SET_MISMATCH"
pass "file injected after signing is caught by set-equality (signature alone would miss it)"

# ── Test 7: removed file -> SET_MISMATCH ─────────────────────────────────────
# Failure mode guarded: a file named in the signed manifest is removed from the
# medium. Signature still valid (manifest unchanged); set check must catch it.
step "Test 7: manifest-named file removed from medium -> SET_MISMATCH"
make_medium "$MED"; sign_medium "$MED" "$WORK/priv.pem"; rm -f "$MED/vmlinux"
medium_manifest_verify_sig "$MED" "$WORK/pub.pem" >/dev/null || fail "sig should still pass; only the medium changed"
set +e; TOK="$(medium_manifest_verify_set "$MED")"; RC=$?; set -e
[ "$RC" -eq 6 ] && [ "$TOK" = "$MM_SET_MISMATCH" ] || fail "removed file: rc=$RC tok=$TOK, expected 6/$MM_SET_MISMATCH"
pass "file removed from medium is caught by set-equality"

# ── Test 8: content swapped, hash stale -> HASH_MISMATCH ─────────────────────
# Failure mode guarded: a named file's BYTES are replaced after signing without
# touching the manifest or the set. Signature valid, set equal; only the
# per-file hash check catches it. Proves the integrity layer rides correctly on
# the trusted hashes.
step "Test 8: file content replaced after signing -> HASH_MISMATCH"
make_medium "$MED"; sign_medium "$MED" "$WORK/priv.pem"
printf 'malicious rootfs\n' > "$MED/scanner-rootfs.ext4"   # same name, new bytes
medium_manifest_verify_sig "$MED" "$WORK/pub.pem" >/dev/null || fail "sig should still pass; manifest unchanged"
medium_manifest_verify_set "$MED" >/dev/null || fail "set should still be equal; same filenames"
set +e; TOK="$(medium_manifest_verify_hashes "$MED")"; RC=$?; set -e
[ "$RC" -eq 7 ] || fail "swapped content: rc=$RC, expected 7 (HASH_MISMATCH)"
echo "$TOK" | grep -q "scanner-rootfs.ext4" || fail "hash mismatch did not name the offending file: $TOK"
pass "content swap under a stale hash is caught by the hash layer and names the file"

# ── Test 9: build refuses an empty medium ────────────────────────────────────
# Failure mode guarded: a manifest over zero files must never be produced; it
# would sign a vacuous claim that any empty medium satisfies.
step "Test 9: build over an empty directory fails"
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
set +e; medium_manifest_build "$EMPTY" "x" "false" "y" >/dev/null 2>&1; RC=$?; set -e
[ "$RC" -ne 0 ] || fail "build returned 0 over an empty medium"
pass "build refuses a medium with no covered files"

# ── Test 10: ordering is load-bearing (sig must gate set/hash trust) ─────────
# Failure mode guarded: documents and asserts the required order. The set and
# hash checks TRUST the manifest's contents, so they are only meaningful after
# the signature has verified. Here we prove a wrong-key (forged) manifest is
# rejected at the signature stage, i.e. before any code would trust its file
# list. This is the encoded contract: signature, THEN set, THEN hashes.
step "Test 10: forged manifest is rejected at the signature gate, before its list is trusted"
make_medium "$MED"; sign_medium "$MED" "$WORK/evil.pem"
# A forged manifest could name anything; the point is the host stops at the sig.
set +e; medium_manifest_verify_sig "$MED" "$WORK/pub.pem" >/dev/null; RC=$?; set -e
[ "$RC" -ne 0 ] || fail "forged manifest passed the signature gate"
pass "signature gate rejects a forged manifest before its file list is trusted"

# ── Test 11: keypair match check accepts the matching public key ─────────────
# Failure mode guarded: the signer's optional cross-check must ACCEPT the host
# public key that corresponds to the signing private key, or it would refuse
# legitimate signing. Note the subtle trap this proves absent: a public-key file
# carries a trailing newline that command-capture strips, so a naive byte
# compare would FALSELY mismatch a correct keypair. The fingerprint comparison
# must be immune to that.
step "Test 11: signing key matches its own public key -> accepted"
set +e; medium_manifest_keypair_matches "$WORK/priv.pem" "$WORK/pub.pem"; RC=$?; set -e
[ "$RC" -eq 0 ] || fail "matching keypair reported as mismatch (rc=$RC) -- false refusal"
pass "matching private/public keypair is accepted by the cross-check"

# ── Test 12: keypair match check rejects a non-matching public key ───────────
# Failure mode guarded: THE silent self-mismatch. Signing with priv.pem while
# the host trusts evilpub.pem (a different keypair) must be caught at the desk.
step "Test 12: signing key vs a different public key -> rejected"
set +e; medium_manifest_keypair_matches "$WORK/priv.pem" "$WORK/evilpub.pem"; RC=$?; set -e
[ "$RC" -ne 0 ] || fail "mismatched keypair reported as match -- self-mismatch would reach the host"
pass "mismatched private/public keypair is rejected by the cross-check"

# ── Test 13: fingerprint is immune to public-key formatting noise ────────────
# Failure mode guarded: a reformatted-but-identical public key (extra blank
# lines, missing trailing newline) must still match. Proves the canonicalisation
# is real and not an accident of identical formatting.
step "Test 13: keypair match survives public-key reformatting"
{ cat "$WORK/pub.pem"; echo; echo; } > "$WORK/pub.messy"
set +e; medium_manifest_keypair_matches "$WORK/priv.pem" "$WORK/pub.messy"; RC=$?; set -e
[ "$RC" -eq 0 ] || fail "reformatted-but-identical public key falsely mismatched (rc=$RC)"
pass "keypair match canonicalises away public-key formatting differences"

# ── Test 14: unreadable public key is treated as mismatch, not pass ──────────
# Failure mode guarded: a garbage/unreadable host public key must NOT compare
# equal (which would let signing proceed on a key the host cannot be using).
step "Test 14: unreadable host public key -> mismatch (fails closed)"
printf 'not a key\n' > "$WORK/garbage.pub"
set +e; medium_manifest_keypair_matches "$WORK/priv.pem" "$WORK/garbage.pub"; RC=$?; set -e
[ "$RC" -ne 0 ] || fail "unreadable public key compared equal -- must fail closed"
pass "unreadable host public key is treated as mismatch (fails closed)"

step "Result"
echo "[+] All ${PASS} assertions passed. Medium-manifest authenticity module is correct."
echo ""
echo "[+] Tier 1 medium-manifest verification passed."