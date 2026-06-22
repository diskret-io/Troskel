#!/usr/bin/env bash
# scripts/prepare-boot-usb.sh
# Compiles the Butane config to Ignition JSON, downloads the latest CoreOS
# stable ISO, embeds the Ignition config, and writes it to the boot USB stick.
#
# Generates a fresh four-word diceware passphrase for the 'scanner' user on
# every run, hashes it with openssl passwd -6, and substitutes the hash into
# a temporary copy of the Butane config. The committed config carries only
# the sentinel @@SCANNER_PASSWORD_HASH@@; no real hash ever lives in the
# repo. The plaintext passphrase is printed to the admin's terminal once
# at the end of the build and is not stored anywhere.
#
# Requires: butane, openssl, shuf (coreutils), docker
# Requires: config/eff-large-wordlist.txt (download from https://www.eff.org/dice
#           and place at the path; see THIRD_PARTY_NOTICES.md)
# Usage: sudo bash scripts/prepare-boot-usb.sh /dev/sdX
set -euo pipefail

USB_DEV="${1:?Usage: prepare-boot-usb.sh <device> e.g. /dev/sdb}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../config/versions.env
source "${SCRIPT_DIR}/../config/versions.env"

# Passphrase banner producer. The banner layout is a cross-script contract
# consumed by scripts/troskel-build.sh; both halves live in this module so
# the producer and the awk that parses it cannot drift apart. See the module
# header for the PROTOCOL CONTRACT. tests/test-passphrase-banner.sh round-trips
# the two under `make validate`.
# shellcheck source=lib/passphrase-banner.sh
source "${SCRIPT_DIR}/lib/passphrase-banner.sh"

# Data-USB authenticity gate: host-type decision and verifier-key embedding.
# medium-manifest.sh provides the canonical key fingerprint shared with the
# signer; boot-sign-key.sh decides SIGNING vs PERMISSIVE and bakes (or omits)
# the verifier key. See docs/medium-authenticity-contract.md.
# shellcheck source=lib/medium-manifest.sh
source "${SCRIPT_DIR}/lib/medium-manifest.sh"
# shellcheck source=lib/boot-sign-key.sh
source "${SCRIPT_DIR}/lib/boot-sign-key.sh"

CONFIG="${SCRIPT_DIR}/../config/scanner-host.bu"
CONFIG_DIR="${SCRIPT_DIR}/../config"
WORDLIST="${SCRIPT_DIR}/../config/eff-large-wordlist.txt"
BUILD="$(mktemp -d --tmpdir fc-boot-XXXXXX)"

cleanup() { rm -rf "$BUILD"; }
trap cleanup EXIT

[ -f "$CONFIG" ] \
    || { echo "[!] Butane config not found: $CONFIG"; exit 1; }

[ -f "$WORDLIST" ] \
    || { echo "[!] Wordlist not found: $WORDLIST"; \
         echo "    Download the EFF Long Wordlist from https://www.eff.org/dice"; \
         echo "    and place it at the path above. See THIRD_PARTY_NOTICES.md."; \
         exit 1; }

# Docker is required.
if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    echo "[!] Docker not found."
    echo "    See https://docs.docker.com/engine/install/"
    exit 1
fi
echo "[*] Using container runtime: ${CONTAINER_RUNTIME}"

COREOS_IMAGE="quay.io/coreos/coreos-installer:${COREOS_INSTALLER_TAG}"
COREOS_INSTALLER="${CONTAINER_RUNTIME} run --security-opt label=disable --pull=always --rm -v ${BUILD}:/data -w /data ${COREOS_IMAGE}"

# Decide the host's authenticity posture before any expensive work, so an
# ambiguous invocation (no key and no explicit opt-out, or both at once) fails
# fast rather than after a multi-hundred-MB ISO download. boot_sign_resolve_mode
# prints "signing <path>" or "permissive", or aborts non-zero with guidance.
SIGN_MODE_LINE="$(boot_sign_resolve_mode)" || exit 1
SIGN_MODE="${SIGN_MODE_LINE%% *}"
SIGN_KEY=""
if [ "$SIGN_MODE" = "signing" ]; then
    SIGN_KEY="${SIGN_MODE_LINE#signing }"
    echo "[*] Authenticity gate: SIGNING host (verifier key ${SIGN_KEY})."
else
    echo "[!] Authenticity gate: PERMISSIVE host. This host will NOT verify"
    echo "    data-USB authenticity. Set TROSKEL_SIGN_PUBKEY to build a signing"
    echo "    host. (Proceeding because TROSKEL_ALLOW_UNSIGNED is set.)"
fi

# --- Passphrase generation ------------------------------------------------
# Four-word diceware from the EFF Long Wordlist. ~51.6 bits of entropy
# (log2(7776^4) ≈ 51.7). Joined with hyphens for shell-friendliness.
#
# The plaintext exists only in this script's memory and on the admin's
# terminal at the very end. The hash is substituted into a temp copy of
# the Butane config which the cleanup trap deletes on exit. Nothing is
# written to disk that survives this script.
#
# shuf -n 4 picks 4 random lines uniformly without replacement; cut -f2
# strips the upstream "<dice-roll>\t<word>" prefix.
echo "[*] Generating scanner-user passphrase..."
PASSPHRASE="$(shuf -n 4 "$WORDLIST" | cut -f2 | paste -sd-)"
PASSWORD_HASH="$(openssl passwd -6 "$PASSPHRASE")"

# Substitute the sentinel in a temp copy. Crypt strings contain $ and /,
# so we use | as the sed delimiter rather than the conventional /.
CONFIG_BUILD="${BUILD}/scanner-host.bu"
sed "s|@@SCANNER_PASSWORD_HASH@@|${PASSWORD_HASH}|" "$CONFIG" > "$CONFIG_BUILD"

# Inject or remove the verifier-key storage.files entry in the build copy.
# SIGNING bakes the key at /etc/troskel/sign.pub and copies it into the
# files-dir; PERMISSIVE removes the sentinel so no key is baked. The committed
# config carries only the @@SIGN_PUBKEY_FILE_ENTRY@@ sentinel; Butane never
# sees it because substitution happens here, before --check below.
boot_sign_apply_mode "$SIGN_MODE" "$SIGN_KEY" "$CONFIG_BUILD" "$CONFIG_DIR" \
    || { echo "[!] Failed to apply authenticity-gate key entry."; exit 1; }

echo "[*] Checking Butane config..."
butane --check --files-dir "$CONFIG_DIR" "$CONFIG_BUILD" \
    || { echo "[!] Butane config failed validation."; exit 1; }

echo "[*] Compiling configuration..."
butane --pretty --strict --files-dir "$CONFIG_DIR" "$CONFIG_BUILD" \
    > "${BUILD}/ignition.json"
echo "[+] Ignition JSON written ($(wc -c < "${BUILD}/ignition.json") bytes)"

# Post-compile drift check: the key actually baked into the Ignition must match
# the source key (SIGNING) or be absent (PERMISSIVE). Verifies against the
# produced artefact, not the source, so a stale or mangled key cannot ship. A
# mismatch aborts before the ISO is downloaded or written.
boot_sign_verify_drift "$SIGN_MODE" "$SIGN_KEY" "${BUILD}/ignition.json" \
    || { echo "[!] Authenticity-gate drift check failed; aborting build."; exit 1; }
    
echo "[*] Downloading CoreOS ${COREOS_STREAM} ISO..."
$COREOS_INSTALLER download \
    --stream "${COREOS_STREAM}" \
    --platform metal \
    --format iso \
    --directory /data

ISO="$(ls "${BUILD}"/*.iso | head -1)"
[ -f "$ISO" ] || { echo "[!] ISO download failed — no .iso found in ${BUILD}"; exit 1; }
echo "[+] ISO: $(basename "$ISO")"

echo "[*] Embedding Ignition config into ISO..."
$COREOS_INSTALLER iso ignition embed \
    --ignition-file /data/ignition.json \
    "/data/$(basename "$ISO")"

echo "[*] Writing to ${USB_DEV}..."
echo "    WARNING: all data on ${USB_DEV} will be destroyed."

# Confirmation prompt. Skipped when invoked by the orchestrator
# (troskel-build.sh sets TROSKEL_CONFIRMED=1 after the operator has
# confirmed the device assignment in Phase 1). When invoked directly
# the operator gets the safety prompt as usual.
if [ "${TROSKEL_CONFIRMED:-0}" = "1" ]; then
    echo "    (Confirmation from orchestrator: TROSKEL_CONFIRMED=1)"
else
    read -r -p "    Continue? [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# Release any handles on the device before the dd write and verify the
# release actually happened. This block has a contract with the
# orchestrator: if the device cannot be released, we abort non-zero
# with a diagnostic naming what is holding it. We do NOT swallow the
# failure with `|| true`, because dd against a busy device either
# fails or, worse, succeeds against a stale page-cache view.
#
# A desktop-environment auto-mounter (gnome-volume-monitor, udisks2)
# may have mounted partitions on the USB the moment it was inserted;
# udev may still be probing after a recent insertion.
echo "[*] Releasing device handles..."

# Attempt to unmount any partition on this device. Individual umount
# failures here are not yet fatal; the verification below is.
for PART in "${USB_DEV}"?*; do
    [ -b "$PART" ] || continue
    while MNT="$(findmnt -no TARGET --source "$PART" 2>/dev/null | head -1)"; do
        [ -n "$MNT" ] || break
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || break
    done
done
udevadm settle

# Verify: if anything on this device is still mounted, abort with a
# diagnostic naming the offending mount and (where possible) the
# process holding it.
STILL_MOUNTED="$(findmnt -no TARGET,SOURCE \
    | awk -v dev="$(basename "$USB_DEV")" '$2 ~ dev {print}')"
if [ -n "$STILL_MOUNTED" ]; then
    echo "[!] Cannot release ${USB_DEV} — partitions still mounted:" >&2
    echo "$STILL_MOUNTED" | sed 's/^/      /' >&2
    echo "" >&2
    if command -v fuser >/dev/null 2>&1; then
        echo "    Processes holding mounts on ${USB_DEV}:" >&2
        for PART in "${USB_DEV}"?*; do
            [ -b "$PART" ] || continue
            fuser -vm "$PART" 2>&1 | sed 's/^/      /' >&2 || true
        done
    elif command -v lsof >/dev/null 2>&1; then
        echo "    Processes with open files on ${USB_DEV}:" >&2
        lsof "$USB_DEV"?* 2>/dev/null | sed 's/^/      /' >&2 || true
    fi
    echo "" >&2
    echo "    Close any file managers showing the USB, exit any" >&2
    echo "    terminals cd'd into its mount, or unplug and replug" >&2
    echo "    the device. Then re-run this command." >&2
    exit 1
fi

dd if="$ISO" of="$USB_DEV" bs=4M status=progress
sync

echo ""
echo "[+] Boot USB written to ${USB_DEV}."
echo "    Note down today's date in log."
# CONTRACT (producer side): the passphrase banner below is parsed by
# scripts/troskel-build.sh, which captures this script's stdout (via
# run_step's KEEP_OUT) and runs an awk state machine over it to extract
# the passphrase for its final summary box. The awk keys on three things,
# all of which this banner must keep emitting verbatim:
#   - a line containing the literal string "SCANNER PASSPHRASE" (opens
#     the header);
#   - a line beginning "====" closing the header, after which the first
#     non-empty line is taken to be the passphrase itself (so the
#     passphrase must remain the first non-empty line after that rule,
#     ahead of the explanatory paragraph);
#   - a second line beginning "====" closing the block.
# Changing the title wording, the "====" rules, or the ordering (e.g.
# putting explanatory text before the passphrase) will break extraction.
# The orchestrator fails closed: a missed extraction aborts the build
# with a passphrase-capture error rather than printing an empty summary
# box, so drift is loud, not silent. But it still costs the operator a
# failed run. If you change this banner, update the awk in
# troskel-build.sh and its matching CONTRACT NOTE in the same commit.
echo ""
echo "============================================================"
echo "  SCANNER PASSPHRASE"
echo "============================================================"
echo ""
echo "    ${PASSPHRASE}"
echo ""
echo "  WRITE THIS DOWN NOW. It is not stored anywhere and cannot"
echo "  be recovered once this script exits. You need it to log in"
echo "  as the user 'scanner' on the scanning host."
echo "============================================================"
echo ""