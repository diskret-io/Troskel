#!/usr/bin/env bash
# scripts/run-update.sh
# Prepares all scanner artefacts. Run on the build station before each scan session.
# Usage: sudo bash scripts/run-update.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

SCRIPTS="$(dirname "$0")"

echo "============================================="
echo " Scanner update — $(date -u --iso-8601=seconds)"
echo "============================================="
echo ""

echo "[1/4] Downloading ClamAV signatures..."
bash "${SCRIPTS}/download-clamav-signatures.sh"
echo ""

echo "[2/4] Refreshing LOKI-RS YARA rules..."
bash "${SCRIPTS}/download-loki-yara-rules.sh"
echo ""

echo "[3/4] Downloading guest kernel..."
bash "${SCRIPTS}/download-kernel.sh"
echo ""

echo "[4/4] Building scanner image..."
bash "${SCRIPTS}/build-scanner-image.sh"
echo ""

echo "============================================="
echo "[+] Update complete."
echo "    Signature date : $(cat /var/lib/troskel/signature-date 2>/dev/null || echo unknown)"
echo "    YARA rules date: $(cat /var/lib/troskel/yara-rules-date 2>/dev/null || echo unknown)"
echo "============================================="