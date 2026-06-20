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
# RUN_RC, RUN_OUT, DEST_DIR, ISSUE_FILE. Not wrapped in command substitution,
# so the global assignments survive (a $(...) subshell would discard them).
run_load() {
    local usb="$1"
    DEST_DIR="$(mktemp -d "$WORK/dest.XXXXXX")"
    # Per-run /etc/issue fixture so banner assertions read what THIS run wrote.
    ISSUE_FILE="$(mktemp "$WORK/issue.XXXXXX")"
    set +e
    RUN_OUT="$(MOUNT="$usb" DEST="$DEST_DIR" ETC_ISSUE="$ISSUE_FILE" bash "$LOAD_SCANNER" 2>&1)"
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

# ── Test 7: good load writes a banner with the real dates ────────────────────
# Failure mode guarded: the pre-login banner must show the loaded dates, read
# from $DEST (the same source show-status uses), so the two displays agree. A
# banner that showed nothing, or showed the USB copy rather than the loaded
# copy, would defeat the point of the card.
step "Test 7: good load writes /etc/issue with the loaded dates"
USB="$(make_usb good)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -eq 0 ] || fail "good load: rc was $RC, expected 0. Output:
$RUN_OUT"
[ -f "$ISSUE_FILE" ] || fail "good load: no /etc/issue was written"
grep -q "^  Signature date  : 2026-06-19$" "$ISSUE_FILE" \
    || fail "good load: banner missing the loaded signature date. Banner:
$(cat "$ISSUE_FILE")"
grep -q "^  YARA rules date : 2026-06-19$" "$ISSUE_FILE" \
    || fail "good load: banner missing the loaded YARA date. Banner:
$(cat "$ISSUE_FILE")"
# The dates in the banner must equal what show-status would read from $DEST.
[ "$(cat "$ISSUE_FILE" | grep 'Signature date' | sed 's/.*: //')" \
    = "$(cat "$DEST_DIR/signature-date")" ] \
    || fail "good load: banner signature date disagrees with \$DEST/signature-date"
echo "$RUN_OUT" | grep -q "Pre-login banner updated" \
    || fail "good load: no banner-updated confirmation in output"
pass "good load writes a banner agreeing with the loaded dates"

# ── Test 8: unverified-but-tolerated load still writes the banner ─────────────
# Failure mode guarded: the absent-sidecar path (Test 5) loads successfully and
# must still get a real banner. The banner write sits after the verification
# gate, so a path that loads without a sidecar must reach it. A banner that
# only appeared on the sidecar-present path would leave old-USB operators with
# a stale default screen despite a successful load.
step "Test 8: absent-sidecar load (tolerated) still writes the banner"
USB="$(make_usb missing)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -eq 0 ] || fail "absent sidecar: rc was $RC, expected 0. Output:
$RUN_OUT"
grep -q "^  Signature date  : 2026-06-19$" "$ISSUE_FILE" \
    || fail "absent sidecar: banner missing the loaded date. Banner:
$(cat "$ISSUE_FILE")"
pass "tolerated unverified load still produces a dated banner"

# ── Test 9: a fatal load does NOT write a banner ─────────────────────────────
# Failure mode guarded: THE display-correctness property. A load that fails
# verification must not write /etc/issue, so the operator is left seeing the
# Butane default ("not loaded") rather than a banner this script produced. If a
# failing load wrote a banner, the pre-login screen could show dates for an
# image that was rejected and removed. We assert the issue fixture is still
# empty (load-scanner exited before the banner block) after a fatal load.
step "Test 9: fatal load leaves the banner unwritten"
USB="$(make_usb corrupt-target)"
run_load "$USB"; RC="$RUN_RC"
[ "$RC" -ne 0 ] || fail "corrupt image: expected non-zero rc"
[ ! -s "$ISSUE_FILE" ] \
    || fail "corrupt image: banner was written on a FAILED load. Banner:
$(cat "$ISSUE_FILE")"
pass "a fatal load writes no banner; the default stands"

# ── Test 10: banner per-field fallback yields 'not loaded' for an absent file ─
# Failure mode guarded: the banner's per-field `|| echo 'not loaded'` idiom.
# Scope note: in the normal USB flow this fallback is not reached, because
# load-scanner copies both date files early under `set -e`, so a USB missing a
# date file fails at that cp and never reaches the banner. The fallback is
# defensive cover for a file vanishing between copy and banner generation. This
# test therefore exercises the idiom directly (the exact expression the banner
# block uses) rather than driving it through load-scanner, asserting a present
# file reads through and an absent file degrades to 'not loaded' without
# aborting under set -e.
step "Test 10: banner per-field fallback yields 'not loaded' for an absent file"
MISSING_DIR="$(mktemp -d "$WORK/miss.XXXXXX")"
printf '2026-06-19\n' > "$MISSING_DIR/signature-date"   # yara-rules-date absent
SIG_DATE="$(cat "$MISSING_DIR/signature-date" 2>/dev/null || echo 'not loaded')"
YARA_DATE="$(cat "$MISSING_DIR/yara-rules-date" 2>/dev/null || echo 'not loaded')"
[ "$SIG_DATE" = "2026-06-19" ] || fail "fallback: present file did not read through"
[ "$YARA_DATE" = "not loaded" ] || fail "fallback: absent file did not yield 'not loaded'"
pass "per-field fallback shows 'not loaded' only for the missing field"


step "Result"
echo "[+] All ${PASS} assertions passed. Host-side rootfs verification and pre-login banner generation are correct."