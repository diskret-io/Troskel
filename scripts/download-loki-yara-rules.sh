#!/usr/bin/env bash
# scripts/download-loki-yara-rules.sh
# Downloads the latest YARA Forge Core rule set directly from GitHub
# and stages it into /var/lib/troskel/yara-rules/ for injection into
# the scanner rootfs by build-scanner-image.sh.
#
# This script does not use loki-util — it fetches the upstream ZIP
# archive directly, which works on any system with curl and unzip
# regardless of whether loki-util can run (e.g. NixOS).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

SIGDIR="/var/lib/troskel"
RULES_OUT="${SIGDIR}/yara-rules"
TMPDIR_RULES="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR_RULES"; }
trap cleanup EXIT

# YARA Forge publishes weekly releases. The `latest` redirect resolves
# to the most recent release automatically.
YARA_FORGE_URL="https://github.com/YARAHQ/yara-forge/releases/latest/download/yara-forge-rules-core.zip"

echo "[*] Downloading YARA Forge Core rules..."
curl -fsSL --location "$YARA_FORGE_URL" \
    -o "${TMPDIR_RULES}/yara-forge-rules-core.zip" \
    || { echo "[!] Download failed — check internet connectivity."; exit 1; }

echo "[*] Extracting rules..."
unzip -q "${TMPDIR_RULES}/yara-forge-rules-core.zip" \
    -d "${TMPDIR_RULES}/extracted" \
    || { echo "[!] Extraction failed — zip may be corrupt."; exit 1; }

# The zip contains a packages/core/ directory with the .yar file(s).
# Find and stage them.
RULE_FILES="$(find "${TMPDIR_RULES}/extracted" -name '*.yar' -o -name '*.yara' 2>/dev/null)"
if [ -z "$RULE_FILES" ]; then
    echo "[!] No .yar or .yara files found in archive — YARA Forge layout may have changed."
    exit 1
fi

rm -rf "$RULES_OUT"
# LOKI-RS expects this exact directory structure under signatures/:
#   signatures/yara/      — .yar rule files
#   signatures/iocs/      — hash-iocs.txt, filename-iocs.txt, c2-iocs.txt
# Both are sourced directly from GitHub — YARA rules from YARA Forge,
# IOCs from Neo23x0/signature-base (the upstream IOC collection used
# by the original Loki scanner and maintained alongside LOKI-RS).
mkdir -p "${RULES_OUT}/yara"
mkdir -p "${RULES_OUT}/iocs"

echo "[*] Downloading IOC files from signature-base..."
SIGBASE_URL="https://raw.githubusercontent.com/Neo23x0/signature-base/master/iocs"
curl -fsSL "${SIGBASE_URL}/hash-iocs.txt"     -o "${RULES_OUT}/iocs/hash-iocs.txt"     || { echo "[!] Failed to download hash-iocs.txt"; exit 1; }
curl -fsSL "${SIGBASE_URL}/filename-iocs.txt" -o "${RULES_OUT}/iocs/filename-iocs.txt"     || { echo "[!] Failed to download filename-iocs.txt"; exit 1; }
curl -fsSL "${SIGBASE_URL}/c2-iocs.txt"       -o "${RULES_OUT}/iocs/c2-iocs.txt"     || { echo "[!] Failed to download c2-iocs.txt"; exit 1; }
echo "[+] IOC files downloaded"

# Copy .yar files into signatures/yara/ — LOKI-RS reads from this path.
find "${TMPDIR_RULES}/extracted" \( -name '*.yar' -o -name '*.yara' \) | while read -r FILE; do
    cp "$FILE" "${RULES_OUT}/yara/$(basename "$FILE")"
done

date -u --iso-8601=seconds > "${SIGDIR}/yara-rules-date"

RULE_COUNT="$(find "${RULES_OUT}/yara" -type f \( -name '*.yar' -o -name '*.yara' \) | wc -l)"
echo "[+] YARA rules ready: ${RULE_COUNT} rule file(s) in ${RULES_OUT}"
echo "[+] Refresh date: $(cat "${SIGDIR}/yara-rules-date")"