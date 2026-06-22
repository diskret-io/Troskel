#!/usr/bin/env bash
# scripts/sign-data-usb.sh
# Signs the contents of a prepared TROSKEL-DATA medium so the air-gapped
# scanning host can verify their AUTHENTICITY (not merely their integrity)
# before loading or running the scanner.
#
# Deliberately separate from prepare-data-usb.sh: the private signing key must
# never sit on the build host. It lives on a separate offline machine (an
# offline keyfile for now, a hardware token in future). The admin prepares the
# medium on the build station, carries it to the offline signing machine, and
# runs this script there with the key present.
#
# Usage: sudo bash scripts/sign-data-usb.sh <device> <private-key.pem>
#   e.g. sudo bash scripts/sign-data-usb.sh /dev/sdb /secure/troskel-sign.pem
#
# This script is the device-level wrapper. All manifest logic (which files are
# covered, the manifest shape, signing, and the verification primitives) lives
# in scripts/lib/medium-manifest.sh, shared with the host-side consumer
# (config/host-scripts/load-scanner) so the two cannot disagree on the covered
# set. See that module's header for the full producer/consumer contract.
set -euo pipefail

USB_DEV="${1:?Usage: sign-data-usb.sh <device> <private-key.pem> [host-public-key.pem]}"
KEYFILE="${2:?Usage: sign-data-usb.sh <device> <private-key.pem> [host-public-key.pem]}"
HOST_PUBKEY="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/medium-manifest.sh
source "${SCRIPT_DIR}/lib/medium-manifest.sh"

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root (to mount the medium)." >&2; exit 1; }
[ -f "$KEYFILE" ]    || { echo "[!] Private key not found: ${KEYFILE}" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "[!] openssl not found." >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "[!] jq not found (build/sign station only)." >&2; exit 1; }

# Fail fast if the key is not a usable private key, rather than discovering it
# when the sign call produces garbage. Fails (non-zero, nothing written) if the
# operator points us at a public key, wrong-algorithm key, or non-key file.
openssl pkey -in "$KEYFILE" -noout 2>/dev/null \
    || { echo "[!] ${KEYFILE} is not a readable private key." >&2; exit 1; }

# Optional sign-time cross-check (the silent self-mismatch guard). If the admin
# supplies the public key their target host was built with, confirm the private
# key we are about to sign with actually corresponds to it, and REFUSE on a
# mismatch. This catches a keypair mix-up here, at the signing desk, rather than
# at the air-gapped host, where the host's resulting BAD_SIGNATURE refusal is
# indistinguishable from an attack and there are no tools to diagnose it. See
# docs/medium-authenticity-contract.md (Signing behaviour). When no host public
# key is supplied, this check is skipped and only the always-on post-sign
# self-verification (below) runs.
if [ -n "$HOST_PUBKEY" ]; then
    [ -f "$HOST_PUBKEY" ] || { echo "[!] Host public key not found: ${HOST_PUBKEY}" >&2; exit 1; }
    openssl pkey -pubin -in "$HOST_PUBKEY" -noout 2>/dev/null \
        || { echo "[!] ${HOST_PUBKEY} is not a readable public key." >&2; exit 1; }
    if ! medium_manifest_keypair_matches "$KEYFILE" "$HOST_PUBKEY"; then
        echo "[!] REFUSING TO SIGN: the private key does not match the host public key." >&2
        echo "    Signing key     : ${KEYFILE}" >&2
        echo "    Host public key : ${HOST_PUBKEY}" >&2
        echo "    A medium signed with this key would be refused by that host as" >&2
        echo "    BAD_SIGNATURE. Use the private key matching the host's baked key," >&2
        echo "    or rebuild the host's boot ISO with this key's public half." >&2
        exit 1
    fi
    echo "[*] Signing key matches the supplied host public key."
fi

if echo "$USB_DEV" | grep -q "nvme"; then PART="${USB_DEV}p1"; else PART="${USB_DEV}1"; fi
[ -b "$PART" ] || { echo "[!] ${PART} is not a block device. Is the medium prepared?" >&2; exit 1; }

LABEL="$(lsblk -no LABEL "$PART" 2>/dev/null | head -1 | tr -d '[:space:]')"
[ "$LABEL" = "TROSKEL-DATA" ] \
    || { echo "[!] ${PART} label is '${LABEL:-none}', expected TROSKEL-DATA. Refusing." >&2; exit 1; }

MOUNT="$(mktemp -d)"
STAGE="$(mktemp -d)"
cleanup() {
    mountpoint -q "$MOUNT" && { mount -o remount,ro "$MOUNT" 2>/dev/null || true; umount "$MOUNT" 2>/dev/null || true; }
    rmdir "$MOUNT" 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

mount -o ro "$PART" "$MOUNT"

# Provenance fields come from the build manifest already on the medium. Its
# absence means the medium was not prepared by a 1.0.0+ prepare-data-usb.sh;
# that is an unsigned-legacy situation to refuse, not to paper over.
[ -f "${MOUNT}/build-manifest.json" ] \
    || { echo "[!] build-manifest.json missing on medium, re-prepare before signing." >&2; exit 1; }

COMMIT="$(jq -r '.build_environment.troskel_commit // empty' "${MOUNT}/build-manifest.json")"
DIRTY="$(jq -r  '.build_environment | if has("troskel_dirty") then (.troskel_dirty|tostring) else empty end' "${MOUNT}/build-manifest.json")"
GEN="$(jq -r    '.generated_at // empty' "${MOUNT}/build-manifest.json")"
{ [ -n "$COMMIT" ] && [ -n "$DIRTY" ] && [ -n "$GEN" ]; } \
    || { echo "[!] build-manifest.json missing required build-identity fields. Re-prepare." >&2; exit 1; }

echo "[*] Enumerating and hashing medium contents..."
if ! medium_manifest_build "$MOUNT" "$COMMIT" "$DIRTY" "$GEN" > "${STAGE}/${MEDIUM_MANIFEST_NAME}"; then
    echo "[!] Could not build a manifest for this medium." >&2
    exit 1
fi
FILE_COUNT="$(jq '.files | length' "${STAGE}/${MEDIUM_MANIFEST_NAME}")"

echo "[*] Signing manifest (${FILE_COUNT} files) with offline key..."
# Public half of the signing key, derived here purely to self-verify our own
# signature below. NOT the host's embedded key; a pass here proves only "we
# signed correctly", which is the post-condition we want at this stage. The
# host performs the real authenticity check against its independently embedded
# key later.
openssl pkey -in "$KEYFILE" -pubout -out "${STAGE}/pub.pem" 2>/dev/null
medium_manifest_sign "$STAGE" "$KEYFILE"

# Write manifest + signature to the medium in a minimal rw window.
mount -o remount,rw "$MOUNT"
cp "${STAGE}/${MEDIUM_MANIFEST_NAME}" "${MOUNT}/${MEDIUM_MANIFEST_NAME}"
cp "${STAGE}/${MEDIUM_SIG_NAME}"      "${MOUNT}/${MEDIUM_SIG_NAME}"
sync
mount -o remount,ro "$MOUNT"

# Post-condition (destructive-operations rule): verify the signature against
# the copies AS WRITTEN TO THE MEDIUM, not the staged copies. This fails if the
# cp truncated, the medium dropped bytes, or manifest and signature disagree as
# written. On failure, delete both artefacts so no half-signed medium ships.
echo "[*] Verifying signature against the medium copy..."
remove_bad_and_die() {
    echo "[!] $1" >&2
    mount -o remount,rw "$MOUNT"
    rm -f "${MOUNT}/${MEDIUM_MANIFEST_NAME}" "${MOUNT}/${MEDIUM_SIG_NAME}"
    sync
    mount -o remount,ro "$MOUNT"
    exit 1
}
medium_manifest_verify_sig "$MOUNT" "${STAGE}/pub.pem" >/dev/null \
    || remove_bad_and_die "Post-sign signature verification FAILED against the medium copy. Medium is NOT signed."

# Second post-condition: the signed manifest must enumerate exactly the
# medium's covered files. Producer half of the set-equality contract the host
# enforces on every load.
medium_manifest_verify_set "$MOUNT" >/dev/null \
    || remove_bad_and_die "Post-sign set check FAILED: manifest does not enumerate exactly the medium's files."

echo "[+] Medium signed and verified."
echo "    Files signed : ${FILE_COUNT}"
echo "    Commit       : ${COMMIT}$([ "$DIRTY" = "true" ] && echo ' (dirty)')"
echo "    Manifest     : /${MEDIUM_MANIFEST_NAME}"
echo "    Signature    : /${MEDIUM_SIG_NAME}"