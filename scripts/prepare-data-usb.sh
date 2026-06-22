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

# Sidecar verification protocol. Single implementation; see the module header
# for the result contract. This script is a consumer (verifies the rootfs copy
# on the USB against the sidecar written alongside it).
# shellcheck source=lib/verify-artefact.sh
source "${SCRIPT_DIR}/lib/verify-artefact.sh"

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
# build-manifest.json joined for 1.0.0: every completed run-update.sh now
# generates one (it is the final step), so its absence here means the build
# is incomplete, not that the feature is unavailable. Tolerating its absence
# belongs on the read side (an old USB predating manifests), not here at
# write time. See the manifest CONTRACT block below.
for FILE in scanner-rootfs.ext4 scanner-rootfs.ext4.sha256 vmlinux signature-date yara-rules-date build-manifest.json; do
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

# Copy build-manifest.json. Required as of 1.0.0 (checked in the required-
# artefacts loop above), so this is an unconditional copy, not an optional one.
#
# CONTRACT (producer/propagator side): build-manifest.json is generated by
# scripts/generate-build-records.sh as the final step of run-update.sh,
# propagated to the scanning host by config/host-scripts/load-scanner (which
# copies it off this USB into /var/lib/troskel), and consumed by
# config/host-scripts/show-status (which parses it for build identity). This
# script is the middle hop: build station artefact directory -> data USB.
#
# The destination verification below re-reads the copy from the mounted USB
# (not from source) and checks both byte-identity (sha256) and parseability
# (jq), per the destructive-operations rule: a write whose result is not
# re-read from the destination is not verified. The build container has jq, 
# and so does the scanning host (pinned CoreOS base image, asserted by 
# check-system-ready). load-scanner and show-status
# parse build-manifest.json with vendored grep/sed regardless: that parser
# predates the jq-on-host guarantee, is tested, and adds no dependency, so it
# was kept. New host-side manifest logic uses jq. If the manifest's field names or nesting change in
# generate-build-records.sh, the host-side extractors must change too; the
# regression test tests/test-manifest-propagation.sh guards the round trip.
cp "${SIGDIR}/build-manifest.json" "$MOUNT/"

date -u --iso-8601=seconds > "${MOUNT}/usb-written-date"
sync

echo "[*] Verifying checksums..."
# Verify the rootfs copy on the USB via the shared module. It resolves the
# artefact under $MOUNT and rejects any sidecar carrying a path, so a corrupt
# sidecar cannot redirect the check at the source (bug 2). On any non-verified
# result we unmount and abort: a USB that does not verify must not ship.
if verify_artefact_check "$MOUNT" "$MOUNT/scanner-rootfs.ext4.sha256" >/dev/null; then
    echo "[+] Checksum OK."
else
    echo "[!] Checksum FAILED — do not use this USB."
    umount "$MOUNT"
    exit 1
fi

# Verify the manifest landed intact by re-reading it FROM THE USB (not from
# source). Two checks, because byte-identity and usability are different
# failure modes:
#   (1) sha256 of the USB copy matches sha256 of the source. Catches a
#       truncated or partially-written copy. A bare `cp` returning zero does
#       not prove the bytes reached the medium intact (page cache, a device
#       error surfacing only on read-back), which is exactly what re-reading
#       from the destination is for.
#   (2) jq parses the USB copy and the fields the scanning host will read are
#       present and non-empty. Catches a copy that is byte-identical to a
#       source that was itself corrupt, and a manifest whose structure has
#       drifted from what show-status extracts. jq is available in the build 
#       container and on the scanning host (pinned CoreOS base image); the host's 
#       build-manifest.json parse nonetheless uses vendored grep/sed, a pre-existing 
#       tested path kept to avoid churn.
# Field set mirrors what config/host-scripts/show-status reads: generated_at
# (top-level) and build_environment.troskel_commit / .troskel_dirty. If
# show-status starts reading a new field, add it here so a manifest missing
# that field fails at write time rather than showing "unknown" on the host.
echo "[*] Verifying build manifest on USB..."
SRC_SUM="$(sha256sum "${SIGDIR}/build-manifest.json" | awk '{print $1}')"
USB_SUM="$(sha256sum "${MOUNT}/build-manifest.json" | awk '{print $1}')"
if [ "$SRC_SUM" != "$USB_SUM" ]; then
    echo "[!] build-manifest.json on USB does not match source (sha256 mismatch)." >&2
    echo "    Source: ${SRC_SUM}" >&2
    echo "    USB   : ${USB_SUM}" >&2
    echo "    The copy did not land intact — do not use this USB." >&2
    umount "$MOUNT"; exit 1
fi
if ! jq -e \
        '.generated_at and (.build_environment.troskel_commit) and (.build_environment | has("troskel_dirty"))' \
        "${MOUNT}/build-manifest.json" >/dev/null 2>&1; then
    echo "[!] build-manifest.json on USB is not valid JSON or is missing required" >&2
    echo "    build-identity fields (generated_at, build_environment.troskel_commit," >&2
    echo "    build_environment.troskel_dirty). Do not use this USB." >&2
    echo "    Re-run scripts/run-update.sh to regenerate, then rewrite." >&2
    umount "$MOUNT"; exit 1
fi
echo "[+] Build manifest OK (matches source, parses, required fields present)."

umount "$MOUNT"

echo ""
echo "[+] Data USB ready."
echo "    Label          : TROSKEL-DATA"
echo "    Signature date : $(cat "${SIGDIR}/signature-date")"
echo "    YARA rules date: $(cat "${SIGDIR}/yara-rules-date")"
echo "    Written        : $(date -u --iso-8601=seconds)"
echo "    Label this USB with the signature date and transport to the air-gapped room."