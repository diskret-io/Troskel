#!/usr/bin/env bash
# scripts/download-wordlist.sh
# Downloads the EFF Long Wordlist used by prepare-boot-usb.sh for
# diceware passphrase generation. Run once during build-station setup.
# Safe to re-run — skips the download if the file is already present
# and its checksum is correct.
#
# Version and SHA-256 are sourced from config/versions.env. To bump
# the wordlist, edit WORDLIST_URL and WORDLIST_SHA256 there.
#
# Licence: the wordlist is published by the Electronic Frontier Foundation
# under CC-BY 3.0. See THIRD_PARTY_NOTICES.md for attribution details.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../config/versions.env
source "${SCRIPT_DIR}/../config/versions.env"

DEST="${SCRIPT_DIR}/../config/eff-large-wordlist.txt"

verify() {
    local FILE="$1"
    local ACTUAL
    ACTUAL="$(sha256sum "$FILE" | awk '{print $1}')"
    if [ "$ACTUAL" = "$WORDLIST_SHA256" ]; then
        return 0
    else
        echo "[!] SHA-256 mismatch."
        echo "    Expected : ${WORDLIST_SHA256}"
        echo "    Got      : ${ACTUAL}"
        return 1
    fi
}

# If already present and correct, skip.
if [ -f "$DEST" ]; then
    if verify "$DEST" 2>/dev/null; then
        echo "[+] EFF wordlist already present and verified — skipping download."
        exit 0
    else
        echo "[!] Existing wordlist failed checksum — re-downloading."
        rm -f "$DEST"
    fi
fi

echo "[*] Downloading EFF Long Wordlist..."
curl -fsSL "$WORDLIST_URL" -o "$DEST" \
    || { echo "[!] Download failed. Check internet connectivity."; rm -f "$DEST"; exit 1; }

echo "[*] Verifying checksum..."
verify "$DEST" \
    || { echo "[!] Downloaded file is corrupt. Removing."; rm -f "$DEST"; exit 1; }

echo "[+] EFF wordlist downloaded and verified."
echo "    Location : ${DEST}"
echo "    Licence  : CC-BY 3.0 (see THIRD_PARTY_NOTICES.md)"