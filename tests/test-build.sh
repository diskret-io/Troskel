#!/usr/bin/env bash
# tests/test-build.sh
# Runs the build pipeline end-to-end inside the troskel-build container.
# Stops at the first failure.
#
# Invocation: `make test-build` (from the project root).
#
# Direct host invocation is not supported — the script gates on a
# container sentinel and refuses to run on the host. The historical
# host-direct path produced environment-dependent bugs (clamav user
# missing on NixOS, chown semantics under sudo, varying sigtool
# versions) that the containerised pipeline avoids by construction.
# See docs/DEVELOPER.md for the rationale.
#
# Covers:
#   - Butane config validation
#   - SHA-256 verification negative-path tests (LOKI-RS and guest kernel)
#   - ClamAV signature download
#   - YARA Forge Core rules refresh
#   - Guest kernel download
#   - Scanner image build (debootstrap, ClamAV install, LOKI-RS install,
#     signature/rule injection, ext4 image)
#   - Sidecar verification regression test (hermetic)
#
# Container-internal requirements (the Dockerfile and Makefile satisfy these):
#   - root (the underlying scripts need it for debootstrap, mkfs.ext4,
#     writes to /var/lib/troskel)
#   - internet (for signature/rule/kernel downloads)
#
# Does not cover the scan pipeline — see test-scan.sh and manual-tests-scan.md.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

# ── Container sentinel gate ───────────────────────────────────────────────────
# Refuses to run outside the troskel-build container. The sentinel is a
# zero-byte file the Dockerfile creates at /.troskel-container; its
# absence indicates host-direct invocation. The error message names the
# supported entry point and also shows the docker-run fallback for the
# fast-iteration loop, so a developer who hits this gate has a clear
# next action without consulting docs.
if [ ! -f /.troskel-container ]; then
    echo "[!] tests/test-build.sh must run inside the troskel-build container."
    echo ""
    echo "    Supported invocation:"
    echo "      make test-build"
    echo ""
    echo "    Fast-iteration fallback (run a single script in the container):"
    echo "      docker run --rm --privileged \\"
    echo "          --volume \"\$PWD:/troskel\" --workdir /troskel \\"
    echo "          troskel-build bash tests/test-build.sh"
    echo ""
    echo "    See docs/DEVELOPER.md for the rationale."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIGDIR="/var/lib/troskel"
VERSIONS_FILE="${PROJECT_ROOT}/config/versions.env"

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *)       echo "[!] Unknown argument: $arg"; exit 1 ;;
    esac
done

step() { echo ""; echo "=== $* ==="; }

cd "$PROJECT_ROOT"

# Check for required tools individually so the operator knows exactly
# what is missing rather than getting a single opaque failure.
# These should all be present inside the troskel-build container; a
# failure here indicates the image is out of date relative to what
# the test suite expects.
PREFLIGHT_FAIL=0
for tool in debootstrap butane firecracker; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "[!] '$tool' not found on PATH."; PREFLIGHT_FAIL=1; }
done
[ -x /opt/loki-rs/loki ] \
    || { echo "[!] loki-rs not found at /opt/loki-rs/loki."; PREFLIGHT_FAIL=1; }
if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
    echo ""
    echo "    The container image appears to be out of date. Rebuild it:"
    echo "      make clean && make image"
    exit 1
fi

if [ "$CLEAN" -eq 1 ]; then
    step "0/6  Clearing prior artefacts under ${SIGDIR}"
    rm -rf "${SIGDIR:?}"/{clamav-db,yara-rules,scanner-rootfs.ext4,scanner-rootfs.ext4.sha256,vmlinux,signature-date,yara-rules-date}
    mkdir -p "${SIGDIR}"/{clamav-db,yara-rules,logs}
    echo "[+] Cleared."
fi

# ── SHA-256 verification negative-path tests ──────────────────────────────────
# Deliberately corrupt a recorded SHA-256 and confirm the affected download
# script fails cleanly with the expected error. This exercises the
# verification path itself, not just its happy case — a regression that
# silently accepts a mismatched hash would defeat the whole point of the
# checksum-verification work.
#
# Each test:
#   1. Saves the original value from versions.env.
#   2. Substitutes a known-wrong value (all zeros).
#   3. Deletes the installed artefact so the verification path runs.
#   4. Runs the affected script under `set +e` and asserts it exits non-zero.
#   5. Asserts the error output contains the expected mismatch text.
#   6. Restores the original value.
#
# The restore step is in an EXIT trap so an interrupted test cannot leave
# versions.env in a corrupted state.

step "1/6  Verification negative-path tests"

# Save originals up front so the trap can always restore them, even if
# the test fails before substitution would normally run.
ORIG_LOKI_SHA=""
ORIG_KERNEL_SHA=""
restore_versions_env() {
    if [ -n "$ORIG_LOKI_SHA" ]; then
        sed -i "s|^LOKI_SHA256=.*|LOKI_SHA256=\"${ORIG_LOKI_SHA}\"|" "$VERSIONS_FILE"
    fi
    if [ -n "$ORIG_KERNEL_SHA" ]; then
        sed -i "s|^KERNEL_SHA256=.*|KERNEL_SHA256=\"${ORIG_KERNEL_SHA}\"|" "$VERSIONS_FILE"
    fi
}
trap restore_versions_env EXIT

assert_fails_with() {
    local LABEL="$1"
    local EXPECTED_PATTERN="$2"
    shift 2
    local OUTPUT
    set +e
    OUTPUT="$("$@" 2>&1)"
    local RC="$?"
    set -e
    if [ "$RC" -eq 0 ]; then
        echo "[!] ${LABEL}: expected non-zero exit, got 0"
        echo "    Output:"
        echo "${OUTPUT}" | sed 's/^/      /'
        return 1
    fi
    if ! echo "$OUTPUT" | grep -qE "$EXPECTED_PATTERN"; then
        echo "[!] ${LABEL}: exited non-zero but output did not match expected pattern"
        echo "    Expected pattern: ${EXPECTED_PATTERN}"
        echo "    Output:"
        echo "${OUTPUT}" | sed 's/^/      /'
        return 1
    fi
    echo "[+] ${LABEL}: failed cleanly with expected message"
}

# Test A — LOKI-RS verification (verify_sha256 helper, prepare-build-machine.sh)
echo ""
echo "  [a] LOKI-RS SHA-256 mismatch"
ORIG_LOKI_SHA="$(grep -oP '(?<=^LOKI_SHA256=")[^"]*' "$VERSIONS_FILE")"
[ -n "$ORIG_LOKI_SHA" ] \
    || { echo "[!] LOKI_SHA256 not set in versions.env — phase A not applied?"; exit 1; }
sed -i "s|^LOKI_SHA256=.*|LOKI_SHA256=\"0000000000000000000000000000000000000000000000000000000000000000\"|" "$VERSIONS_FILE"
# Remove the installed loki-rs to force re-download and re-verify.
rm -rf /opt/loki-rs
assert_fails_with "LOKI-RS mismatch" "SHA-256 mismatch for LOKI-RS" \
    bash scripts/prepare-build-machine.sh
# Restore now so the rest of the test sees the correct value.
sed -i "s|^LOKI_SHA256=.*|LOKI_SHA256=\"${ORIG_LOKI_SHA}\"|" "$VERSIONS_FILE"
ORIG_LOKI_SHA=""    # avoid double-restore in the trap

# Test B — guest kernel verification (download-kernel.sh verify mode)
# Applicable only in verify mode: both KERNEL_RESOLVED and KERNEL_SHA256
# populated in versions.env. If either is empty (fresh discover state),
# there is no recorded pin to verify against, so skip.
#
# Strategy: rather than corrupt the recorded SHA and rely on a correct
# kernel being on disk (which assumes a prior build this session, an
# ordering dependency), we corrupt the ON-DISK kernel and leave the
# recorded SHA intact. download-kernel.sh verify mode hashes the on-disk
# vmlinux against the recorded SHA before any download; synthetic wrong
# bytes mismatch the (correct, untouched) recorded value, so the mismatch
# path fires with no network and no dependence on build order. Any real
# vmlinux present is backed up and restored; a synthetic one is removed.
echo ""
echo "  [b] guest kernel SHA-256 mismatch"
KERNEL_RESOLVED_NOW="$(grep -oP '(?<=^KERNEL_RESOLVED=")[^"]*' "$VERSIONS_FILE")"
KERNEL_SHA_NOW="$(grep -oP '(?<=^KERNEL_SHA256=")[^"]*' "$VERSIONS_FILE")"
if [ -z "$KERNEL_RESOLVED_NOW" ] || [ -z "$KERNEL_SHA_NOW" ]; then
    echo "[i] kernel not pinned (discover state); skipping verify-mode test."
else
    KERNEL_FILE="${SIGDIR}/vmlinux"
    KERNEL_BACKUP=""
    if [ -f "$KERNEL_FILE" ]; then
        KERNEL_BACKUP="$(mktemp)"
        cp -a "$KERNEL_FILE" "$KERNEL_BACKUP"
    fi
    # Synthetic wrong-bytes kernel. Its hash will not match the recorded
    # (untouched) KERNEL_SHA256, so verify mode reports the mismatch.
    printf 'synthetic-corrupt-kernel-for-negative-test' > "$KERNEL_FILE"
    assert_fails_with "kernel mismatch" "SHA-256 mismatch for guest kernel" \
        bash scripts/download-kernel.sh
    # Restore the real kernel if there was one; otherwise remove the
    # synthetic so we do not leave a bogus vmlinux for later steps.
    if [ -n "$KERNEL_BACKUP" ]; then
        mv "$KERNEL_BACKUP" "$KERNEL_FILE"
    else
        rm -f "$KERNEL_FILE"
    fi
fi

# Re-install LOKI-RS now that the negative test is complete, so subsequent
# steps see the build environment in its expected state.
echo ""
echo "  [+] Re-installing LOKI-RS for subsequent build steps"
bash scripts/prepare-build-machine.sh >/dev/null

# Negative tests done. Release the trap; from here on versions.env is correct
# and any failure during the real build pipeline should leave it alone.
trap - EXIT

# ── Real build pipeline ───────────────────────────────────────────────────────

step "2/6  Validate Butane config"
# The committed config carries the sentinel @@SCANNER_PASSWORD_HASH@@ in
# place of a real hash; prepare-boot-usb.sh substitutes a real hash at
# build time. For the validation pass we substitute a known-good dummy
# hash so butane --strict sees a syntactically valid crypt string. The
# dummy is never written outside this temp file.
#
# --files-dir points butane at config/ so it can resolve local: references
# in the config (e.g. host-scripts/*) regardless of where the temp file
# lives. Without this, butane cannot find the host-scripts/ directory.
TMP_CONFIG="$(mktemp --suffix=.bu)"
trap 'rm -f "$TMP_CONFIG"' EXIT
sed 's|@@SCANNER_PASSWORD_HASH@@|$6$dummysalt$dummyhashfortestingpurposesonly0000000000000000000000000000000000000000000000000000.|' \
    config/scanner-host.bu > "$TMP_CONFIG"
butane --strict --files-dir config "$TMP_CONFIG" > /dev/null
echo "[+] Butane OK"

step "3/6  Download ClamAV signatures"
bash scripts/download-clamav-signatures.sh

step "4/6  Refresh LOKI-RS YARA rules"
bash scripts/download-loki-yara-rules.sh

step "5/6  Download guest kernel"
bash scripts/download-kernel.sh

step "6/6  Build scanner image"
bash scripts/build-scanner-image.sh

# ── Post-build regression tests ───────────────────────────────────────────────
# Tests that exercise the artefacts the build just produced, beyond the
# build's own happy-path checks. These are run inside the same container
# session so the artefacts are guaranteed fresh and available.

step "Sidecar verification regression"
# Hermetic test: simulates the sidecar produce/verify protocol and
# asserts verification fails against a corrupted file. Catches the
# class of bug where the sidecar contains an absolute path that
# routes verification back to the source rather than the copy.
# See tests/test-usb-verify.sh header for the bug history.
bash "${SCRIPT_DIR}/test-usb-verify.sh"

echo ""
echo "=== Build pipeline OK ==="
echo "Artefacts under: ${SIGDIR}"
echo "Next: make test-scan  (needs /dev/kvm)"