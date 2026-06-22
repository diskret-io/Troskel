#!/usr/bin/env bash
# scripts/gen-signing-key.sh
# Generate the data-USB signing keypair for the authenticity gate.
#
# Runs on the ADMIN'S HOST, not in the build container: the private key must
# land on the admin's own filesystem and persist, and a key generated inside an
# ephemeral --rm container would vanish with it. This is the one Troskel make
# target that is deliberately host-direct rather than containerised. It needs
# only openssl, which any host running the build already has.
#
# Produces an ed25519 keypair, the same primitive the gate verifies with:
#   <dir>/troskel-sign.key  the PRIVATE key (owner-only, 0600). Sign media with
#                           this via sign-data-usb.sh. NEVER commit it, NEVER put
#                           it on the scanning host, BACK IT UP: if lost, you
#                           cannot sign new media and must rotate (rebuild the
#                           boot ISO with a new public key).
#   <dir>/troskel-sign.pub  the PUBLIC key. Feed this to the boot build via
#                           TROSKEL_SIGN_PUBKEY so the host trusts your
#                           signatures. Safe to share; it verifies, never signs.
#
# See docs/medium-authenticity-contract.md (Key generation, Private-key tiers).
#
# Usage:
#   make gen-signing-key                 -> writes into ./keys/
#   make gen-signing-key KEYDIR=/path    -> writes into /path
#   (or invoke directly: bash scripts/gen-signing-key.sh [dir])
set -euo pipefail

KEYDIR="${1:-${KEYDIR:-./keys}}"
PRIV="${KEYDIR}/troskel-sign.key"
PUB="${KEYDIR}/troskel-sign.pub"

command -v openssl >/dev/null 2>&1 \
    || { echo "[!] openssl not found; it is required to generate a key." >&2; exit 1; }

# Named failure mode 1: silently overwriting an existing private key. That key
# may be the only copy of the secret that existing media were signed with;
# clobbering it would irrecoverably destroy it. Refuse if either file exists,
# and make the operator move or delete it deliberately. This is a destructive
# operation guarded by refusing to be destructive.
if [ -e "$PRIV" ] || [ -e "$PUB" ]; then
    echo "[!] A key already exists in ${KEYDIR}:" >&2
    [ -e "$PRIV" ] && echo "      ${PRIV}" >&2
    [ -e "$PUB" ]  && echo "      ${PUB}" >&2
    echo "    Refusing to overwrite. If you mean to ROTATE, move these aside" >&2
    echo "    first (and remember: rotating requires rebuilding the boot ISO" >&2
    echo "    with the new public key). If you mean to keep this key, you are" >&2
    echo "    already done." >&2
    exit 1
fi

mkdir -p "$KEYDIR"

# Named failure mode 2: a private key readable by other users. Create it with a
# restrictive umask so it is never, even momentarily, world- or group-readable.
# We set the umask in a subshell so the rest of the environment is unaffected.
echo "[*] Generating ed25519 signing keypair in ${KEYDIR}..."
(
    umask 077
    openssl genpkey -algorithm ed25519 -out "$PRIV"
)
openssl pkey -in "$PRIV" -pubout -out "$PUB"
chmod 0600 "$PRIV"
chmod 0644 "$PUB"

# Post-condition 1 (verify against the artefact, not the intent): the private
# key must actually be a usable ed25519 private key, and the public key its
# genuine public half. A generation that silently produced garbage must fail
# here, not at first signing. We derive the public half again and compare its
# canonical fingerprint to the written .pub; a mismatch means the pair on disk
# is inconsistent.
FP_FROM_PRIV="$(openssl pkey -in "$PRIV" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
FP_FROM_PUB="$(openssl pkey -pubin -in "$PUB" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
if [ -z "$FP_FROM_PRIV" ] || [ "$FP_FROM_PRIV" != "$FP_FROM_PUB" ]; then
    echo "[!] Generated keypair is inconsistent (private and public halves do not" >&2
    echo "    match). Removing the bad pair; please re-run." >&2
    rm -f "$PRIV" "$PUB"
    exit 1
fi

# Post-condition 2: the private key permissions must be owner-only. Re-read the
# mode from disk rather than trusting the chmod return. A key left readable is a
# silent security failure, so it is checked, not assumed.
MODE="$(stat -c '%a' "$PRIV" 2>/dev/null || stat -f '%Lp' "$PRIV" 2>/dev/null || echo '?')"
if [ "$MODE" != "600" ]; then
    echo "[!] Private key ${PRIV} has mode ${MODE}, expected 600. Fixing..." >&2
    chmod 0600 "$PRIV"
    MODE="$(stat -c '%a' "$PRIV" 2>/dev/null || echo '?')"
    if [ "$MODE" != "600" ]; then
        echo "[!] Could not secure ${PRIV} (mode still ${MODE}). Remove it and" >&2
        echo "    investigate the filesystem before using this key." >&2
        exit 1
    fi
fi

echo "[+] Keypair generated and verified:"
echo "      private: ${PRIV} (mode 600, keep secret, BACK IT UP)"
echo "      public : ${PUB}"
echo ""
echo "    Next steps:"
echo "      1. Back up ${PRIV} somewhere safe and offline. If you lose it you"
echo "         cannot sign new media and must rotate (new key + new boot ISO)."
echo "      2. Build a SIGNING boot ISO that trusts this key:"
echo "           sudo TROSKEL_SIGN_PUBKEY=${PUB} bash scripts/prepare-boot-usb.sh /dev/sdX"
echo "      3. Sign each data USB before use:"
echo "           sudo bash scripts/sign-data-usb.sh /dev/sdY ${PRIV} ${PUB}"
echo "         (passing ${PUB} lets the signer confirm it matches your host.)"