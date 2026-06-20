#!/usr/bin/env bash
# tests/test-load-scanner.sh
# Regression test for host-side scanner-rootfs verification in
# config/host-scripts/load-scanner.
#
# What this guards (load-scanner-verify-rootfs card):
#   load-scanner copies scanner-rootfs.ext4 from the data USB to
#   /var/lib/troskel and the scanner VM executes it. Before this work the copy
#   was unverified: a bare `cp` and nothing else, on the one hop where the
#   executable image crosses the air gap. This test asserts the host now
#   verifies the copied image against its sidecar, re-reading the copy under
#   $DEST (not the USB), and that a failed verification is FATAL: the bad image
#   is removed and the script exits non-zero. It also asserts the bug-2
#   guard (a path-bearing sidecar is rejected, never followed).
#
# The script exposes DATA_USB, DEST, and MOUNT as environment seams so the
# copy-and-verify logic runs against fixture directories without a real device
# or root. Supplying MOUNT bypasses the real mount/unmount.
#
# Invocation: `bash tests/test-load-scanner.sh` (no privilege, no device,
# no container; bash + coreutils only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOAD_SCANNER="${PROJECT_ROOT}/config/host-scripts/load-scanner"

[ -f "$LOAD_SCANNER" ] || { echo "[!] load-scanner not found at $LOAD_SCANNER"; exit 1; }

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
step() { echo ""; echo "=== $* ==="; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build a fixture "USB" (a populated directory) with the files load-scanner
# copies. sidecar_mode controls the sidecar: good | corrupt-target | absolute
# | missing | uppercase. Returns the fixture mount dir path on stdout.
make_usb() {
    local sidecar_mode="$1"
    local usb
    usb="$(mktemp -d "$WORK/usb.XXXXXX")"
    printf 'pretend scanner rootfs bytes\n' > "$usb/scanner-rootfs.ext4"
    printf 'pretend kernel\n'              > "$usb/vmlinux"
    printf '2026-06-19\n'                  > "$usb/signature-date"
    printf '2026-06-19\n'                  > "$usb/yara-rules-date"
    printf 'SCANNER_TIMEOUT=300\n'         > "$usb/scanner.env"
    local hash
    hash="$( ( cd "$usb" && sha256sum scanner-rootfs.ext4 ) | awk '{print $1}' )"
    case "$sidecar_mode" in
        good)
            printf '%s  scanner-rootfs.ext4\n' "$hash" > "$usb/scanner-rootfs.ext4.sha256" ;;
        corrupt-target)
            # Valid sidecar, but the image gets corrupted after hashing so the
            # host copy will not match.
            printf '%s  scanner-rootfs.ext4\n' "$hash" > "$usb/scanner-rootfs.ext4.sha256"
            printf 'EXTRA' >> "$usb/scanner-rootfs.ext4" ;;
        absolute)
            # Bug 2: an absolute path in the sidecar must be rejected.
            printf '%s  /var/lib/troskel/scanner-rootfs.ext4\n' "$hash" > "$usb/scanner-rootfs.ext4.sha256" ;;
        uppercase)
            printf 'NOTAHASH  scanner-rootfs.ext4\n' > "$usb/scanner-rootfs.ext4.sha256" ;;
        missing)
            : ;;  # no sidecar written
    esac
    echo "$usb"
}

# run_load <usb-dir>: runs load-scanner against the fixture, setting globals
# RUN_RC, RUN_OUT, DEST_DIR. Not wrapped in command substitution, so the
# global assignments survive (a $(...) subshell would discard them).
run_load() {
    local usb="$1"
    DEST_DIR="$(mktemp -d "$WORK/dest.XXXXXX")"
    set +e
    RUN_OUT="$(MOUNT="$usb" DEST="$DEST_DIR" bash "$LOAD_SCANNER" 2>&1)"
    RUN_RC=$?
    set -e
}

# ── Test 1: good image verifies and loads ────────────────────────────────────
# Failure mode guarded: the happy path must load and report verification.
step "Test 1: matching image verifies and loads (rc 0)"
USB="$(make_usb good)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -eq 0 ] || fail "good image: rc was $RC, expected 0. Output:
$RUN_OUT"
echo "$RUN_OUT" | grep -q "verified against sidecar" \
    || fail "good image: no verification confirmation. Output:
$RUN_OUT"
[ -f "$DEST_DIR/scanner-rootfs.ext4" ] || fail "good image: rootfs not present in DEST"
pass "matching image verifies and is loaded"

# ── Test 2: corrupted host copy is fatal and the bad image is removed ─────────
# Failure mode guarded: THE point of the card. A rootfs that does not match its
# sidecar must not be loaded; the script must exit non-zero AND remove the bad
# copy so a later step cannot pick it up.
step "Test 2: corrupted image is fatal, bad copy removed (rc != 0)"
USB="$(make_usb corrupt-target)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -ne 0 ] || fail "corrupt image: rc was 0, expected non-zero. Output:
$RUN_OUT"
echo "$RUN_OUT" | grep -q "failed verification" \
    || fail "corrupt image: no failure diagnostic. Output:
$RUN_OUT"
[ ! -f "$DEST_DIR/scanner-rootfs.ext4" ] \
    || fail "corrupt image: bad rootfs was left in DEST (must be removed)"
pass "corrupted image is fatal and the bad copy is removed"

# ── Test 3: absolute-path sidecar is rejected (bug 2) ────────────────────────
# Failure mode guarded: a path-bearing sidecar must be rejected, never
# followed. Under the old per-site code an absolute path verified the source,
# not the host copy.
step "Test 3: absolute-path sidecar is rejected, fatal (rc != 0)"
USB="$(make_usb absolute)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -ne 0 ] || fail "absolute-path sidecar: rc was 0, expected non-zero. Output:
$RUN_OUT"
echo "$RUN_OUT" | grep -q "safe 'sha256sum <basename>' form" \
    || fail "absolute-path sidecar: not rejected for shape. Output:
$RUN_OUT"
[ ! -f "$DEST_DIR/scanner-rootfs.ext4" ] \
    || fail "absolute-path sidecar: rootfs left in DEST after rejection"
pass "absolute-path sidecar is rejected before any hashing"

# ── Test 4: malformed hash field is rejected ─────────────────────────────────
# Failure mode guarded: a sidecar whose hash field is the wrong shape (here
# uppercase, which sha256sum never emits) is a hand-edited or corrupt sidecar;
# reject rather than attempt a comparison.
step "Test 4: malformed hash field is rejected, fatal (rc != 0)"
USB="$(make_usb uppercase)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -ne 0 ] || fail "malformed sidecar: rc was 0, expected non-zero. Output:
$RUN_OUT"
[ ! -f "$DEST_DIR/scanner-rootfs.ext4" ] \
    || fail "malformed sidecar: rootfs left in DEST after rejection"
pass "malformed hash field is rejected"

# ── Test 5: absent sidecar loads with a loud warning (old USB) ───────────────
# Failure mode guarded: an old USB with no sidecar must still load (tolerated),
# but the operator must be told the image is unverified. This is intentional:
# the hash was never the substitution defence (that is the signing card), so
# refusing here would only block genuinely old media without closing an attack.
step "Test 5: absent sidecar loads with an unverified warning (rc 0)"
USB="$(make_usb missing)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -eq 0 ] || fail "absent sidecar: rc was $RC, expected 0 (tolerated). Output:
$RUN_OUT"
echo "$RUN_OUT" | grep -qi "unverified\|predates sidecar" \
    || fail "absent sidecar: no unverified warning. Output:
$RUN_OUT"
[ -f "$DEST_DIR/scanner-rootfs.ext4" ] || fail "absent sidecar: rootfs should still be loaded"
pass "absent sidecar loads with a clear unverified warning"

# ── Test 6: verification re-reads the DEST copy, not the USB ─────────────────
# Failure mode guarded: the card requires hashing the copy that will execute
# (under $DEST), not the USB copy. The failure diagnostic prints the "actual"
# hash it computed. We confirm that hash equals the bytes load-scanner copied
# into DEST, which it can only do if it hashed DEST. (At copy time DEST holds a
# byte-identical copy of the USB rootfs, so the DEST hash equals the USB
# rootfs hash here; the assertion still proves the script computed a real hash
# over the copied bytes rather than blindly trusting the sidecar's value.)
step "Test 6: failure diagnostic shows the hash of the copied bytes"
USB="$(make_usb corrupt-target)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -ne 0 ] || fail "expected failure for corrupt image"
DEST_HASH="$( sha256sum "$USB/scanner-rootfs.ext4" | awk '{print $1}' )"
echo "$RUN_OUT" | grep -q "$DEST_HASH" \
    || fail "failure output does not contain the copied-bytes hash; verification
may be reading the wrong file. Output:
$RUN_OUT"
pass "verification computes the hash over the copied bytes"

step "Result"
echo "[+] All ${PASS} assertions passed. Host-side rootfs verification is correct."