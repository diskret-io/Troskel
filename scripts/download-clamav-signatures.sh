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

# freshclam requires the database directory to be owned by the clamav user
# (UID 100 on Debian/Ubuntu) or root. We chown to clamav if it exists,
# fall back to root otherwise (e.g. on NixOS or minimal Docker images).
# freshclam.dat lock file must also be writable by the running user.
if getent passwd clamav >/dev/null 2>&1; then
    chown clamav:clamav "$DB_OUT"
else
    chown root:root "$DB_OUT"
fi
chmod 755 "$DB_OUT"
rm -f "${DB_OUT}/freshclam.dat"

# Write a minimal freshclam config so the tool works on hosts where
# /etc/clamav/freshclam.conf is absent (e.g. NixOS, Docker without postinst).
FRESHCLAM_CONF="$(mktemp --suffix=.conf)"
FRESHCLAM_LOG="$(mktemp)"

# Set log file ownership to match the DB directory owner.
if getent passwd clamav >/dev/null 2>&1; then
    chown clamav:clamav "$FRESHCLAM_LOG"
fi

cat > "$FRESHCLAM_CONF" <<CONF
DatabaseDirectory ${DB_OUT}
DatabaseMirror database.clamav.net
UpdateLogFile ${FRESHCLAM_LOG}
LogSyslog false
LogRotate false
MaxAttempts 3
CONF

echo "[*] Downloading ClamAV signatures via freshclam..."
freshclam --config-file="$FRESHCLAM_CONF" \
    || { rm -f "$FRESHCLAM_CONF" "$FRESHCLAM_LOG"; \
         echo "[!] freshclam failed — check internet connectivity or DNS."; exit 1; }
rm -f "$FRESHCLAM_CONF" "$FRESHCLAM_LOG"

# Restore ownership to root so the rest of the build pipeline can read
# the files without privilege concerns.
chown -R root:root "$DB_OUT"

SIG_DATE="$(date -u --iso-8601=seconds)"
echo "$SIG_DATE" > "${SIGDIR}/signature-date"

DB_COUNT="$(find "$DB_OUT" -type f \( -name '*.cvd' -o -name '*.cld' \) | wc -l)"
echo "[+] ClamAV signatures ready: ${DB_COUNT} database file(s) in ${DB_OUT}"
echo "[+] Signature date: ${SIG_DATE}"