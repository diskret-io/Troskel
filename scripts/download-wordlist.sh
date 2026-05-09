#!/usr/bin/env bash
# scripts/download-wordlist.sh
# Downloads the EFF Long Wordlist used by prepare-boot-usb.sh for
# diceware passphrase generation. Run once during build-station setup.
# Safe to re-run — skips the download if the file is already present
# and its checksum is correct.
#
# Licence: the wordlist is published by the Electronic Frontier Foundation
# under CC-BY 3.0. See THIRD_PARTY_NOTICES.md for attribution details.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${SCRIPT_DIR}/../config/eff-large-wordlist.txt"
URL="https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt"

# SHA-256 of the canonical upstream file. Recorded in SBOM.json.
EXPECTED_SHA256="addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e"

verify() {
    local FILE="$1"
    local ACTUAL
    ACTUAL="$(sha256sum "$FILE" | awk '{print $1}')"
    if [ "$ACTUAL" = "$EXPECTED_SHA256" ]; then
        return 0
    else
        echo "[!] SHA-256 mismatch."
        echo "    Expected : ${EXPECTED_SHA256}"
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
curl -fsSL "$URL" -o "$DEST" \
    || { echo "[!] Download failed. Check internet connectivity."; rm -f "$DEST"; exit 1; }

echo "[*] Verifying checksum..."
verify "$DEST" \
    || { echo "[!] Downloaded file is corrupt. Removing."; rm -f "$DEST"; exit 1; }

echo "[+] EFF wordlist downloaded and verified."
echo "    Location : ${DEST}"
echo "    Licence  : CC-BY 3.0 (see THIRD_PARTY_NOTICES.md)"