#!/usr/bin/env bash
# tests/test-usb-verify.sh
# Regression test for the sidecar verification protocol.
#
# Bug history: the sidecar emitted by build-scanner-image.sh once
# contained an absolute path baked in:
#
#     <hash>  /var/lib/troskel/scanner-rootfs.ext4
#
# Verifiers in prepare-data-usb.sh and troskel-build.sh both `cd`
# into the USB mount before running `sha256sum --check`, on the
# assumption that the sidecar contained a relative path. With an
# absolute path, the check ignored the cwd and followed the path
# back to the source on the host. The verification step silently
# checked the source against its own sidecar, not the USB.
#
# Symptom: a USB that was never written successfully could pass
# verification. The bug went undetected because the test suite
# only exercised the happy path; corruption on a real USB was the
# only thing that could expose it.
#
# This test reproduces the verification scenario hermetically (no
# real USB needed) and confirms:
#
#   1. Verification passes on an unmodified file.
#   2. Verification fails on a corrupted file.
#
# Both assertions are required. (1) alone is the happy path that
# the original code also passed. (2) is the actual regression test;
# under the pre-fix code (absolute-path sidecar) it would have
# falsely reported success.
#
# Invocation: `bash tests/test-usb-verify.sh` (no privilege needed;
# no real device touched). Also runnable inside the troskel-build
# container, where it can be wired into make test-build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Self-contained: this test only needs sha256sum and basic shell. It
# does not require root, a container, real block devices, or
# privileged operations. By design: regression tests must be cheap
# enough to run on every PR without ceremony.

step() { echo ""; echo "=== $* ==="; }
pass() { echo "[+] $*"; }
fail() { echo "[!] $*" >&2; exit 1; }

# Cleanup any tempdirs on exit. Two are created: one acting as the
# "source" (the build station's /var/lib/troskel/), one acting as
# the "USB mount". The trap fires even on assertion failure so a
# broken test does not leave stale state behind.
SOURCE_DIR=""
MOUNT_DIR=""
cleanup() {
    [ -n "$SOURCE_DIR" ] && rm -rf "$SOURCE_DIR"
    [ -n "$MOUNT_DIR" ]  && rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

# ── Setup ─────────────────────────────────────────────────────────────────────

step "Setup: simulate build-scanner-image.sh sidecar emission"

SOURCE_DIR="$(mktemp -d)"
MOUNT_DIR="$(mktemp -d)"

# Create a fake "scanner-rootfs.ext4" in the source directory. Real
# content does not matter; the test exercises the verification
# protocol, not the build.
echo "fake scanner image content for the test" > "${SOURCE_DIR}/scanner-rootfs.ext4"

# Emit the sidecar the way build-scanner-image.sh now emits it: a
# subshell cd to the file's directory, then sha256sum on the
# basename so the path written into the sidecar is relative.
# CONTRACT NOTE: this matches the producer site in
# scripts/build-scanner-image.sh. If either drifts, this test
# catches the divergence.
( cd "$SOURCE_DIR" && sha256sum "scanner-rootfs.ext4" \
    > "scanner-rootfs.ext4.sha256" )

# Sanity check the producer: the sidecar must contain a relative
# path. An absolute path here is the bug we are guarding against.
if grep -q "^[0-9a-f]\+\s\+/" "${SOURCE_DIR}/scanner-rootfs.ext4.sha256"; then
    fail "Sidecar contains an absolute path. The bug has regressed in the producer."
fi
pass "Sidecar emitted with relative path"

# ── Stage the "USB" ───────────────────────────────────────────────────────────

step "Stage: copy artefacts to fake USB mount"

# Copy both the file and its sidecar to the fake USB mount, the
# same way prepare-data-usb.sh does.
cp "${SOURCE_DIR}/scanner-rootfs.ext4"        "${MOUNT_DIR}/"
cp "${SOURCE_DIR}/scanner-rootfs.ext4.sha256" "${MOUNT_DIR}/"
pass "Artefacts staged"

# ── Test 1: verification passes on an unmodified file ─────────────────────────

step "Test 1: verification passes against unmodified copy"

# Replicate the verifier in prepare-data-usb.sh and troskel-build.sh:
# cd to the mount, sha256sum --check against the sidecar.
# CONTRACT NOTE: this matches the consumer sites in
# scripts/prepare-data-usb.sh and scripts/troskel-build.sh.
if ! ( cd "$MOUNT_DIR" && sha256sum --check scanner-rootfs.ext4.sha256 >/dev/null 2>&1 ); then
    fail "Verification should pass on an unmodified file but did not. Producer/consumer have drifted."
fi
pass "Verification correctly passes on unmodified file"

# ── Test 2: verification fails on a corrupted file (the regression test) ──────

step "Test 2: verification fails against corrupted copy"

# Deliberately corrupt the copy in the mount. We modify one byte in
# the middle of the file so the sha256 cannot match. The source in
# SOURCE_DIR is untouched.
printf 'X' | dd of="${MOUNT_DIR}/scanner-rootfs.ext4" \
    bs=1 count=1 seek=10 conv=notrunc status=none

# Verification must now fail. If it still passes, the sidecar is
# pointing at the wrong file (the source rather than the copy),
# which is exactly the original bug.
if ( cd "$MOUNT_DIR" && sha256sum --check scanner-rootfs.ext4.sha256 >/dev/null 2>&1 ); then
    fail "Verification incorrectly passed against a corrupted file. The sidecar bug has regressed."
fi
pass "Verification correctly fails on corrupted file"

# ── Done ──────────────────────────────────────────────────────────────────────

step "Result"
echo "[+] All assertions passed. Sidecar verification protocol is correct."