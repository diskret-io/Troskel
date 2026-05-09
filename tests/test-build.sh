#!/usr/bin/env bash
# tests/test-build.sh
# Runs the build pipeline end-to-end against the host directly.
# Stops at the first failure. Run from the project root:
#   sudo bash tests/test-build.sh
#   sudo bash tests/test-build.sh --clean   # discard prior artefacts first
#
# Covers:
#   - Butane config validation
#   - ClamAV signature download
#   - YARA Forge Core rules refresh (via loki-util update)
#   - Guest kernel download
#   - Scanner image build (debootstrap, ClamAV install, LOKI-RS install,
#     signature/rule injection, ext4 image)
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

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *)       echo "[!] Unknown argument: $arg"; exit 1 ;;
    esac
done

step() { echo ""; echo "=== $* ==="; }

cd "$PROJECT_ROOT"

# Refuse to run if prepare-build-machine.sh has not been run. Without
# debootstrap, butane, firecracker etc. on PATH, the test would fail
# halfway through with confusing errors. Better to fail loudly up front.
for tool in debootstrap butane firecracker; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "[!] '$tool' not found on PATH. Run scripts/prepare-build-machine.sh first."; exit 1; }
done
[ -x /opt/loki-rs/loki ] \
    || { echo "[!] /opt/loki-rs/loki not found. Run scripts/prepare-build-machine.sh first."; exit 1; }

if [ "$CLEAN" -eq 1 ]; then
    step "0/5  Clearing prior artefacts under ${SIGDIR}"
    rm -rf "${SIGDIR:?}"/{clamav-db,yara-rules,scanner-rootfs.ext4,scanner-rootfs.ext4.sha256,vmlinux,signature-date,yara-rules-date}
    mkdir -p "${SIGDIR}"/{clamav-db,yara-rules,logs}
    echo "[+] Cleared."
fi

step "1/5  Validate Butane config"
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

step "2/5  Download ClamAV signatures"
bash scripts/download-latest-signatures.sh

step "3/5  Refresh YARA Forge Core rules"
bash scripts/download-yara-rules.sh

step "4/5  Download guest kernel"
bash scripts/download-kernel.sh

step "5/5  Build scanner image"
bash scripts/build-scanner-image.sh

echo ""
echo "=== Build pipeline OK ==="
echo "Artefacts under: ${SIGDIR}"
echo "Next: sudo bash tests/test-scan.sh  (needs /dev/kvm)"