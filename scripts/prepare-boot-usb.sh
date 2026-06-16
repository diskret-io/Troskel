#!/usr/bin/env bash
# scripts/prepare-boot-usb.sh
# Compiles the Butane config to Ignition JSON, downloads the latest CoreOS
# stable ISO, embeds the Ignition config, and writes it to the boot USB stick.
#
# Generates a fresh four-word diceware passphrase for the 'scanner' user on
# every run, hashes it with openssl passwd -6, and substitutes the hash into
# a temporary copy of the Butane config. The committed config carries only
# the sentinel @@SCANNER_PASSWORD_HASH@@; no real hash ever lives in the
# repo. The plaintext passphrase is printed to the admin's terminal once
# at the end of the build and is not stored anywhere.
#
# Requires: butane, openssl, shuf (coreutils), docker
# Requires: config/eff-large-wordlist.txt (download from https://www.eff.org/dice
#           and place at the path; see THIRD_PARTY_NOTICES.md)
# Usage: sudo bash scripts/prepare-boot-usb.sh /dev/sdX
set -euo pipefail

USB_DEV="${1:?Usage: prepare-boot-usb.sh <device> e.g. /dev/sdb}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../config/versions.env
source "${SCRIPT_DIR}/../config/versions.env"

CONFIG="${SCRIPT_DIR}/../config/scanner-host.bu"
CONFIG_DIR="${SCRIPT_DIR}/../config"
WORDLIST="${SCRIPT_DIR}/../config/eff-large-wordlist.txt"
BUILD="$(mktemp -d --tmpdir fc-boot-XXXXXX)"

cleanup() { rm -rf "$BUILD"; }
trap cleanup EXIT

[ -f "$CONFIG" ] \
    || { echo "[!] Butane config not found: $CONFIG"; exit 1; }

[ -f "$WORDLIST" ] \
    || { echo "[!] Wordlist not found: $WORDLIST"; \
         echo "    Download the EFF Long Wordlist from https://www.eff.org/dice"; \
         echo "    and place it at the path above. See THIRD_PARTY_NOTICES.md."; \
         exit 1; }

# Docker is required.
if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    echo "[!] Docker not found."
    echo "    See https://docs.docker.com/engine/install/"
    exit 1
fi
echo "[*] Using container runtime: ${CONTAINER_RUNTIME}"

COREOS_IMAGE="quay.io/coreos/coreos-installer:${COREOS_INSTALLER_TAG}"
COREOS_INSTALLER="${CONTAINER_RUNTIME} run --security-opt label=disable --pull=always --rm -v ${BUILD}:/data -w /data ${COREOS_IMAGE}"

# --- Passphrase generation ------------------------------------------------
# Four-word diceware from the EFF Long Wordlist. ~51.6 bits of entropy
# (log2(7776^4) ≈ 51.7). Joined with hyphens for shell-friendliness.
#
# The plaintext exists only in this script's memory and on the admin's
# terminal at the very end. The hash is substituted into a temp copy of
# the Butane config which the cleanup trap deletes on exit. Nothing is
# written to disk that survives this script.
#
# shuf -n 4 picks 4 random lines uniformly without replacement; cut -f2
# strips the upstream "<dice-roll>\t<word>" prefix.
echo "[*] Generating scanner-user passphrase..."
PASSPHRASE="$(shuf -n 4 "$WORDLIST" | cut -f2 | paste -sd-)"
PASSWORD_HASH="$(openssl passwd -6 "$PASSPHRASE")"

# Substitute the sentinel in a temp copy. Crypt strings contain $ and /,
# so we use | as the sed delimiter rather than the conventional /.
CONFIG_BUILD="${BUILD}/scanner-host.bu"
sed "s|@@SCANNER_PASSWORD_HASH@@|${PASSWORD_HASH}|" "$CONFIG" > "$CONFIG_BUILD"

echo "[*] Checking Butane config..."
butane --check --files-dir "$CONFIG_DIR" "$CONFIG_BUILD" \
    || { echo "[!] Butane config failed validation."; exit 1; }

echo "[*] Compiling configuration..."
butane --pretty --strict --files-dir "$CONFIG_DIR" "$CONFIG_BUILD" \
    > "${BUILD}/ignition.json"
echo "[+] Ignition JSON written ($(wc -c < "${BUILD}/ignition.json") bytes)"

echo "[*] Downloading CoreOS ${COREOS_STREAM} ISO..."
$COREOS_INSTALLER download \
    --stream "${COREOS_STREAM}" \
    --platform metal \
    --format iso \
    --directory /data

ISO="$(ls "${BUILD}"/*.iso | head -1)"
[ -f "$ISO" ] || { echo "[!] ISO download failed — no .iso found in ${BUILD}"; exit 1; }
echo "[+] ISO: $(basename "$ISO")"

echo "[*] Embedding Ignition config into ISO..."
$COREOS_INSTALLER iso ignition embed \
    --ignition-file /data/ignition.json \
    "/data/$(basename "$ISO")"

echo "[*] Writing to ${USB_DEV}..."
echo "    WARNING: all data on ${USB_DEV} will be destroyed."
read -r -p "    Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Release any handles on the device before the dd write. A desktop-
# environment auto-mounter may have mounted partitions on the USB the
# moment it was inserted; udev may still be probing after a recent
# insertion. Either condition causes dd to fail or, worse, succeed
# while the kernel holds stale cached metadata that corrupts the
# subsequent verify. Unmount any partitions on the device and wait
# for udev to settle before writing.
echo "[*] Releasing device handles..."
umount "${USB_DEV}"?* 2>/dev/null || true
udevadm settle

dd if="$ISO" of="$USB_DEV" bs=4M status=progress
sync

echo ""
echo "[+] Boot USB written to ${USB_DEV}."
echo "    Note down today's date in log."
echo ""
echo "============================================================"
echo "  SCANNER PASSPHRASE — RECORD THIS NOW"
echo "============================================================"
echo ""
echo "    ${PASSPHRASE}"
echo ""
echo "  This passphrase is required to log in as 'scanner' on the"
echo "  scanning host. It is NOT stored anywhere — once this script"
echo "  exits, it cannot be recovered. Write it on the boot USB"
echo "  label (or an equivalent secure record) before continuing."
echo "============================================================"