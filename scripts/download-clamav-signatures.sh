#!/usr/bin/env bash
# scripts/download-clamav-signatures.sh
# Downloads the latest ClamAV signature databases (main.cvd, daily.cvd,
# bytecode.cvd) using freshclam and mirrors them into /var/lib/troskel/clamav-db/
# for injection into the scanner rootfs by build-scanner-image.sh.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

SIGDIR="/var/lib/troskel"
DB_OUT="${SIGDIR}/clamav-db"

mkdir -p "$DB_OUT"

# Determine the clamav user/group dynamically — the UID varies by distro
# and runner environment (e.g. 100 on standard Debian, 113 on GitHub runners).
CLAMAV_UID="$(getent passwd clamav | cut -d: -f3 || echo 0)"
CLAMAV_GID="$(getent group  clamav | cut -d: -f3 || echo 0)"

chown "${CLAMAV_UID}:${CLAMAV_GID}" "$DB_OUT"
chmod 755 "$DB_OUT"

# Pre-create freshclam.dat owned by the clamav user so freshclam does not
# hit a permission error trying to create it.
touch "${DB_OUT}/freshclam.dat"
chown "${CLAMAV_UID}:${CLAMAV_GID}" "${DB_OUT}/freshclam.dat"

# Write a minimal freshclam config — works on hosts where
# /etc/clamav/freshclam.conf is absent (NixOS, Docker without postinst).
FRESHCLAM_CONF="$(mktemp --suffix=.conf)"
FRESHCLAM_LOG="$(mktemp)"
chown "${CLAMAV_UID}:${CLAMAV_GID}" "$FRESHCLAM_LOG"

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

# Restore ownership to root for the rest of the build pipeline.
chown -R root:root "$DB_OUT"

SIG_DATE="$(date -u --iso-8601=seconds)"
echo "$SIG_DATE" > "${SIGDIR}/signature-date"

DB_COUNT="$(find "$DB_OUT" -type f \( -name '*.cvd' -o -name '*.cld' \) | wc -l)"
echo "[+] ClamAV signatures ready: ${DB_COUNT} database file(s) in ${DB_OUT}"
echo "[+] Signature date: ${SIG_DATE}"