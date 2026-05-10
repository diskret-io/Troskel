#!/usr/bin/env bash
# scripts/download-clamav-signatures.sh
# Downloads the latest ClamAV signature databases (main.cvd, daily.cvd,
# bytecode.cvd) using freshclam and mirrors them into /var/lib/troskel/clamav-db/
# for injection into the scanner rootfs by build-scanner-image.sh.
# Run on the build station as part of run-update.sh.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

SIGDIR="/var/lib/troskel"
DB_OUT="${SIGDIR}/clamav-db"

mkdir -p "$DB_OUT"

# freshclam writes directly into its configured DatabaseDirectory.
# We point it at our staging dir so signatures land where
# build-scanner-image.sh expects them.
echo "[*] Downloading ClamAV signatures via freshclam..."
freshclam --datadir="$DB_OUT"     || { echo "[!] freshclam failed — check internet connectivity or DNS."; exit 1; }

SIG_DATE="$(date -u --iso-8601=seconds)"
echo "$SIG_DATE" > "${SIGDIR}/signature-date"

DB_COUNT="$(find "$DB_OUT" -type f \( -name '*.cvd' -o -name '*.cld' \) | wc -l)"
echo "[+] ClamAV signatures ready: ${DB_COUNT} database file(s) in ${DB_OUT}"
echo "[+] Signature date: ${SIG_DATE}"