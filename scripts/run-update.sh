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

echo "[1/4] Downloading latest ClamAV signatures..."
bash "${SCRIPTS}/download-latest-signatures.sh"
echo ""

echo "[2/4] Refreshing YARA Forge Core rules..."
bash "${SCRIPTS}/download-yara-rules.sh"
echo ""

echo "[3/4] Downloading guest kernel..."
bash "${SCRIPTS}/download-kernel.sh"
echo ""

echo "[4/4] Building scanner image..."
bash "${SCRIPTS}/build-scanner-image.sh"
echo ""

echo "============================================="
echo "[+] Update complete."
echo "    ClamAV signature date : $(cat /var/lib/troskel/signature-date)"
echo "    YARA rules date       : $(cat /var/lib/troskel/yara-rules-date 2>/dev/null || echo 'not recorded')"
echo "    Kernel                : $(ls -lh /var/lib/troskel/vmlinux | awk '{print $5}')"
echo "    Image size            : $(ls -lh /var/lib/troskel/scanner-rootfs.ext4 | awk '{print $5}')"
echo ""
echo "    Next steps:"
echo "      sudo bash scripts/prepare-data-usb.sh  /dev/sdX"
echo "      sudo bash scripts/prepare-boot-usb.sh  /dev/sdY"
echo "============================================="