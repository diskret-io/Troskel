#!/usr/bin/env bash
# scripts/download-kernel.sh
# Downloads a Firecracker-compatible guest kernel (vmlinux) from the official
# AWS Firecracker release assets. Run on the build station as part of run-update.sh.
#
# The kernel must match the Firecracker binary's CI version — newer Firecracker
# CI kernels drop virtio-mmio support, so a v1.7 binary paired with a v1.15
# kernel produces a guest that can't see its drives. We read FC_VERSION from
# config/versions.env so the two stay coupled.
#
# Integrity strategy: record-at-first-download.
# The Firecracker CI S3 bucket does not publish per-asset SHA-256 sidecars,
# so the kernel uses a record-at-first-download pattern. Two values in
# config/versions.env participate:
#
#   KERNEL_RESOLVED   The resolved kernel filename under the CI series
#                     (e.g. vmlinux-6.1.141). Recorded on first build,
#                     pinned thereafter.
#   KERNEL_SHA256     The SHA-256 of that kernel file. Recorded on first
#                     build, verified thereafter.
#
# First run (both empty): resolve "latest under CI series", download, hash,
# write both values back to versions.env. Subsequent runs (both populated):
# construct the URL from the recorded filename, download, verify against
# the recorded hash, fail loudly on mismatch. To intentionally bump to a
# newer kernel, edit versions.env: blank both values and re-run; the next
# build will discover-and-record fresh.
#
# Usage: sudo bash scripts/download-kernel.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSIONS_FILE="${SCRIPT_DIR}/../config/versions.env"
# shellcheck source=../config/versions.env
source "$VERSIONS_FILE"

SIGDIR="/var/lib/troskel"
KERNEL_OUT="${SIGDIR}/vmlinux"
ARCH="$(uname -m)"

[ -n "${FC_VERSION:-}" ] \
    || { echo "[!] FC_VERSION not set — check config/versions.env"; exit 1; }
CI_VERSION="${FC_VERSION%.*}"   # v1.7.0 -> v1.7

# ── versions.env write-back helper ────────────────────────────────────────────
# Replaces a `KEY=""` line in versions.env with `KEY="VALUE"`, preserving the
# original file ownership (versions.env is committed to the repo; running
# this script as root via sudo must not chown the file to root).
#
# Only updates if the current on-disk value is the empty string. This is
# deliberate: if the value is already populated and we somehow reach this
# function, that is a logic bug, not a "should overwrite" case. The match
# pattern is anchored on `KEY=""` so a populated line cannot be silently
# overwritten by a re-run.
record_in_versions_env() {
    local KEY="$1"
    local VALUE="$2"
    local OWNER
    OWNER="$(stat -c '%U:%G' "$VERSIONS_FILE")"
    if ! grep -qE "^${KEY}=\"\"\$" "$VERSIONS_FILE"; then
        echo "[!] Refusing to overwrite ${KEY} in versions.env — value is not empty."
        echo "    To bump the recording deliberately, blank both KERNEL_RESOLVED"
        echo "    and KERNEL_SHA256 in config/versions.env and re-run."
        return 1
    fi
    # Use a temp file + mv rather than sed -i to avoid partial writes if
    # the script is interrupted mid-edit. The escape on VALUE handles any
    # forward slashes; the values we write here (filenames and hex hashes)
    # contain none, but the defensive escape is cheap insurance.
    local ESCAPED_VALUE
    ESCAPED_VALUE="$(printf '%s' "$VALUE" | sed 's/[\/&]/\\&/g')"
    sed "s/^${KEY}=\"\"\$/${KEY}=\"${ESCAPED_VALUE}\"/" "$VERSIONS_FILE" \
        > "${VERSIONS_FILE}.new"
    chown "$OWNER" "${VERSIONS_FILE}.new"
    mv "${VERSIONS_FILE}.new" "$VERSIONS_FILE"
    echo "[+] Recorded ${KEY} in config/versions.env"
}

# ── First-run discovery vs subsequent verification ────────────────────────────
mkdir -p "$SIGDIR"

echo "[*] Firecracker binary version: ${FC_VERSION}"
echo "[*] Matching guest kernel CI version: ${CI_VERSION}"

if [ -z "${KERNEL_RESOLVED:-}" ] && [ -z "${KERNEL_SHA256:-}" ]; then
    MODE="discover"
    echo "[*] First-run discovery: resolving latest kernel under ${CI_VERSION}..."
elif [ -n "${KERNEL_RESOLVED:-}" ] && [ -n "${KERNEL_SHA256:-}" ]; then
    MODE="verify"
    echo "[*] Verifying recorded kernel: ${KERNEL_RESOLVED}"
else
    echo "[!] Inconsistent kernel pinning in config/versions.env:"
    echo "    KERNEL_RESOLVED='${KERNEL_RESOLVED:-}'"
    echo "    KERNEL_SHA256='${KERNEL_SHA256:-}'"
    echo "    Either both must be empty (discover-and-record) or both must"
    echo "    be populated (verify). To re-record, blank both values."
    exit 1
fi

# ── Resolve the kernel URL ────────────────────────────────────────────────────
if [ "$MODE" = "discover" ]; then
    KERNEL_KEY=$(curl -fsSL \
        "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-&list-type=2" \
        | grep -oP "(?<=<Key>)(firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
        | sort -V | tail -1)
    [ -n "$KERNEL_KEY" ] \
        || { echo "[!] Could not resolve kernel key — check connectivity or that ${CI_VERSION} kernels exist."; exit 1; }
    KERNEL_FILENAME="$(basename "$KERNEL_KEY")"
else
    # Verify mode: construct the URL from the recorded filename.
    KERNEL_FILENAME="$KERNEL_RESOLVED"
    KERNEL_KEY="firecracker-ci/${CI_VERSION}/${ARCH}/${KERNEL_FILENAME}"
fi

KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/${KERNEL_KEY}"

# ── Download ──────────────────────────────────────────────────────────────────
echo "[*] Downloading guest kernel: ${KERNEL_FILENAME}..."
wget -q --show-progress \
    -O "${KERNEL_OUT}.tmp" \
    "$KERNEL_URL" \
    || { echo "[!] Kernel download failed — check internet connectivity."; rm -f "${KERNEL_OUT}.tmp"; exit 1; }

# ── Verify or record ──────────────────────────────────────────────────────────
DOWNLOADED_SHA="$(sha256sum "${KERNEL_OUT}.tmp" | awk '{print $1}')"

if [ "$MODE" = "verify" ]; then
    if [ "$DOWNLOADED_SHA" != "$KERNEL_SHA256" ]; then
        rm -f "${KERNEL_OUT}.tmp"
        echo ""
        echo "[!] SHA-256 mismatch for guest kernel ${KERNEL_FILENAME}"
        echo "    Expected : ${KERNEL_SHA256}"
        echo "    Got      : ${DOWNLOADED_SHA}"
        echo ""
        echo "    The downloaded kernel does not match the value recorded in"
        echo "    config/versions.env. Possible causes:"
        echo "      - The Firecracker CI S3 bucket re-published this asset"
        echo "        (rare but possible if the CI rebuild was triggered)."
        echo "      - The download was corrupted in transit (retry)."
        echo "      - A man-in-the-middle has substituted a tampered kernel."
        echo ""
        echo "    To accept a deliberate upstream change, blank KERNEL_RESOLVED"
        echo "    and KERNEL_SHA256 in config/versions.env and re-run; the next"
        echo "    build will discover-and-record fresh values. Do not do this"
        echo "    without first independently confirming the upstream change."
        echo ""
        exit 1
    fi
    echo "[+] Kernel verified against recorded SHA-256"
else
    # Discover mode: record both values.
    record_in_versions_env "KERNEL_RESOLVED" "$KERNEL_FILENAME"
    record_in_versions_env "KERNEL_SHA256" "$DOWNLOADED_SHA"
    echo "[+] First-run discovery complete:"
    echo "    KERNEL_RESOLVED = ${KERNEL_FILENAME}"
    echo "    KERNEL_SHA256   = ${DOWNLOADED_SHA}"
    echo ""
    echo "    These values are now pinned in config/versions.env. Subsequent"
    echo "    builds will verify against them rather than re-resolving 'latest'."
fi

# ── Install ───────────────────────────────────────────────────────────────────
mv "${KERNEL_OUT}.tmp" "$KERNEL_OUT"
chmod 644 "$KERNEL_OUT"

KSIZE="$(ls -lh "$KERNEL_OUT" | awk '{print $5}')"
echo "[+] Kernel ready: ${KERNEL_OUT} (${KSIZE})"