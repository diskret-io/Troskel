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

# Required artefacts. yara-rules-date joined this list once check-system-ready
# on the scanning host started enforcing a YARA freshness gate alongside the
# ClamAV one; without it the scanning host has no way to age-check rules.
for FILE in scanner-rootfs.ext4 scanner-rootfs.ext4.sha256 vmlinux signature-date yara-rules-date; do
    [ -f "${SIGDIR}/${FILE}" ] \
        || { echo "[!] Missing: ${SIGDIR}/${FILE} — run scripts/run-update.sh first."; exit 1; }
done

echo "[*] Preparing data USB on ${USB_DEV} (transport: usb, size: $(lsblk -no SIZE "$USB_DEV" | head -1))."
echo "    WARNING: all data on ${USB_DEV} will be destroyed."

# Confirmation prompt. Skipped when invoked by the orchestrator
# (troskel-build.sh sets TROSKEL_CONFIRMED=1 after the operator has
# confirmed the device assignment in Phase 1). When invoked directly
# the operator gets the safety prompt as usual.
if [ "${TROSKEL_CONFIRMED:-0}" = "1" ]; then
    echo "    (Confirmation from orchestrator: TROSKEL_CONFIRMED=1)"
else
    read -r -p "    Continue? [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# Release any handles on the device before destructive operations and
# verify the release actually happened. This block has a contract with
# the orchestrator: if the device cannot be released, we abort non-zero
# with a diagnostic naming what is holding it. We do NOT swallow the
# failure with `|| true`, because operating on a busy device causes
# silent corruption (writes absorbed by stale page cache for an
# existing mount; verify against source rather than the USB).
#
# A desktop-environment auto-mounter (gnome-volume-monitor, udisks2)
# may have mounted partitions on the USB the moment it was inserted;
# udev may still be probing after a recent insertion. Either condition
# blocks wipefs and the rest of the destructive sequence.
echo "[*] Releasing device handles..."

# Attempt to unmount any partition on this device. The glob expands to
# /dev/sdX1, /dev/sdX2, etc.; the trailing ?* requires at least one
# character so the parent device is not matched. Individual umount
# failures here are not yet fatal; the verification below is.
for PART in "${USB_DEV}"?*; do
    [ -b "$PART" ] || continue
    # Find every mountpoint that resolves to this partition (a device
    # can be mounted in multiple places via bind mounts or auto-mount
    # plus orchestrator temp mounts) and unmount each.
    while MNT="$(findmnt -no TARGET --source "$PART" 2>/dev/null | head -1)"; do
        [ -n "$MNT" ] || break
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || break
    done
done
udevadm settle

# Verify: if anything on this device is still mounted, abort with a
# diagnostic naming the offending mount and (where possible) the
# process holding it. The operator needs to act; we will not proceed.
STILL_MOUNTED="$(findmnt -no TARGET,SOURCE \
    | awk -v dev="$(basename "$USB_DEV")" '$2 ~ dev {print}')"
if [ -n "$STILL_MOUNTED" ]; then
    echo "[!] Cannot release ${USB_DEV} — partitions still mounted:" >&2
    echo "$STILL_MOUNTED" | sed 's/^/      /' >&2
    echo "" >&2
    # Try to name the holders. fuser may not be installed everywhere;
    # fall back to lsof if available; otherwise just say so.
    if command -v fuser >/dev/null 2>&1; then
        echo "    Processes holding mounts on ${USB_DEV}:" >&2
        for PART in "${USB_DEV}"?*; do
            [ -b "$PART" ] || continue
            fuser -vm "$PART" 2>&1 | sed 's/^/      /' >&2 || true
        done
    elif command -v lsof >/dev/null 2>&1; then
        echo "    Processes with open files on ${USB_DEV}:" >&2
        lsof "$USB_DEV"?* 2>/dev/null | sed 's/^/      /' >&2 || true
    fi
    echo "" >&2
    echo "    Close any file managers showing the USB, exit any" >&2
    echo "    terminals cd'd into its mount, or unplug and replug" >&2
    echo "    the device. Then re-run this command." >&2
    exit 1
fi

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
cp "${SIGDIR}/yara-rules-date"            "$MOUNT/"
cp "$SCANNER_ENV" "${MOUNT}/scanner.env"

# Optional: copy build-manifest.json if present. Generated by
# scripts/generate-build-records.sh as the final step of run-update.sh.
# Optional rather than required because on a fresh refresh from an older
# state (before the manifest generator landed) the file may not yet exist;
# preserving the ability to write a data USB in that case keeps recovery
# paths open. show-status on the scanning host treats absence the same way.
if [ -f "${SIGDIR}/build-manifest.json" ]; then
    cp "${SIGDIR}/build-manifest.json" "$MOUNT/"
else
    echo "[i] build-manifest.json not present — run-update.sh has not yet generated one."
    echo "    The data USB will work without it; show-status will display 'unknown' for build identity."
fi

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
echo "    YARA rules date: $(cat "${SIGDIR}/yara-rules-date")"
echo "    Written        : $(date -u --iso-8601=seconds)"
echo "    Label this USB with the signature date and transport to the air-gapped room."