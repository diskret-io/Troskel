#!/usr/bin/env bash
# scripts/download-kernel.sh
# Downloads a Firecracker-compatible guest kernel (vmlinux) from the official
# AWS Firecracker release assets. Run on the build station as part of run-update.sh.
#
# The kernel must match the Firecracker binary's CI version — newer Firecracker
# CI kernels drop virtio-mmio support, so a v1.7 binary paired with a v1.15
# kernel produces a guest that can't see its drives. We read FC_VERSION from
# config/versions.env so the two stay coupled.
#
# Usage: sudo bash scripts/download-kernel.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../config/versions.env
source "${SCRIPT_DIR}/../config/versions.env"

SIGDIR="/var/lib/troskel"
KERNEL_OUT="${SIGDIR}/vmlinux"
ARCH="$(uname -m)"

[ -n "${FC_VERSION:-}" ] \
    || { echo "[!] FC_VERSION not set — check config/versions.env"; exit 1; }
CI_VERSION="${FC_VERSION%.*}"   # v1.7.0 -> v1.7

echo "[*] Firecracker binary version: ${FC_VERSION}"
echo "[*] Matching guest kernel CI version: ${CI_VERSION}"

mkdir -p "$SIGDIR"

echo "[*] Resolving latest guest kernel for ${ARCH} under ${CI_VERSION}..."
KERNEL_KEY=$(curl -fsSL \
    "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-&list-type=2" \
    | grep -oP "(?<=<Key>)(firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V | tail -1)

[ -n "$KERNEL_KEY" ] \
    || { echo "[!] Could not resolve kernel key — check connectivity or that ${CI_VERSION} kernels exist."; exit 1; }

KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/${KERNEL_KEY}"
echo "[*] Downloading guest kernel: ${KERNEL_KEY}..."
wget -q --show-progress \
    -O "${KERNEL_OUT}.tmp" \
    "$KERNEL_URL" \
    || { echo "[!] Kernel download failed — check internet connectivity."; exit 1; }

mv "${KERNEL_OUT}.tmp" "$KERNEL_OUT"
chmod 644 "$KERNEL_OUT"

KSIZE="$(ls -lh "$KERNEL_OUT" | awk '{print $5}')"
echo "[+] Kernel ready: ${KERNEL_OUT} (${KSIZE})"