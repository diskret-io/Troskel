#!/usr/bin/env bash
# tests/test-build.sh
# Runs the build pipeline end-to-end against the host directly.
# Stops at the first failure. Run from the project root:
#   sudo bash tests/test-build.sh
#   sudo bash tests/test-build.sh --clean   # discard prior artefacts first
#
# Covers:
#   - Butane config validation
#   - SHA-256 verification negative-path tests (LOKI-RS and guest kernel)
#   - ClamAV signature download
#   - YARA Forge Core rules refresh
#   - Guest kernel download
#   - Scanner image build (debootstrap, ClamAV install, LOKI-RS install,
#     signature/rule injection, ext4 image)
#   - Build records generation (SBOM + per-build manifest)
#   - SBOM-drift check: committed SBOM.json must match a fresh
#     regeneration modulo volatile fields (serialNumber, timestamp)
#
# Requirements:
#   - Debian/Ubuntu dev host
#   - prepare-build-machine.sh already run (debootstrap, butane, firecracker,
#     LOKI-RS, container runtime, etc. installed)
#   - root (the underlying scripts need it for debootstrap, mkfs.ext4, writes
#     to /var/lib/troskel)
#   - internet (for signature/rule/kernel downloads)
#
# Does not cover the scan pipeline — see test-scan.sh and manual-tests-scan.md.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

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
# Run scripts/prepare-build-machine.sh to install anything missing.
PREFLIGHT_FAIL=0
for tool in debootstrap butane firecracker; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "[!] '$tool' not found on PATH."; PREFLIGHT_FAIL=1; }
done
[ -x /opt/loki-rs/loki ] \
    || { echo "[!] loki-rs not found at /opt/loki-rs/loki."; PREFLIGHT_FAIL=1; }
if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
    echo ""
    echo "    Run: sudo bash scripts/prepare-build-machine.sh"
    echo "    On NixOS: ensure tools are available via nix-env or configuration.nix,"
    echo "    then install Firecracker, Butane, and LOKI-RS by running the script."
    exit 1
fi

if [ "$CLEAN" -eq 1 ]; then
    step "0/7  Clearing prior artefacts under ${SIGDIR}"
    rm -rf "${SIGDIR:?}"/{clamav-db,yara-rules,scanner-rootfs.ext4,scanner-rootfs.ext4.sha256,vmlinux,signature-date,yara-rules-date,yara-forge-resolved-tag,yara-forge-archive-sha256,build-manifest.json}
    mkdir -p "${SIGDIR}"/{clamav-db,yara-rules,logs}
    echo "[+] Cleared."
fi

# ── SHA-256 verification negative-path tests ──────────────────────────────────

step "1/7  Verification negative-path tests"

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

echo ""
echo "  [a] LOKI-RS SHA-256 mismatch"
ORIG_LOKI_SHA="$(grep -oP '(?<=^LOKI_SHA256=")[^"]*' "$VERSIONS_FILE")"
[ -n "$ORIG_LOKI_SHA" ] \
    || { echo "[!] LOKI_SHA256 not set in versions.env — phase A not applied?"; exit 1; }
sed -i "s|^LOKI_SHA256=.*|LOKI_SHA256=\"0000000000000000000000000000000000000000000000000000000000000000\"|" "$VERSIONS_FILE"
rm -rf /opt/loki-rs
assert_fails_with "LOKI-RS mismatch" "SHA-256 mismatch for LOKI-RS" \
    bash scripts/prepare-build-machine.sh
sed -i "s|^LOKI_SHA256=.*|LOKI_SHA256=\"${ORIG_LOKI_SHA}\"|" "$VERSIONS_FILE"
ORIG_LOKI_SHA=""

echo ""
echo "  [b] guest kernel SHA-256 mismatch"
ORIG_KERNEL_SHA="$(grep -oP '(?<=^KERNEL_SHA256=")[^"]*' "$VERSIONS_FILE")"
if [ -z "$ORIG_KERNEL_SHA" ]; then
    echo "[i] KERNEL_SHA256 is empty (discover mode); skipping verify-mode test."
    ORIG_KERNEL_SHA=""
else
    sed -i "s|^KERNEL_SHA256=.*|KERNEL_SHA256=\"0000000000000000000000000000000000000000000000000000000000000000\"|" "$VERSIONS_FILE"
    rm -f "${SIGDIR}/vmlinux"
    assert_fails_with "kernel mismatch" "SHA-256 mismatch for guest kernel" \
        bash scripts/download-kernel.sh
    sed -i "s|^KERNEL_SHA256=.*|KERNEL_SHA256=\"${ORIG_KERNEL_SHA}\"|" "$VERSIONS_FILE"
    ORIG_KERNEL_SHA=""
fi

echo ""
echo "  [+] Re-installing LOKI-RS for subsequent build steps"
bash scripts/prepare-build-machine.sh >/dev/null

trap - EXIT

# ── Real build pipeline ───────────────────────────────────────────────────────

step "2/7  Validate Butane config"
TMP_CONFIG="$(mktemp --suffix=.bu)"
trap 'rm -f "$TMP_CONFIG"' EXIT
sed 's|@@SCANNER_PASSWORD_HASH@@|$6$dummysalt$dummyhashfortestingpurposesonly0000000000000000000000000000000000000000000000000000.|' \
    config/scanner-host.bu > "$TMP_CONFIG"
butane --strict --files-dir config "$TMP_CONFIG" > /dev/null
echo "[+] Butane OK"

step "3/7  Download ClamAV signatures"
bash scripts/download-clamav-signatures.sh

step "4/7  Refresh LOKI-RS YARA rules"
bash scripts/download-loki-yara-rules.sh

step "5/7  Download guest kernel"
bash scripts/download-kernel.sh

step "6/7  Build scanner image"
bash scripts/build-scanner-image.sh

# ── Build records generation + SBOM drift check ───────────────────────────────
# The generator produces SBOM.json (project root) and build-manifest.json
# (/var/lib/troskel/). After generation, compare the just-emitted SBOM
# against the committed-at-HEAD copy modulo the two volatile fields
# (serialNumber and timestamp), which change every emission by design.
#
# A non-empty diff means the committed SBOM is stale relative to
# versions.env or the captured build state — the typical cause is a
# version bump in versions.env without a corresponding regeneration.
# The fix is to commit the regenerated file.

step "7/7  Build records and SBOM-drift check"

# Capture the committed copy *before* the generator overwrites it on disk.
SBOM_COMMITTED_TMP="$(mktemp --suffix=.json)"
trap 'rm -f "$TMP_CONFIG" "$SBOM_COMMITTED_TMP" "${SBOM_COMMITTED_TMP}.norm" "${SBOM_COMMITTED_TMP}.fresh.norm"' EXIT
git -C "$PROJECT_ROOT" show "HEAD:SBOM.json" > "$SBOM_COMMITTED_TMP" 2>/dev/null \
    || { echo "[!] Could not read HEAD:SBOM.json — is the file committed?"; exit 1; }

bash scripts/generate-build-records.sh

# Normalise both files by stripping the volatile fields, then diff.
# Pattern matches "serialNumber"/"timestamp" with optional whitespace
# before the colon-value, robust against minor formatting differences.
normalise_sbom() {
    sed -E \
        -e 's/"serialNumber":[[:space:]]*"[^"]*"/"serialNumber": "<volatile>"/' \
        -e 's/"timestamp":[[:space:]]*"[^"]*"/"timestamp": "<volatile>"/g' \
        "$1"
}

normalise_sbom "$SBOM_COMMITTED_TMP"             > "${SBOM_COMMITTED_TMP}.norm"
normalise_sbom "${PROJECT_ROOT}/SBOM.json"       > "${SBOM_COMMITTED_TMP}.fresh.norm"

if ! diff -u \
    "${SBOM_COMMITTED_TMP}.norm" \
    "${SBOM_COMMITTED_TMP}.fresh.norm"
then
    echo ""
    echo "[!] SBOM drift detected."
    echo "    The committed SBOM.json (at HEAD) does not match a fresh"
    echo "    regeneration from versions.env and the build state."
    echo ""
    echo "    Typical cause: a version was bumped in versions.env without"
    echo "    running 'sudo bash scripts/run-update.sh' to regenerate."
    echo "    Fix: commit the regenerated SBOM.json (it is already on disk"
    echo "    at the repo root; git status will show the diff)."
    echo ""
    exit 1
fi
echo "[+] SBOM in sync with versions.env and build state"

echo ""
echo "=== Build pipeline OK ==="
echo "Artefacts under: ${SIGDIR}"
echo "Next: sudo bash tests/test-scan.sh  (needs /dev/kvm)"