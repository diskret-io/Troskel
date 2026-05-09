#!/usr/bin/env bash
# scripts/download-latest-signatures.sh
set -euo pipefail

SIGDIR="/var/lib/troskel"
CLAMDB="${SIGDIR}/clamav-db"
# freshclam's default database location. AppArmor profiles shipped with
# the Ubuntu/Debian clamav-freshclam package only permit writes to this
# path. We let freshclam write there (where it is allowed and expected
# to write), then mirror the result into our own artefact directory.
FRESHCLAM_DEFAULT_DB="/var/lib/clamav"

mkdir -p "$CLAMDB"
mkdir -p "$FRESHCLAM_DEFAULT_DB"

# freshclam drops privileges to the clamav system user before writing.
# Both the default path and our artefact path need to be owned by that
# user. The default path is owned by clamav out of the box on a fresh
# install, but we touch it anyway in case an earlier failed run left it
# in an unexpected state.
chown -R clamav:clamav "$FRESHCLAM_DEFAULT_DB" "$CLAMDB" 2>/dev/null \
    || { echo "[!] Could not chown signature directories. Is the 'clamav' user present (apt install clamav-freshclam)?"; exit 1; }

echo "[*] Downloading latest ClamAV signatures..."
# Use freshclam's default database location — DatabaseDirectory left at
# its compiled-in default so AppArmor lets the write through. We still
# pin the mirror so behaviour is deterministic.
CONF="$(mktemp --suffix=.conf)"
cat > "$CONF" <<EOF
LogVerbose false
LogTime true
DatabaseMirror database.clamav.net
Checks 0
EOF
chmod 644 "$CONF"

freshclam --config-file="$CONF" \
    || { echo "[!] Download failed — check internet connectivity (or AppArmor logs: sudo dmesg | grep -i apparmor)."; rm -f "$CONF"; exit 1; }
rm -f "$CONF"

# Mirror freshclam's output into the project artefact directory. The
# build-scanner-image step injects from $CLAMDB, not from freshclam's
# default path, so this copy is what actually ships into the rootfs.
#
# Wipe $CLAMDB completely first, then copy only known signature file
# extensions. Using `cp -a *` would have copied any stray file (test
# artefacts, hand-placed debug files, etc.) — guarding against that
# matters because anything in $CLAMDB ends up in the rootfs.
echo "[*] Mirroring signatures into ${CLAMDB}..."
rm -rf "${CLAMDB:?}"/*
for ext in cvd cld cdb fp ftm; do
    cp -a "$FRESHCLAM_DEFAULT_DB"/*.${ext} "$CLAMDB/" 2>/dev/null || true
done
chown -R clamav:clamav "$CLAMDB"

# Sanity-check: at least one signature database (.cvd or .cld) should
# have arrived. main.cvd and daily.cvd are the minimum useful set.
SIG_COUNT=$(find "$CLAMDB" -maxdepth 1 \( -name "*.cvd" -o -name "*.cld" \) | wc -l)
[ "$SIG_COUNT" -gt 0 ] \
    || { echo "[!] No signature databases found in ${CLAMDB} after copy. Check ${FRESHCLAM_DEFAULT_DB}."; exit 1; }

date -u --iso-8601=seconds > "${SIGDIR}/signature-date"

echo "[+] Signatures ready: $(cat "${SIGDIR}/signature-date")"
echo "[+] ClamAV DB:"
ls -lh "$CLAMDB"