#!/usr/bin/env bash
# scripts/prepare-build-machine.sh
# Run once on the build station to install all required tools.
# Safe to run again on an already-configured machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../config/versions.env
source "${SCRIPT_DIR}/../config/versions.env"

latest_github_tag() {
    basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/${1}/releases/latest")"
}

echo "[*] Installing build dependencies..."
apt-get update
apt-get install -y \
    debootstrap \
    clamav-freshclam \
    e2fsprogs \
    wget \
    curl \
    gnupg \
    xorriso \
    util-linux \
    parted \
    iproute2 \
    openssl \
    coreutils

# Container runtime — Docker is required.
if command -v docker >/dev/null 2>&1; then
    echo "[+] Container runtime: docker (already installed)"
else
    echo "[!] Docker not found."
    echo "    See https://docs.docker.com/engine/install/ for your distribution."
    echo "    After installing Docker, re-run this script."
    exit 1
fi

# EFF Long Wordlist — needed by prepare-boot-usb.sh for passphrase generation.
echo "[*] Downloading EFF Long Wordlist..."
bash "${SCRIPT_DIR}/download-wordlist.sh"

echo ""
echo "[+] Build station ready."