#!/usr/bin/env bash
# scripts/prepare-data-usb.sh
# Formats a USB stick with the TROSKEL-DATA label, copies all scanner assets,
# verifies checksums, and records the write date.
# Usage: sudo bash scripts/prepare-data-usb.sh /dev/sdX
set -euo pipefail

USB_DEV="${1:?Usage: prepare-data-usb.sh <device> e.g. /dev/sdb}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGDIR="/var/lib/troskel"
SCANNER_ENV="${SCRIPT_DIR}/../config/scanner.env"

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

# Safety check — refuse to format the system disk.
# Identify the system disk by the device backing the root filesystem.
ROOT_DEV="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || true)"
USB_BASE="$(basename "$USB_DEV" | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')"
if [ -n "$ROOT_DEV" ] && [ "$USB_BASE" = "$ROOT_DEV" ]; then
    echo "[!] Refusing to format /dev/${ROOT_DEV} — this is your system disk."
    exit 1
fi

# Secondary check — refuse if the device is not connected via USB transport.
TRAN="$(lsblk -no TRAN "$USB_DEV" 2>/dev/null | head -1 | tr -d '[:space:]')"
if [ "$TRAN" != "usb" ]; then
    echo "[!] ${USB_DEV} does not appear to be a USB device (transport: ${TRAN:-unknown})."
    echo "    Refusing to format a non-USB device. Double-check with: lsblk -o NAME,TRAN"
    exit 1
fi

# Confirm required source files exist before doing anything destructive.
[ -f "$SCANNER_ENV" ]     || { echo "[!] Missing config/scanner.env — is the repo complete?"; exit 1; }

for FILE in scanner-rootfs.ext4 scanner-rootfs.ext4.sha256 vmlinux signature-date; do
    [ -f "${SIGDIR}/${FILE}" ] \
        || { echo "[!] Missing: ${SIGDIR}/${FILE} — run scripts/run-update.sh first."; exit 1; }
done

echo "[*] Preparing data USB on ${USB_DEV} (transport: usb, size: $(lsblk -no SIZE "$USB_DEV" | head -1))."
echo "    WARNING: all data on ${USB_DEV} will be destroyed."
read -r -p "    Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo "[*] Formatting ${USB_DEV} with label TROSKEL-DATA..."
wipefs -a "$USB_DEV"
parted "$USB_DEV" --script mklabel gpt
parted "$USB_DEV" --script mkpart primary ext4 0% 100%
sleep 1

if echo "$USB_DEV" | grep -q "nvme"; then
    PART="${USB_DEV}p1"
else
    PART="${USB_DEV}1"
fi

mkfs.ext4 -L TROSKEL-DATA "$PART"

MOUNT="$(mktemp -d)"
mount "$PART" "$MOUNT"

echo "[*] Copying scanner assets..."
cp "${SIGDIR}/scanner-rootfs.ext4"        "$MOUNT/"
cp "${SIGDIR}/scanner-rootfs.ext4.sha256" "$MOUNT/"
cp "${SIGDIR}/vmlinux"                    "$MOUNT/"
cp "${SIGDIR}/signature-date"             "$MOUNT/"
cp "$SCANNER_ENV" "${MOUNT}/scanner.env"
date -u --iso-8601=seconds > "${MOUNT}/usb-written-date"
sync

echo "[*] Verifying checksums..."
cd "$MOUNT"
sha256sum --check scanner-rootfs.ext4.sha256 \
    && echo "[+] Checksum OK." \
    || { echo "[!] Checksum FAILED — do not use this USB."; cd /; umount "$MOUNT"; exit 1; }
cd /

umount "$MOUNT"

echo ""
echo "[+] Data USB ready."
echo "    Label          : TROSKEL-DATA"
echo "    Signature date : $(cat "${SIGDIR}/signature-date")"
echo "    Written        : $(date -u --iso-8601=seconds)"
echo "    Label this USB with the signature date and transport to the air-gapped room."