#!/usr/bin/env bash
# scripts/download-loki-yara-rules.sh
# Downloads the YARA Forge Core rule set and the LOKI-RS IOC files,
# staging both into /var/lib/troskel/yara-rules/ for injection into the
# scanner rootfs by build-scanner-image.sh.
#
# This script does not use loki-util. It fetches the upstream archives
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
#     The downloaded archive's hash and the resolved release tag are
#     written to durable files under /var/lib/troskel/ for the
#     build-records generator to consume; together they let a future
#     reader say precisely "this scan used YARA Forge release T with
#     archive SHA-256 H".
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

mkdir -p "$SIGDIR"

# ── YARA Forge ────────────────────────────────────────────────────────────────

# YARA Forge publishes weekly releases. The `latest` redirect resolves
# to the most recent release. We resolve the tag *before* downloading so
# that the resolved value matches what we actually fetch (and so that
# the manifest can record "this build used release T", not "this build
# used whatever latest resolved to roughly around then").
#
# The redirect target looks like:
#   https://github.com/YARAHQ/yara-forge/releases/tag/20260510
# We extract the trailing path component as the resolved tag.
YARA_FORGE_LATEST_URL="https://github.com/YARAHQ/yara-forge/releases/latest"

echo "[*] Resolving YARA Forge latest release tag..."
YARA_FORGE_REDIRECT="$(curl -sI -o /dev/null -w '%{redirect_url}' "$YARA_FORGE_LATEST_URL" \
    || { echo "[!] HEAD request to YARA Forge latest failed."; exit 1; })"
YARA_FORGE_TAG="${YARA_FORGE_REDIRECT##*/tag/}"
# Sanity: if the redirect URL doesn't have a /tag/ component, ${##*/tag/}
# returns the entire redirect URL. Detect this and bail.
case "$YARA_FORGE_TAG" in
    https://*|"")
        echo "[!] Could not resolve YARA Forge release tag from redirect: ${YARA_FORGE_REDIRECT}"
        exit 1
        ;;
esac
echo "[+] YARA Forge release tag: ${YARA_FORGE_TAG}"

# Now download the archive from the resolved tag rather than from /latest/,
# so there is no race between resolution and download.
YARA_FORGE_ZIP="yara-forge-rules-core.zip"
YARA_FORGE_URL="https://github.com/YARAHQ/yara-forge/releases/download/${YARA_FORGE_TAG}/${YARA_FORGE_ZIP}"

echo "[*] Downloading YARA Forge Core rules..."
curl -fsSL --location "$YARA_FORGE_URL" \
    -o "${TMPDIR_RULES}/${YARA_FORGE_ZIP}" \
    || { echo "[!] Download failed — check internet connectivity."; exit 1; }

# Record the SHA-256 of what we downloaded. This is a receipt, not a
# verification: there is no upstream-published value to compare against.
# Written to a durable file so the build-records generator can read it.
YARA_FORGE_DOWNLOADED_SHA="$(sha256sum "${TMPDIR_RULES}/${YARA_FORGE_ZIP}" | awk '{print $1}')"
echo "[i] YARA Forge archive SHA-256: ${YARA_FORGE_DOWNLOADED_SHA}"

# Durable artefacts for the generator. Written atomically via tmp+mv so
# a script interruption can't leave half-written values around.
echo "$YARA_FORGE_TAG" > "${SIGDIR}/yara-forge-resolved-tag.new"
mv "${SIGDIR}/yara-forge-resolved-tag.new" "${SIGDIR}/yara-forge-resolved-tag"
echo "$YARA_FORGE_DOWNLOADED_SHA" > "${SIGDIR}/yara-forge-archive-sha256.new"
mv "${SIGDIR}/yara-forge-archive-sha256.new" "${SIGDIR}/yara-forge-archive-sha256"

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
#   signatures/yara/      - .yar rule files
#   signatures/iocs/      - hash-iocs.txt, filename-iocs.txt, c2-iocs.txt
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

# Normalise the regex dialect of the IOC files for LOKI-RS.
#
# signature-base IOCs are authored for the Python LOKI, whose `re` module
# accepts `{,N}` as a synonym for `{0,N}` (omitted lower bound = zero). The
# Rust `regex` crate that LOKI-RS uses rejects `{,N}`: the lower bound is
# mandatory. Upstream patterns like `[^\\]{,20}` therefore log a parse error
# in LOKI-RS and that IOC line is silently skipped, so we are not just looking
# at noise, we are losing detection coverage for every pattern that uses the
# omitted-lower-bound form. Rewriting `{,N}` to `{0,N}` is a semantics-
# preserving transform (Python treats them as identical) that makes the
# pattern parse under Rust.
#
# Scope of the rewrite, deliberately narrow to avoid corrupting patterns:
#   - Only the regex-bearing files (filename-iocs.txt, c2-iocs.txt). NOT
#     hash-iocs.txt: it holds hashes, never regexes, so any `{,` there would be
#     in a comment or path and must not be touched.
#   - Only the exact quantifier shape: a brace, a comma, one or more digits, a
#     brace (`{,[0-9]+}`). This leaves every other use of `{` alone, including
#     `{M,N}` and `{N}` quantifiers (already valid) and any literal brace that
#     is not immediately followed by a comma and digits.
#
# CONTRACT (producer side): this transform is applied to the IOC files that
# land in ${RULES_OUT}/iocs and are consumed by LOKI-RS at scan time. If
# LOKI-RS ever moves to a regex engine that accepts `{,N}` (or upstream
# normalises the patterns), this step becomes a harmless no-op and can be
# removed. tests/test-loki-ioc-sanitise.sh guards the transform's correctness.
sanitise_ioc_regex() {  # sanitise_ioc_regex <file>  rewrites {,N} -> {0,N} in place
    local f="$1"
    sed -i -E 's/\{,([0-9]+)\}/{0,\1}/g' "$f"
}

IOC_REWRITE_TOTAL=0
for FILE in filename-iocs.txt c2-iocs.txt; do
    TARGET="${RULES_OUT}/iocs/${FILE}"
    [ -f "$TARGET" ] || continue
    # Count the occurrences we are about to fix, for the post-condition.
    BEFORE="$( { grep -oE '\{,[0-9]+\}' "$TARGET" || true; } | wc -l | tr -d ' ')"
    sanitise_ioc_regex "$TARGET"
    # Post-condition: re-read the file and confirm NO `{,N}` quantifier remains.
    # A non-zero count here means the rewrite missed a form it should have
    # caught (e.g. an unanticipated variant), which would leave LOKI-RS parse
    # errors in place. Fail loudly rather than ship a file we claimed to fix.
    AFTER="$( { grep -oE '\{,[0-9]+\}' "$TARGET" || true; } | wc -l | tr -d ' ')"
    if [ "$AFTER" -ne 0 ]; then
        echo "[!] IOC regex sanitisation incomplete: ${AFTER} '{,N}' quantifier(s)" >&2
        echo "    remain in ${FILE} after rewrite. LOKI-RS will reject these." >&2
        exit 1
    fi
    [ "$BEFORE" -gt 0 ] && echo "[+] Normalised ${BEFORE} '{,N}' quantifier(s) in ${FILE} for LOKI-RS"
    IOC_REWRITE_TOTAL=$((IOC_REWRITE_TOTAL + BEFORE))
done
echo "[+] IOC regex dialect normalised (${IOC_REWRITE_TOTAL} pattern(s) rewritten for the Rust regex engine)"

date -u --iso-8601=seconds > "${SIGDIR}/yara-rules-date"

RULE_COUNT="$(find "${RULES_OUT}/yara" -type f \( -name '*.yar' -o -name '*.yara' \) | wc -l)"
echo "[+] YARA rules ready: ${RULE_COUNT} rule file(s) in ${RULES_OUT}"
echo "[+] Refresh date: $(cat "${SIGDIR}/yara-rules-date")"