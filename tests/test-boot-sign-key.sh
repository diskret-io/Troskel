#!/usr/bin/env bash
# tests/test-boot-sign-key.sh
# Unit test for scripts/lib/boot-sign-key.sh, the boot-build half of the
# data-USB authenticity gate. Proves the host-type decision, the sentinel
# substitution/removal, and the post-compile drift check, each against the
# failure mode it guards. See docs/medium-authenticity-contract.md.
#
# Hermetic: no Butane, no docker, no ISO. The drift check is exercised against
# a hand-built ignition.json carrying the exact data-URL shape Butane emits for
# a local file (data:;base64,<payload>), so the decode + fingerprint + compare
# logic is fully tested. The one thing this CANNOT test is whether a real Butane
# actually produces that shape; that is asserted by the integration test on the
# build container. Needs bash, coreutils, openssl, jq.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scripts/lib/medium-manifest.sh
source "${ROOT}/scripts/lib/medium-manifest.sh"
# shellcheck source=../scripts/lib/boot-sign-key.sh
source "${ROOT}/scripts/lib/boot-sign-key.sh"

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
step() { echo ""; echo "=== $* ==="; }
command -v openssl >/dev/null 2>&1 || fail "openssl required (gate dependency)"
command -v jq      >/dev/null 2>&1 || fail "jq required (gate dependency)"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
openssl genpkey -algorithm ed25519 -out "$W/sign.priv" 2>/dev/null
openssl pkey -in "$W/sign.priv" -pubout -out "$W/sign.pub" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$W/stale.priv" 2>/dev/null
openssl pkey -in "$W/stale.priv" -pubout -out "$W/stale.pub" 2>/dev/null

# Build an ignition.json embedding a given pubkey file at BAKED_KEY_PATH, the
# way Butane would (data:;base64,...). If key path is empty, omit the entry.
make_ignition() {
    local keyfile="$1" out="$2"
    if [ -n "$keyfile" ]; then
        local b64; b64="$(base64 -w0 "$keyfile")"
        jq -n --arg p "$BAKED_KEY_PATH" --arg s "data:;base64,${b64}" \
          '{ignition:{version:"3.4.0"},storage:{files:[{path:$p,mode:420,contents:{source:$s}}]}}' > "$out"
    else
        jq -n '{ignition:{version:"3.4.0"},storage:{files:[{path:"/etc/issue",contents:{source:"data:;base64,aGk="}}]}}' > "$out"
    fi
}

# ── Test 1: mode resolution, all four combinations ───────────────────────────
# Failure mode guarded: an ambiguous or forgotten invocation must never silently
# yield a permissive host. Neither-set and both-set must abort; the two valid
# combinations must resolve correctly.
step "Test 1: host-type decision (key / flag / neither / both)"
set +e
OUT="$(TROSKEL_SIGN_PUBKEY="$W/sign.pub" TROSKEL_ALLOW_UNSIGNED="" boot_sign_resolve_mode 2>/dev/null)"; R=$?
set -e
[ $R -eq 0 ] && [ "${OUT%% *}" = "signing" ] || fail "key-only should resolve 'signing' (got rc=$R '$OUT')"
set +e
OUT="$(TROSKEL_SIGN_PUBKEY="" TROSKEL_ALLOW_UNSIGNED=1 boot_sign_resolve_mode 2>/dev/null)"; R=$?
set -e
[ $R -eq 0 ] && [ "$OUT" = "permissive" ] || fail "flag-only should resolve 'permissive' (got rc=$R '$OUT')"
set +e
TROSKEL_SIGN_PUBKEY="" TROSKEL_ALLOW_UNSIGNED="" boot_sign_resolve_mode >/dev/null 2>&1; R=$?
set -e
[ $R -ne 0 ] || fail "neither-set must abort (got rc=0)"
set +e
TROSKEL_SIGN_PUBKEY="$W/sign.pub" TROSKEL_ALLOW_UNSIGNED=1 boot_sign_resolve_mode >/dev/null 2>&1; R=$?
set -e
[ $R -ne 0 ] || fail "both-set must abort (got rc=0)"
pass "host-type decision: key->signing, flag->permissive, neither->abort, both->abort"

# ── Test 2: a malformed key in TROSKEL_SIGN_PUBKEY aborts ─────────────────────
# Failure mode guarded: a garbage key path must not produce a 'signing' host
# that bakes nonsense.
step "Test 2: malformed signing key aborts mode resolution"
printf 'not a key\n' > "$W/garbage.pub"
set +e
TROSKEL_SIGN_PUBKEY="$W/garbage.pub" boot_sign_resolve_mode >/dev/null 2>&1; R=$?
set -e
[ $R -ne 0 ] || fail "malformed key should abort"
pass "malformed signing key is rejected at mode resolution"

# ── Test 3: SIGNING substitution inserts the key entry, consumes sentinel ─────
step "Test 3: apply_mode signing inserts the storage.files entry"
mkdir -p "$W/cfgdir"
printf 'storage:\n  files:\n    - path: /usr/local/bin/x\n%s\n    - path: /etc/issue\n' "$SIGN_PUBKEY_SENTINEL" > "$W/cfgdir/scanner-host.bu"
boot_sign_apply_mode signing "$W/sign.pub" "$W/cfgdir/scanner-host.bu" "$W/cfgdir"
grep -q "$SIGN_PUBKEY_SENTINEL" "$W/cfgdir/scanner-host.bu" && fail "sentinel not consumed"
grep -q "local: ${SIGN_KEY_FILESDIR_NAME}" "$W/cfgdir/scanner-host.bu" || fail "key entry not inserted"
grep -q "path: ${BAKED_KEY_PATH}" "$W/cfgdir/scanner-host.bu" || fail "baked path not present"
[ -f "$W/cfgdir/${SIGN_KEY_FILESDIR_NAME}" ] || fail "key not copied into files-dir"
pass "signing mode inserts key entry, copies key, consumes sentinel"

# ── Test 4: PERMISSIVE removal strips sentinel, leaves no key entry ───────────
step "Test 4: apply_mode permissive removes the sentinel, no key entry"
printf 'storage:\n  files:\n    - path: /usr/local/bin/x\n%s\n    - path: /etc/issue\n' "$SIGN_PUBKEY_SENTINEL" > "$W/cfgdir/perm.bu"
boot_sign_apply_mode permissive "" "$W/cfgdir/perm.bu" "$W/cfgdir"
grep -q "$SIGN_PUBKEY_SENTINEL" "$W/cfgdir/perm.bu" && fail "sentinel not removed"
grep -q "sign.pub" "$W/cfgdir/perm.bu" && fail "key entry present in permissive build"
pass "permissive mode removes sentinel and bakes no key"

# ── Test 5: drift check PASSES when the correct key is baked ──────────────────
step "Test 5: drift check passes for matching baked key"
make_ignition "$W/sign.pub" "$W/ign.good.json"
set +e; boot_sign_verify_drift signing "$W/sign.pub" "$W/ign.good.json" >/dev/null; R=$?; set -e
[ $R -eq 0 ] || fail "drift check failed on a correct baked key (rc=$R)"
pass "drift check passes when baked key matches source"

# ── Test 6: drift check ABORTS when a stale/wrong key is baked ────────────────
# THE core failure mode: a key other than the source somehow ended up in the
# Ignition. Must abort, or a wrong-key ISO ships.
step "Test 6: drift check aborts for a stale/wrong baked key"
make_ignition "$W/stale.pub" "$W/ign.stale.json"
set +e; boot_sign_verify_drift signing "$W/sign.pub" "$W/ign.stale.json" >/dev/null 2>&1; R=$?; set -e
[ $R -ne 0 ] || fail "drift check passed a wrong baked key -- would ship wrong-key ISO"
pass "drift check aborts when baked key differs from source (substitution caught)"

# ── Test 7: drift check ABORTS when SIGNING requested but no key baked ────────
# Sentinel failed to substitute, or Butane dropped the entry.
step "Test 7: drift check aborts when signing build baked no key"
make_ignition "" "$W/ign.none.json"
set +e; boot_sign_verify_drift signing "$W/sign.pub" "$W/ign.none.json" >/dev/null 2>&1; R=$?; set -e
[ $R -ne 0 ] || fail "drift check passed a signing build with no baked key"
pass "drift check aborts when a signing build baked no key"

# ── Test 8: permissive drift check ABORTS if a key was baked anyway ───────────
# Sentinel not removed: a permissive host that secretly trusts a key is a
# contract violation load-scanner would misread.
step "Test 8: permissive drift check aborts if a key leaked into the build"
set +e; boot_sign_verify_drift permissive "" "$W/ign.good.json" >/dev/null 2>&1; R=$?; set -e
[ $R -ne 0 ] || fail "permissive drift check passed despite a baked key"
pass "permissive drift check aborts when a key was baked"

# ── Test 9: permissive drift check PASSES when no key baked ───────────────────
step "Test 9: permissive drift check passes with no baked key"
set +e; boot_sign_verify_drift permissive "" "$W/ign.none.json" >/dev/null; R=$?; set -e
[ $R -eq 0 ] || fail "permissive drift check failed on a correctly keyless build (rc=$R)"
pass "permissive drift check passes when no key is baked"

step "Result"
echo "[+] All ${PASS} assertions passed. Boot-build authenticity logic is correct."
echo ""
echo "[+] Tier 1 boot-sign-key verification passed."