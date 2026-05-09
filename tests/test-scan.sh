#!/usr/bin/env bash
# tests/test-scan.sh
# End-to-end scan tests against the host directly. Run from the project root:
#   sudo bash tests/test-scan.sh
#
# Two scans:
#
#   1. Red    — scans tests/files/EICAR.txt; expect THREAT DETECTED with both
#               ENGINE: clamav status=threat and ENGINE: loki status=threat.
#               Both engines have rules for EICAR (ClamAV signature, plus the
#               YARA Forge SUSP_Just_EICAR / TRELLIX_ARC_Malw_Eicar rules
#               LOKI-RS bundles), so a single EICAR scan exercises both
#               verdict paths. The per-engine assertions preserve diagnostic
#               isolation: if only one engine breaks, the per-engine check
#               for that engine fails specifically.
#   2. Green  — scans a clean directory; expect CLEAN.
#
# The test runs against an unmodified production rootfs and takes about a
# minute total — no rebuild, no fixture injection, no state to restore.
#
# Yellow paths and other failure modes are documented in manual-tests-scan.md.
#
# Requirements:
#   - test-build.sh already run (artefacts present under /var/lib/troskel)
#   - /dev/kvm available and accessible to root
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

[ "$#" -eq 0 ] || { echo "[!] Unknown arguments: $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIGDIR="/var/lib/troskel"

cd "$PROJECT_ROOT"

# Pre-flight checks.
[ -r /dev/kvm ] && [ -w /dev/kvm ] \
    || { echo "[!] /dev/kvm not accessible — cannot run scan tests."; \
         echo "    Enable VT-x / AMD-V in BIOS, or run on a KVM-capable host."; exit 1; }

[ -f "${SIGDIR}/scanner-rootfs.ext4" ] && [ -f "${SIGDIR}/vmlinux" ] \
    || { echo "[!] Build artefacts missing under ${SIGDIR}."; \
         echo "    Run: sudo bash tests/test-build.sh"; exit 1; }

[ -f tests/files/EICAR.b64 ] \
    || { echo "[!] Missing tests/files/EICAR.b64"; exit 1; }

for tool in firecracker butane; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "[!] '$tool' not on PATH. Run scripts/prepare-build-machine.sh first."; exit 1; }
done

# --- scan-wrap setup --------------------------------------------------------
# scan-wrap lives in config/host-scripts/ and is materialised onto the
# scanning host by Ignition. Copy it directly for testing — no Butane
# compilation or Python extraction needed.
echo "=== Setting up scan-wrap for testing ==="
cp config/host-scripts/scan-wrap /tmp/scan-wrap
chmod +x /tmp/scan-wrap

head -c 64 /tmp/scan-wrap | grep -q "^#!" \
    || { echo "[!] config/host-scripts/scan-wrap is not a shell script."; exit 1; }
echo "[+] scan-wrap ready at /tmp/scan-wrap"

# --- Scan 1: Red — both engines should flag EICAR ------------------------
# EICAR is stored base64-encoded in the repo (tests/files/EICAR.b64) so
# that developer AV tools do not flag the repo itself. It is decoded to
# a temp file here, immediately before scanning — the microVM sees the
# real EICAR content and detects it correctly.

echo
echo "=== Scan 1/2: Red — EICAR (exercises both engines) ==="
mkdir -p /tmp/eicar-test-files
base64 -d tests/files/EICAR.b64 > /tmp/eicar-test-files/EICAR.txt
/tmp/scan-wrap /tmp/eicar-test-files 2>&1 | tee /tmp/scan-red.log

if ! grep -q 'VERDICT: THREAT DETECTED' /tmp/scan-red.log; then
    echo '[!] EICAR did not produce THREAT DETECTED — verdict pipeline broken'
    exit 1
fi
# Belt-and-braces: assert each engine specifically. If only one engine breaks
# the overall verdict still goes red (the other engine catches EICAR), but
# the per-engine assertion below catches the regression.
if ! grep -q '^\[..:..:..\] ENGINE: clamav status=threat' /tmp/scan-red.log; then
    echo '[!] ClamAV did not report a threat — ClamAV verdict path broken'
    grep '^\[..:..:..\] ENGINE:' /tmp/scan-red.log
    exit 1
fi
if ! grep -q '^\[..:..:..\] ENGINE: loki status=threat' /tmp/scan-red.log; then
    echo '[!] LOKI-RS did not report a threat — LOKI-RS verdict path broken'
    grep '^\[..:..:..\] ENGINE:' /tmp/scan-red.log
    exit 1
fi
echo '[+] EICAR detected by both engines as expected'

# --- Scan 2: Green --------------------------------------------------------

echo
echo "=== Scan 2/2: Green — clean directory ==="
mkdir -p /tmp/clean-files
echo 'hello' > /tmp/clean-files/note.txt
/tmp/scan-wrap /tmp/clean-files 2>&1 | tee /tmp/scan-clean.log

if ! grep -q 'VERDICT: CLEAN' /tmp/scan-clean.log; then
    echo '[!] Clean directory did not produce CLEAN verdict'
    exit 1
fi
echo '[+] Clean verdict as expected'

echo
echo "=== Scan pipeline OK — both engines and both verdict paths verified ==="
echo "For yellow-path and stress checks, see tests/manual-tests-scan.md"