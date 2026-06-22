#!/usr/bin/env bash
# tests/test-load-scanner-authenticity.sh
# The data-USB authenticity gate, exercised end to end through the REAL
# load-scanner. This is the committed proof that the gate enforces the load-time
# state table in docs/medium-authenticity-contract.md. For a security gate the
# only assertions that matter are whether it DISTINGUISHES an authentic medium
# from each way one can be forged or corrupted; the substitution attack (a medium
# signed by an attacker's key) is the headline case the whole feature exists to
# refuse. Every cell of the host x medium matrix is checked.
#
# load-scanner is a build-time template (it carries an @@REGION:...@@ marker that
# the build splices in). This test splices it exactly as scripts/prepare-boot-usb.sh
# does, then runs the spliced script, which is the one that ships. Hermetic: a
# directory stands in for the mounted medium, BAKED_KEY_PATH points at a fixture
# key (present = SIGNING host, absent = PERMISSIVE host). Needs bash, coreutils,
# openssl, jq.
#
# Invocation: bash tests/test-load-scanner-authenticity.sh (no privilege/device).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB="${PROJECT_ROOT}/scripts/lib/medium-manifest.sh"
LS_SRC="${PROJECT_ROOT}/config/host-scripts/load-scanner"
[ -f "$LIB" ]    || { echo "[!] not found: $LIB"; exit 1; }
[ -f "$LS_SRC" ] || { echo "[!] not found: $LS_SRC"; exit 1; }

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
step() { echo ""; echo "=== $* ==="; }
command -v openssl >/dev/null 2>&1 || fail "openssl required (gate dependency)"
command -v jq      >/dev/null 2>&1 || fail "jq required (gate dependency)"

# Splice load-scanner exactly as the build does, then run the spliced copy.
# shellcheck source=../scripts/lib/splice-region.sh
source "${PROJECT_ROOT}/scripts/lib/splice-region.sh"
# shellcheck source=../scripts/lib/medium-manifest.sh
source "$LIB"   # producer functions, to build signed test media

W="$(mktemp -d)"
LS="$W/load-scanner"
splice_region "$LIB" medium-manifest-verify "$LS_SRC" > "$LS" \
    || { echo "[!] splice failed"; exit 1; }
trap 'rm -rf "$W"' EXIT

# Keys: the host's trusted keypair, and an attacker's keypair.
openssl genpkey -algorithm ed25519 -out "$W/host.key"  2>/dev/null
openssl pkey -in "$W/host.key"  -pubout -out "$W/host.pub"  2>/dev/null
openssl genpkey -algorithm ed25519 -out "$W/evil.key"  2>/dev/null
openssl pkey -in "$W/evil.key"  -pubout -out "$W/evil.pub"  2>/dev/null

# make_medium <dir> <signing-key|""> : a fixture medium. If a signing key is
# given, builds and signs the medium manifest with it. The rootfs sidecar is
# included so the post-gate rootfs check also passes on the load path.
make_medium() {
    local dir="$1" signkey="${2:-}"
    rm -rf "$dir"; mkdir -p "$dir"
    printf 'pretend scanner rootfs bytes\n' > "$dir/scanner-rootfs.ext4"
    printf 'pretend kernel\n'              > "$dir/vmlinux"
    printf '2026-06-19\n'                  > "$dir/signature-date"
    printf '2026-06-19\n'                  > "$dir/yara-rules-date"
    printf 'SCANNER_TIMEOUT=300\n'         > "$dir/scanner.env"
    local h; h="$( ( cd "$dir" && sha256sum scanner-rootfs.ext4 ) | awk '{print $1}' )"
    printf '%s  scanner-rootfs.ext4\n' "$h" > "$dir/scanner-rootfs.ext4.sha256"
    if [ -n "$signkey" ]; then
        medium_manifest_build "$dir" "testcommit" "false" "2026-06-19T00:00:00+00:00" \
            > "$dir/medium-manifest.json"
        medium_manifest_sign "$dir" "$signkey"
    fi
}

# run_gate <medium-dir> <baked-key-path-or-empty> : runs the spliced load-scanner.
# Sets RUN_RC and RUN_OUT. baked-key empty -> PERMISSIVE host (key file absent).
run_gate() {
    local usb="$1" baked="$2"
    local dest issue
    dest="$(mktemp -d "$W/dest.XXXXXX")"
    issue="$(mktemp "$W/issue.XXXXXX")"
    local bk="${baked:-$W/absent-key.pub}"   # nonexistent path when permissive
    set +e
    RUN_OUT="$(MOUNT="$usb" DEST="$dest" ETC_ISSUE="$issue" BAKED_KEY_PATH="$bk" bash "$LS" 2>&1)"
    RUN_RC=$?
    set -e
}

# ─────────────────────────── SIGNING host cells ─────────────────────────────
# (BAKED_KEY_PATH = host.pub present)

step "SIGNING + matching signature -> LOADS (rc 0)"
make_medium "$W/m" "$W/host.key"
run_gate "$W/m" "$W/host.pub"
[ "$RUN_RC" -eq 0 ] || fail "authentic medium did not load (rc=$RUN_RC): $RUN_OUT"
echo "$RUN_OUT" | grep -q "Authenticity verified" || fail "no authenticity-verified message: $RUN_OUT"
pass "signing host loads a medium signed by its trusted key"

step "SIGNING + WRONG-KEY signature -> REFUSED (the substitution attack)"
make_medium "$W/m" "$W/evil.key"     # signed by attacker
run_gate "$W/m" "$W/host.pub"        # host trusts host.pub
[ "$RUN_RC" -ne 0 ] || fail "WRONG-KEY medium LOADED -- substitution attack not refused: $RUN_OUT"
echo "$RUN_OUT" | grep -q "does not match this host's trusted" || fail "wrong-key refusal message missing: $RUN_OUT"
# And the refused medium must not have been copied to the destination. dest is a
# fresh temp dir per run_gate; assert the rootfs did not land there.
LAST_DEST="$(ls -dt "$W"/dest.* 2>/dev/null | head -1)"
[ -n "$LAST_DEST" ] && [ ! -e "$LAST_DEST/scanner-rootfs.ext4" ] \
    || fail "wrong-key medium was copied to destination despite refusal"
pass "signing host REFUSES a medium signed by a different key (substitution attack), nothing copied"

step "SIGNING + UNSIGNED medium -> REFUSED"
make_medium "$W/m" ""                # no manifest/sig
run_gate "$W/m" "$W/host.pub"
[ "$RUN_RC" -ne 0 ] || fail "unsigned medium loaded on a signing host: $RUN_OUT"
echo "$RUN_OUT" | grep -q "medium is unsigned" || fail "unsigned-refusal message missing: $RUN_OUT"
pass "signing host refuses an unsigned medium"

step "SIGNING + injected file after signing -> REFUSED (set mismatch)"
make_medium "$W/m" "$W/host.key"
printf 'payload\n' > "$W/m/injected"     # add a file the signed manifest cannot name
run_gate "$W/m" "$W/host.pub"
[ "$RUN_RC" -ne 0 ] || fail "injected-file medium loaded: $RUN_OUT"
echo "$RUN_OUT" | grep -q "file set does not match" || fail "set-mismatch message missing: $RUN_OUT"
pass "signing host refuses a medium with a file injected after signing"

step "SIGNING + content swapped after signing -> REFUSED (hash mismatch)"
make_medium "$W/m" "$W/host.key"
printf 'malicious rootfs\n' > "$W/m/scanner-rootfs.ext4"   # same name, new bytes, manifest stale
run_gate "$W/m" "$W/host.pub"
[ "$RUN_RC" -ne 0 ] || fail "content-swapped medium loaded: $RUN_OUT"
echo "$RUN_OUT" | grep -q "do not match the signed manifest" || fail "hash-mismatch message missing: $RUN_OUT"
pass "signing host refuses a medium with file contents altered after signing"

step "SIGNING + malformed manifest -> REFUSED"
make_medium "$W/m" "$W/host.key"
: > "$W/m/medium-manifest.json"          # empty/malformed
run_gate "$W/m" "$W/host.pub"
[ "$RUN_RC" -ne 0 ] || fail "malformed-manifest medium loaded: $RUN_OUT"
pass "signing host refuses a malformed manifest"

# ────────────────────────── PERMISSIVE host cells ───────────────────────────
# (BAKED_KEY_PATH absent)

step "PERMISSIVE announces enforcement is OFF on every load"
make_medium "$W/m" ""
run_gate "$W/m" ""
echo "$RUN_OUT" | grep -q "enforcement is OFF" || fail "permissive host did not announce: $RUN_OUT"
pass "permissive host announces that authenticity enforcement is off"

step "PERMISSIVE + signed intact medium -> LOADS, integrity only (rc 0)"
make_medium "$W/m" "$W/host.key"
run_gate "$W/m" ""
[ "$RUN_RC" -eq 0 ] || fail "permissive host rejected an intact signed medium (rc=$RUN_RC): $RUN_OUT"
echo "$RUN_OUT" | grep -q "authenticity NOT verified" || fail "permissive integrity-only message missing: $RUN_OUT"
pass "permissive host loads an intact signed medium, integrity-only"

step "PERMISSIVE + signed medium, injected file -> REFUSED (integrity fails)"
make_medium "$W/m" "$W/host.key"
printf 'payload\n' > "$W/m/injected"
run_gate "$W/m" ""
[ "$RUN_RC" -ne 0 ] || fail "permissive host loaded a medium with an injected file: $RUN_OUT"
pass "permissive host refuses a signed medium with an integrity failure"

step "PERMISSIVE + unsigned medium -> LOADS with notice (rc 0)"
make_medium "$W/m" ""
run_gate "$W/m" ""
[ "$RUN_RC" -eq 0 ] || fail "permissive host rejected an unsigned medium (rc=$RUN_RC): $RUN_OUT"
echo "$RUN_OUT" | grep -q "Medium is unsigned" || fail "unsigned-notice message missing: $RUN_OUT"
pass "permissive host loads an unsigned medium with a notice"

step "PERMISSIVE cannot detect the substitution attack (documented limitation)"
# An attacker-signed, internally-consistent medium passes integrity on a
# permissive host because there is no key to check the signature against. This
# asserts the DOCUMENTED limitation, so a future change that silently "fixed" it
# (and thereby changed permissive semantics) would surface here for review.
make_medium "$W/m" "$W/evil.key"
run_gate "$W/m" ""
[ "$RUN_RC" -eq 0 ] || fail "permissive host unexpectedly rejected an attacker-signed intact medium: $RUN_OUT"
pass "permissive host loads an attacker-signed intact medium (documented: cannot detect substitution)"

step "Result"
echo "[+] All ${PASS} assertions passed. load-scanner authenticity gate is correct."
echo ""
echo "[+] Tier 1 load-scanner authenticity verification passed."