#!/usr/bin/env bash
# scripts/download-loki-yara-rules.sh
# Refreshes the YARA Forge Core rule set and IOC files used by LOKI-RS.
# Run on the build station as part of run-update.sh.
#
# `loki-util update` is the canonical upstream-supported path: it fetches
# the latest YARA Forge Core ruleset and writes it into the LOKI-RS
# install's `signatures/` tree. We then mirror that tree into
# /var/lib/troskel/yara-rules/ so the scanner-image build can inject
# it into the Debian rootfs alongside the ClamAV signatures.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

LOKI_DIR="/opt/loki-rs"
SIGDIR="/var/lib/troskel"
RULES_OUT="${SIGDIR}/yara-rules"

[ -x "${LOKI_DIR}/loki-util" ] \
    || { echo "[!] loki-util not found at ${LOKI_DIR}/loki-util — run prepare-build-machine.sh first."; exit 1; }

echo "[*] Refreshing YARA Forge Core rules via loki-util..."
( cd "$LOKI_DIR" && ./loki-util update ) \
    || { echo "[!] loki-util update failed — check internet connectivity."; exit 1; }

[ -d "${LOKI_DIR}/signatures" ] \
    || { echo "[!] Expected ${LOKI_DIR}/signatures after update — layout may have changed upstream."; exit 1; }

echo "[*] Mirroring signatures into ${RULES_OUT}..."
rm -rf "$RULES_OUT"
mkdir -p "$RULES_OUT"
cp -r "${LOKI_DIR}/signatures/." "${RULES_OUT}/"

date -u --iso-8601=seconds > "${SIGDIR}/yara-rules-date"

RULE_COUNT="$(find "$RULES_OUT" -type f -name '*.yar*' | wc -l)"
echo "[+] YARA rules ready: ${RULE_COUNT} rule files in ${RULES_OUT}"
echo "[+] Refresh date: $(cat "${SIGDIR}/yara-rules-date")"