#!/usr/bin/env bash
# scripts/download-loki-yara-rules.sh
# Downloads the YARA Forge Core rule set and the LOKI-RS IOC files,
# staging both into /var/lib/troskel/yara-rules/ for injection into the
# scanner rootfs by build-scanner-image.sh.
#
# This script does not use loki-util — it fetches the upstream archives
# directly, which works on any system with curl and unzip regardless of
# whether loki-util can run (e.g. NixOS).
#
# Integrity strategy:
#   - YARA Forge publishes no SHA-256 sidecars or signatures alongside
#     its release assets. The only integrity guarantee available at
#     download time is TLS to GitHub. This is acceptable because YARA
#     Forge is a DETECTION input (see config/versions.env), not a
#     SOFTWARE component: the operational requirement is reproducibility
#     of a given build, not protection against upstream substitution.
#     The downloaded archive's hash is recorded in the per-build
#     manifest (planned — see docs/SECURITY.md), so that a scan can be
#     reproduced later against the same byte-exact rule set.
#   - The IOC base (signature-base upstream) is fetched from a tagged
#     release (pinned in versions.env as LOKI_IOC_BASE_VERSION), not
#     from the rolling master branch. The tag is immutable on the
#     upstream's side, so reproducibility is guaranteed by version
#     pinning; per-file SHA-256s are not recorded because the marginal
#     protection over TLS-from-GitHub is small for small text files
#     served from a tagged tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../config/versions.env
source "${SCRIPT_DIR}/../config/versions.env"

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

SIGDIR="/var/lib/troskel"
RULES_OUT="${SIGDIR}/yara-rules"
TMPDIR_RULES="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR_RULES"; }
trap cleanup EXIT

# ── YARA Forge ────────────────────────────────────────────────────────────────

# YARA Forge publishes weekly releases. The `latest` redirect resolves
# to the most recent release automatically.
YARA_FORGE_BASE="https://github.com/YARAHQ/yara-forge/releases/latest/download"
YARA_FORGE_ZIP="yara-forge-rules-core.zip"
YARA_FORGE_URL="${YARA_FORGE_BASE}/${YARA_FORGE_ZIP}"

echo "[*] Downloading YARA Forge Core rules..."
curl -fsSL --location "$YARA_FORGE_URL" \
    -o "${TMPDIR_RULES}/${YARA_FORGE_ZIP}" \
    || { echo "[!] Download failed — check internet connectivity."; exit 1; }

# Record the SHA-256 of what we downloaded. This is a receipt, not a
# verification: there is no upstream-published value to compare against.
# The hash exists so it can be propagated into the per-build manifest
# for reproducibility. For now, log it visibly so it is captured in
# whatever build log the operator keeps.
YARA_FORGE_DOWNLOADED_SHA="$(sha256sum "${TMPDIR_RULES}/${YARA_FORGE_ZIP}" | awk '{print $1}')"
echo "[i] YARA Forge archive SHA-256: ${YARA_FORGE_DOWNLOADED_SHA}"

echo "[*] Extracting rules..."
unzip -q "${TMPDIR_RULES}/${YARA_FORGE_ZIP}" \
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
mkdir -p "${RULES_OUT}/yara"
mkdir -p "${RULES_OUT}/iocs"

# Copy .yar files into signatures/yara/ — LOKI-RS reads from this path.
find "${TMPDIR_RULES}/extracted" \( -name '*.yar' -o -name '*.yara' \) | while read -r FILE; do
    cp "$FILE" "${RULES_OUT}/yara/$(basename "$FILE")"
done

# ── LOKI-RS IOC base ──────────────────────────────────────────────────────────

# Fetched from a pinned tag rather than master. The tag is set in
# versions.env (LOKI_IOC_BASE_VERSION) and bumped on each detection
# refresh. Tag immutability provides the reproducibility guarantee:
# a scan run today can be re-run later against the same IOC set by
# checking out the same LOKI_IOC_BASE_VERSION.
echo "[*] Downloading IOC files from LOKI IOC base ${LOKI_IOC_BASE_VERSION}..."
IOC_BASE_URL="https://raw.githubusercontent.com/Neo23x0/signature-base/refs/tags/${LOKI_IOC_BASE_VERSION}/iocs"
for FILE in hash-iocs.txt filename-iocs.txt c2-iocs.txt; do
    curl -fsSL "${IOC_BASE_URL}/${FILE}" -o "${RULES_OUT}/iocs/${FILE}" \
        || { echo "[!] Failed to download ${FILE} from LOKI IOC base ${LOKI_IOC_BASE_VERSION}."; exit 1; }
done
echo "[+] IOC files downloaded from LOKI IOC base ${LOKI_IOC_BASE_VERSION}"

date -u --iso-8601=seconds > "${SIGDIR}/yara-rules-date"

RULE_COUNT="$(find "${RULES_OUT}/yara" -type f \( -name '*.yar' -o -name '*.yara' \) | wc -l)"
echo "[+] YARA rules ready: ${RULE_COUNT} rule file(s) in ${RULES_OUT}"
echo "[+] Refresh date: $(cat "${SIGDIR}/yara-rules-date")"