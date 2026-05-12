#!/usr/bin/env bash
# tests/test-scan.sh
# End-to-end scan tests inside the troskel-build container.
#
# Invocation: `make test-scan` (from the project root).
#
# Direct host invocation is not supported — the script gates on a
# container sentinel and refuses to run on the host. See
# docs/roadmap/build-system-rationalisation.md for the rationale.
#
# Two scans:
#
#   1. Red    — scans tests/files/EICAR.txt AND a known encrypted ZIP; expect
#               THREAT DETECTED with:
#                 - ENGINE: clamav status=threat — both the Eicar signature
#                   and a Heuristics.Encrypted.* finding (from the encrypted
#                   ZIP, via --alert-encrypted-archive)
#                 - ENGINE: loki status=threat — TRELLIX_ARC_Malw_Eicar
#                   YARA rule against the EICAR plaintext
#               This exercises both engines, both verdict paths, and the new
#               ClamAV alert classes added by the clamav-tightening work.
#   2. Green  — scans a clean directory; expect CLEAN.
#
# The test runs against an unmodified production rootfs and takes about a
# minute total — no rebuild, no fixture injection, no state to restore.
#
# Yellow paths and other failure modes are documented in manual-tests-scan.md.
#
# Container-internal requirements (the Dockerfile and Makefile satisfy these):
#   - test-build.sh already run (artefacts present under /var/lib/troskel,
#     persisted in the troskel-artefacts named volume)
#   - /dev/kvm available and accessible to root (--device /dev/kvm in the
#     Makefile target)
#   - tests/files/EICAR.b64 present in the repo
#   - tests/files/encrypted-test.zip.b64 present in the repo (see
#     tests/files/README.md for the regeneration recipe)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

# ── Container sentinel gate ───────────────────────────────────────────────────
# Refuses to run outside the troskel-build container. See test-build.sh
# for the full rationale; the gate is identical here.
if [ ! -f /.troskel-container ]; then
    echo "[!] tests/test-scan.sh must run inside the troskel-build container."
    echo ""
    echo "    Supported invocation:"
    echo "      make test-scan"
    echo ""
    echo "    Fast-iteration fallback (run a single script in the container):"
    echo "      docker run --rm --privileged --device /dev/kvm \\"
    echo "          --volume \"\$PWD:/troskel\" --workdir /troskel \\"
    echo "          troskel-build bash tests/test-scan.sh"
    echo ""
    echo "    See docs/roadmap/build-system-rationalisation.md for the rationale."
    exit 1
fi

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
         echo "    Run: make test-build"; exit 1; }

[ -f tests/files/EICAR.b64 ] \
    || { echo "[!] Missing tests/files/EICAR.b64"; exit 1; }

[ -f tests/files/encrypted-test.zip.b64 ] \
    || { echo "[!] Missing tests/files/encrypted-test.zip.b64"
         echo "    See tests/files/README.md for the regeneration recipe."
         exit 1; }

for tool in firecracker butane; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "[!] '$tool' not on PATH. The container image may be out of date — try: make clean && make image"; exit 1; }
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

# --- Scan 1: Red — EICAR + encrypted archive ------------------------------
# EICAR is stored base64-encoded in the repo (tests/files/EICAR.b64) so
# that developer AV tools do not flag the repo itself. It is decoded to
# a temp file here, immediately before scanning — the microVM sees the
# real EICAR content and detects it correctly.
#
# encrypted-test.zip is a small password-protected ZIP, also base64-
# encoded for the same reason: --alert-encrypted-archive flags any
# encrypted ZIP, so committing an unencoded copy would trigger AV
# scanners on the developer's host. Decoded here, scanned with EICAR,
# detected via ClamAV's encrypted-archive alert.

echo
echo "=== Scan 1/2: Red — EICAR + encrypted archive (exercises both engines) ==="
mkdir -p /tmp/red-test-files
base64 -d tests/files/EICAR.b64 > /tmp/red-test-files/EICAR.txt
base64 -d tests/files/encrypted-test.zip.b64 > /tmp/red-test-files/encrypted-test.zip
bash /tmp/scan-wrap /tmp/red-test-files 2>&1 | tee /tmp/scan-red.log

if ! grep -q 'VERDICT: THREAT DETECTED' /tmp/scan-red.log; then
    echo '[!] Red scan did not produce THREAT DETECTED — verdict pipeline broken'
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
# LOKI-RS detects EICAR via the TRELLIX_ARC_Malw_Eicar rule in YARA Forge Core.
if ! grep -q '^\[..:..:..\] ENGINE: loki status=threat' /tmp/scan-red.log; then
    echo '[!] LOKI-RS did not report a threat — LOKI-RS verdict path broken'
    grep '^\[..:..:..\] ENGINE: loki' /tmp/scan-red.log || true
    exit 1
fi
echo '[+] EICAR detected by both engines as expected'

# Check that ClamAV picked up the encrypted-archive heuristic. The
# signature name for an encrypted ZIP alert in current ClamAV is
# "Heuristics.Encrypted.Zip"; older versions use "Heuristics.Encrypted.ZIP"
# or "Heuristics.Encrypted". Match the family rather than the exact name.
if grep -qE 'encrypted-test\.zip:.*Heuristics\.Encrypted' /tmp/scan-red.log; then
    echo '[+] Encrypted archive flagged by ClamAV --alert-encrypted-archive'
else
    echo '[!] Encrypted ZIP was not flagged by ClamAV — --alert-encrypted-archive may not be engaged'
    echo '    ClamAV FOUND lines from the scan:'
    grep ' FOUND$' /tmp/scan-red.log | sed 's/^/      /' || true
    exit 1
fi

# Check whether the flagged filename appeared on screen — confirms show_findings works.
if grep -q 'EICAR\|FOUND' /tmp/scan-red.log; then
    echo '[+] Flagged filename shown on screen'
else
    echo '[~] Flagged filename not found in output — show_findings may need attention'
    echo '    (see manual-tests-scan.md for show_findings verification procedure)'
fi

# --- Scan 2: Green --------------------------------------------------------

echo
echo "=== Scan 2/2: Green — clean directory ==="
mkdir -p /tmp/clean-files
echo 'hello' > /tmp/clean-files/note.txt
bash /tmp/scan-wrap /tmp/clean-files 2>&1 | tee /tmp/scan-clean.log

if ! grep -q 'VERDICT: CLEAN' /tmp/scan-clean.log; then
    echo '[!] Clean directory did not produce CLEAN verdict'
    exit 1
fi
echo '[+] Clean verdict as expected'

echo
echo "=== Scan pipeline OK — both engines, both verdict paths, and the encrypted-archive heuristic verified ==="
echo "For yellow-path and stress checks, see tests/manual-tests-scan.md"