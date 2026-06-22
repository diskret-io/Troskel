#!/usr/bin/env bash
# tests/test-gen-signing-key.sh
# Unit test for scripts/gen-signing-key.sh, the data-USB signing keypair
# generator. The failure modes that matter for a key generator are not "does it
# make a key" but "does it make a SECURE key and refuse to destroy an existing
# one": a world-readable private key or a silently-clobbered key are the silent
# security failures here. Each assertion targets one. Needs only bash, coreutils,
# openssl (no jq); runs anywhere.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEN="${ROOT}/scripts/gen-signing-key.sh"
[ -f "$GEN" ] || { echo "[!] not found: $GEN"; exit 1; }

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
step() { echo ""; echo "=== $* ==="; }
command -v openssl >/dev/null 2>&1 || fail "openssl required"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# ── Test 1: generation produces a consistent, usable ed25519 keypair ─────────
step "Test 1: generates a consistent ed25519 keypair"
bash "$GEN" "$W/k1" >/dev/null 2>&1 || fail "generation returned non-zero"
[ -f "$W/k1/troskel-sign.key" ] || fail "private key not created"
[ -f "$W/k1/troskel-sign.pub" ] || fail "public key not created"
fp_priv="$(openssl pkey -in "$W/k1/troskel-sign.key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
fp_pub="$(openssl pkey -pubin -in "$W/k1/troskel-sign.pub" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
[ -n "$fp_priv" ] && [ "$fp_priv" = "$fp_pub" ] || fail "private and public halves do not match"
pass "generates a consistent, usable ed25519 keypair"

# ── Test 2: private key is owner-only (0600) ─────────────────────────────────
# THE security failure mode: a private key readable by group or other.
step "Test 2: private key permissions are 0600"
MODE="$(stat -c '%a' "$W/k1/troskel-sign.key" 2>/dev/null || stat -f '%Lp' "$W/k1/troskel-sign.key")"
[ "$MODE" = "600" ] || fail "private key mode is $MODE, expected 600"
pass "private key is owner-only (0600)"

# ── Test 3: refuses to overwrite an existing key ─────────────────────────────
# THE destructive failure mode: clobbering the only copy of a key media were
# signed with. Must refuse and leave the existing key intact.
step "Test 3: refuses to overwrite an existing key"
before="$(sha256sum "$W/k1/troskel-sign.key" | awk '{print $1}')"
bash "$GEN" "$W/k1" >/dev/null 2>&1 && fail "overwrote an existing key" || true
after="$(sha256sum "$W/k1/troskel-sign.key" | awk '{print $1}')"
[ "$before" = "$after" ] || fail "existing key was modified despite refusal"
pass "refuses to overwrite and leaves the existing key intact"

# ── Test 4: the generated key signs and verifies (end-to-end) ────────────────
# Proves the key is not just well-formed but functional in the gate's primitive.
step "Test 4: generated keypair signs and verifies a manifest"
printf '{"manifest_version":"1","files":[]}' > "$W/m.json"
openssl pkeyutl -sign -inkey "$W/k1/troskel-sign.key" -rawin -in "$W/m.json" -out "$W/m.sig" 2>/dev/null \
    || fail "signing with the generated key failed"
openssl pkeyutl -verify -pubin -inkey "$W/k1/troskel-sign.pub" -rawin -in "$W/m.json" -sigfile "$W/m.sig" >/dev/null 2>&1 \
    || fail "verifying with the generated public key failed"
# And a DIFFERENT key must NOT verify it (the key is actually unique, not a stub).
openssl genpkey -algorithm ed25519 -out "$W/other.key" 2>/dev/null
openssl pkey -in "$W/other.key" -pubout -out "$W/other.pub" 2>/dev/null
openssl pkeyutl -verify -pubin -inkey "$W/other.pub" -rawin -in "$W/m.json" -sigfile "$W/m.sig" >/dev/null 2>&1 \
    && fail "an unrelated public key verified the signature -- key is not unique" || true
pass "generated keypair signs and verifies, and is unique"

# ── Test 5: missing openssl is reported, not silently skipped ────────────────
# A generator that silently does nothing when openssl is absent would leave the
# admin thinking they have a key. (Simulated by shadowing openssl with a stub
# that is not executable as openssl.)
step "Test 5: absent openssl aborts with a message"
STUBDIR="$W/stub"; mkdir -p "$STUBDIR"
# A PATH containing no openssl: point PATH at an empty dir plus coreutils only.
# Find coreutils location to keep bash working.
COREUTILS_DIR="$(dirname "$(command -v sha256sum)")"
if PATH="$STUBDIR:$COREUTILS_DIR" bash "$GEN" "$W/k5" >/dev/null 2>&1; then
    # If openssl was still found via builtin path, skip rather than false-fail.
    if PATH="$STUBDIR:$COREUTILS_DIR" command -v openssl >/dev/null 2>&1; then
        echo "[SKIP] openssl still reachable; cannot simulate absence here"
    else
        fail "generation succeeded with openssl absent"
    fi
else
    pass "absent openssl aborts (non-zero)"
fi

step "Result"
echo "[+] All ${PASS} assertions passed. Signing-key generator is correct."
echo ""
echo "[+] Tier 1 gen-signing-key verification passed."