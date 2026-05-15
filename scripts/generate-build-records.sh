#!/usr/bin/env bash
# scripts/generate-build-records.sh
# Produces two build records from the post-build state of the build station:
#
#   - SBOM.json at the repository root (CycloneDX 1.6 bill of materials).
#   - /var/lib/troskel/build-manifest.json (per-build manifest, see
#     docs/roadmap/build-manifest.md for the full schema).
#
# A single generator produces both because they read overlapping state
# (versions.env, recorded SHA-256s, freshness dates, captured-at-download
# values under /var/lib/troskel/). Splitting them into two scripts would
# introduce a coordination problem — did both run, did both see the same
# state — that combining them removes.
#
# Run from the project root, as root, as the final step of run-update.sh
# after every download and build step has completed.
#
# Usage: sudo bash scripts/generate-build-records.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[!] Must be run as root."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSIONS_FILE="${PROJECT_ROOT}/config/versions.env"
SIGDIR="/var/lib/troskel"
SBOM_OUT="${PROJECT_ROOT}/SBOM.json"
MANIFEST_OUT="${SIGDIR}/build-manifest.json"

# shellcheck source=../config/versions.env
source "$VERSIONS_FILE"

# ── Static metadata ───────────────────────────────────────────────────────────
# Per-emission values: a fresh serial number and timestamp every run.
SERIAL="urn:uuid:$(uuidgen)"
TIMESTAMP="$(date -u --iso-8601=seconds)"

# ── Build environment ─────────────────────────────────────────────────────────
TROSKEL_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
# `git status --porcelain` returns the empty string iff the working tree
# is clean. Capture that as a boolean for the manifest.
if [ -z "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]; then
    TROSKEL_DIRTY="false"
else
    TROSKEL_DIRTY="true"
fi
BUILD_HOST_KERNEL="$(uname -sr)"

# ── Detection-input state captured at download time ───────────────────────────
# These files are written by the corresponding download scripts. The
# generator treats their absence gracefully — missing values surface as
# "unknown" rather than failing the entire emission.
read_or_unknown() {
    if [ -f "$1" ]; then cat "$1"; else echo "unknown"; fi
}

SIG_DATE="$(read_or_unknown "${SIGDIR}/signature-date")"
YARA_DATE="$(read_or_unknown "${SIGDIR}/yara-rules-date")"
YARA_FORGE_TAG="$(read_or_unknown "${SIGDIR}/yara-forge-resolved-tag")"
YARA_FORGE_SHA="$(read_or_unknown "${SIGDIR}/yara-forge-archive-sha256")"

# ── ClamAV signature versions and hashes via sigtool ──────────────────────────
# sigtool is part of the `clamav` package. prepare-build-machine.sh
# installs `clamav-freshclam`; the parent `clamav` package brings
# sigtool along when apt resolves dependencies.
#
# `sigtool --info <file.cvd>` prints a header block including:
#     Build version: 27234
#     MD5: <hex>
# We extract Build version for the manifest. The .cvd file itself has
# a SHA-256 that we compute separately (sigtool reports MD5, not SHA-256).
#
# Output format for each .cvd in the manifest:
#     {"name": "main.cvd", "version": 62, "sha256": "<hex>"}
#
# Stored in two parallel arrays for the heredoc emission.
CLAM_CVDS_JSON=""
if command -v sigtool >/dev/null 2>&1 && [ -d "${SIGDIR}/clamav-db" ]; then
    for CVD in main.cvd daily.cvd bytecode.cvd; do
        CVD_PATH="${SIGDIR}/clamav-db/${CVD}"
        [ -f "$CVD_PATH" ] || continue
        CVD_VERSION="$(sigtool --info "$CVD_PATH" 2>/dev/null \
            | awk -F': ' '/^Build version:/ {print $2; exit}')"
        CVD_SHA="$(sha256sum "$CVD_PATH" | awk '{print $1}')"
        # Append to the JSON array fragment. Comma handling done at emit time.
        ENTRY="        {\"name\": \"${CVD}\", \"version\": ${CVD_VERSION:-0}, \"sha256\": \"${CVD_SHA}\"}"
        if [ -z "$CLAM_CVDS_JSON" ]; then
            CLAM_CVDS_JSON="$ENTRY"
        else
            CLAM_CVDS_JSON="${CLAM_CVDS_JSON},
${ENTRY}"
        fi
    done
fi
# Default to an empty array if no .cvds were found.
[ -n "$CLAM_CVDS_JSON" ] || CLAM_CVDS_JSON="        "

# ── Repo-root ownership preservation ──────────────────────────────────────────
# Same pattern as download-kernel.sh: capture the owner of SBOM.json (or
# its containing directory if the file doesn't yet exist) by numeric ID,
# write the new file, restore the ownership. Avoids polluting the
# operator's repo with root-owned files when run via sudo.
if [ -f "$SBOM_OUT" ]; then
    SBOM_OWNER="$(stat -c '%u:%g' "$SBOM_OUT")"
else
    SBOM_OWNER="$(stat -c '%u:%g' "$PROJECT_ROOT")"
fi

# ── SBOM emission ─────────────────────────────────────────────────────────────
# CycloneDX 1.6. The structure is a single heredoc — no templating
# engine, no jq dependency. If this grows hard to read, the right
# response is to split into per-component partial heredocs assembled by
# cat, not to introduce a new dependency.
#
# Pinned components carry their recorded SHA-256 in a hashes block.
# Floating components carry no hashes block (would lie about what was
# verified) but do carry verification-method and pin-category properties
# so an auditor can see how trust was established without reading the
# script.
echo "[*] Emitting SBOM..."
cat > "${SBOM_OUT}.new" <<JSON
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "version": 1,
  "serialNumber": "${SERIAL}",
  "metadata": {
    "timestamp": "${TIMESTAMP}",
    "tools": {
      "components": [
        {
          "type": "application",
          "name": "troskel-build-records-generator",
          "version": "0.9.0",
          "vendor": "troskel-project",
          "description": "Generates SBOM.json and build-manifest.json from versions.env and build-station state. See scripts/generate-build-records.sh."
        }
      ]
    },
    "component": {
      "type": "application",
      "name": "troskel",
      "version": "0.9.0",
      "description": "Air-gapped file-crossing scanner",
      "supplier": {"name": "Diskret Team"},
      "licenses": [{"license": {"id": "MIT"}}],
      "purl": "pkg:generic/troskel@0.9.0",
      "properties": [
        {"name": "project-type", "value": "security-tool"},
        {"name": "deployment-model", "value": "air-gapped"},
        {"name": "troskel-commit", "value": "${TROSKEL_COMMIT}"},
        {"name": "troskel-dirty", "value": "${TROSKEL_DIRTY}"}
      ]
    },
    "manufacture": {"name": "Diskret"},
    "authors": [{"name": "Troskel Team"}]
  },
  "components": [
    {
      "type": "operating-system",
      "name": "fedora-coreos",
      "version": "stable-stream",
      "description": "CoreOS variant for scanning host. Tracks the 'stable' stream; the resolved version is not captured by this generator (see docs/roadmap/build-manifest.md open questions). ISO verified by coreos-installer against the Fedora signing key.",
      "supplier": {"name": "Fedora Project"},
      "licenses": [{"license": {"id": "GPL-2.0-only"}}],
      "purl": "pkg:generic/fedora-coreos@stable",
      "externalReferences": [{"url": "https://fedoraproject.org/coreos", "type": "website"}],
      "properties": [
        {"name": "role", "value": "host-os"},
        {"name": "boot-mode", "value": "live-ram"},
        {"name": "verification-method", "value": "upstream-signed"},
        {"name": "pin-category", "value": "FLOATING"}
      ]
    },
    {
      "type": "container",
      "name": "coreos-installer",
      "version": "${COREOS_INSTALLER_TAG}",
      "description": "CoreOS installation tool. Tracks the 'release' tag; pinning by digest is tracked as planned hardening.",
      "supplier": {"name": "Fedora Project"},
      "licenses": [{"license": {"id": "Apache-2.0"}}],
      "purl": "pkg:generic/coreos-installer@${COREOS_INSTALLER_TAG}",
      "externalReferences": [{"url": "https://quay.io/coreos/coreos-installer", "type": "registry"}],
      "properties": [
        {"name": "verification-method", "value": "tls-only"},
        {"name": "pin-category", "value": "FLOATING"}
      ]
    },
    {
      "type": "library",
      "name": "firecracker",
      "version": "${FC_VERSION}",
      "description": "MicroVM hypervisor for isolated scanning",
      "supplier": {"name": "Amazon Web Services"},
      "licenses": [{"license": {"id": "Apache-2.0"}}],
      "purl": "pkg:github/firecracker-microvm/firecracker@${FC_VERSION}",
      "externalReferences": [
        {"url": "https://github.com/firecracker-microvm/firecracker", "type": "website"},
        {"url": "https://firecracker-microvm.github.io", "type": "documentation"}
      ],
      "hashes": [{"alg": "SHA-256", "content": "${FC_SHA256}"}],
      "properties": [
        {"name": "security-role", "value": "hypervisor-boundary"},
        {"name": "attack-surface", "value": "minimal"},
        {"name": "verification-method", "value": "sidecar"},
        {"name": "pin-category", "value": "PINNED"}
      ]
    },
    {
      "type": "library",
      "name": "clamav",
      "version": "${DEBIAN_RELEASE}-default",
      "description": "Signature-based antivirus engine. Installed via debootstrap from the pinned Debian release.",
      "supplier": {"name": "ClamAV Team"},
      "licenses": [{"license": {"id": "GPL-2.0-only"}}],
      "purl": "pkg:debian/clamav@${DEBIAN_RELEASE}",
      "externalReferences": [{"url": "https://www.clamav.net", "type": "website"}],
      "properties": [
        {"name": "detection-type", "value": "signature-based"},
        {"name": "coverage", "value": "commodity-malware"},
        {"name": "verification-method", "value": "apt-via-debian-release"},
        {"name": "pin-category", "value": "DERIVED"}
      ]
    },
    {
      "type": "file",
      "name": "clamav-signatures",
      "version": "dynamic",
      "description": "ClamAV signature database. Updated regularly by freshclam; resolved .cvd version numbers and hashes captured in the per-build manifest at /var/lib/troskel/build-manifest.json.",
      "supplier": {"name": "ClamAV Team"},
      "licenses": [{"license": {"id": "GPL-2.0-only"}}],
      "purl": "pkg:generic/clamav-signatures@dynamic",
      "properties": [
        {"name": "update-frequency", "value": "daily"},
        {"name": "freshness-gate", "value": "30-days"},
        {"name": "downloaded-at", "value": "${SIG_DATE}"},
        {"name": "verification-method", "value": "freshclam-embedded-keys"},
        {"name": "pin-category", "value": "FLOATING"}
      ]
    },
    {
      "type": "file",
      "name": "eff-large-wordlist",
      "version": "2016-07-18",
      "description": "EFF Long Wordlist for diceware passphrase generation",
      "supplier": {"name": "Electronic Frontier Foundation"},
      "licenses": [{"license": {"id": "CC-BY-3.0"}}],
      "purl": "pkg:generic/eff-large-wordlist@2016-07-18",
      "externalReferences": [{"url": "https://www.eff.org/dice", "type": "website"}],
      "hashes": [{"alg": "SHA-256", "content": "${WORDLIST_SHA256}"}],
      "properties": [
        {"name": "role", "value": "passphrase-generation"},
        {"name": "vendored-via", "value": "scripts/download-wordlist.sh"},
        {"name": "verification-method", "value": "recorded"},
        {"name": "pin-category", "value": "PINNED"}
      ]
    },
    {
      "type": "library",
      "name": "loki-rs",
      "version": "${LOKI_VERSION}",
      "description": "YARA-rule and IOC scanner",
      "supplier": {"name": "Neo23x0"},
      "licenses": [{"license": {"id": "GPL-3.0-only"}}],
      "purl": "pkg:github/Neo23x0/Loki-RS@${LOKI_VERSION}",
      "externalReferences": [{"url": "https://github.com/Neo23x0/Loki-RS", "type": "website"}],
      "hashes": [{"alg": "SHA-256", "content": "${LOKI_SHA256}"}],
      "properties": [
        {"name": "detection-type", "value": "yara-rules"},
        {"name": "coverage", "value": "apt-artifacts,hack-tools,web-shells"},
        {"name": "verification-method", "value": "sidecar"},
        {"name": "pin-category", "value": "PINNED"}
      ]
    },
    {
      "type": "file",
      "name": "yara-forge-core-rules",
      "version": "${YARA_FORGE_TAG}",
      "description": "YARA Forge Core rule set for LOKI-RS. Floats with weekly upstream releases; the resolved tag and archive SHA-256 are captured here per build for reproducibility.",
      "supplier": {"name": "YARA Forge"},
      "purl": "pkg:generic/yara-forge-core@${YARA_FORGE_TAG}",
      "externalReferences": [{"url": "https://github.com/YARAHQ/yara-forge", "type": "website"}],
      "hashes": [{"alg": "SHA-256", "content": "${YARA_FORGE_SHA}"}],
      "properties": [
        {"name": "update-method", "value": "scripts/download-loki-yara-rules.sh"},
        {"name": "curated", "value": "true"},
        {"name": "downloaded-at", "value": "${YARA_DATE}"},
        {"name": "verification-method", "value": "tls-only"},
        {"name": "pin-category", "value": "FLOATING"}
      ]
    },
    {
      "type": "file",
      "name": "loki-ioc-base",
      "version": "${LOKI_IOC_BASE_VERSION}",
      "description": "IOC inputs (hash, filename, c2) used by LOKI-RS. Supplied upstream by github.com/Neo23x0/signature-base; pinned to an immutable release tag.",
      "supplier": {"name": "Neo23x0"},
      "licenses": [{"license": {"id": "CC-BY-NC-4.0"}}],
      "purl": "pkg:github/Neo23x0/signature-base@${LOKI_IOC_BASE_VERSION}",
      "externalReferences": [{"url": "https://github.com/Neo23x0/signature-base", "type": "website"}],
      "properties": [
        {"name": "verification-method", "value": "tag-pinning"},
        {"name": "pin-category", "value": "PINNED-TAG"}
      ]
    },
    {
      "type": "operating-system",
      "name": "debian",
      "version": "${DEBIAN_RELEASE}",
      "description": "Guest OS for scanner microVM",
      "supplier": {"name": "Debian Project"},
      "licenses": [{"license": {"id": "GPL-2.0-only"}}],
      "purl": "pkg:generic/debian@${DEBIAN_RELEASE}",
      "externalReferences": [{"url": "https://www.debian.org", "type": "website"}],
      "properties": [
        {"name": "role", "value": "guest-os"},
        {"name": "variant", "value": "minbase"},
        {"name": "verification-method", "value": "debootstrap-via-apt-keys"},
        {"name": "pin-category", "value": "PINNED"}
      ]
    },
    {
      "type": "library",
      "name": "butane",
      "version": "${BUTANE_VERSION}",
      "description": "CoreOS Butane config compiler (Butane to Ignition)",
      "supplier": {"name": "Fedora Project"},
      "licenses": [{"license": {"id": "BSD-2-Clause"}}],
      "purl": "pkg:github/coreos/butane@${BUTANE_VERSION}",
      "externalReferences": [{"url": "https://github.com/coreos/butane", "type": "website"}],
      "hashes": [{"alg": "SHA-256", "content": "${BUTANE_SHA256}"}],
      "properties": [
        {"name": "verification-method", "value": "gpg-bootstrap"},
        {"name": "pin-category", "value": "PINNED"}
      ]
    },
    {
      "type": "library",
      "name": "busybox",
      "version": "${DEBIAN_RELEASE}-default",
      "description": "Minimal Unix utilities for guest. Installed via debootstrap from the pinned Debian release.",
      "supplier": {"name": "BusyBox Team"},
      "licenses": [{"license": {"id": "GPL-2.0-only"}}],
      "purl": "pkg:debian/busybox@${DEBIAN_RELEASE}",
      "properties": [
        {"name": "variant", "value": "static"},
        {"name": "verification-method", "value": "apt-via-debian-release"},
        {"name": "pin-category", "value": "DERIVED"}
      ]
    },
    {
      "type": "firmware",
      "name": "vmlinux",
      "version": "${KERNEL_RESOLVED:-record-at-first-download}",
      "description": "Firecracker-compatible guest kernel. Pinned to the resolved filename within the FC_VERSION CI series via the record-at-first-download pattern.",
      "supplier": {"name": "AWS Firecracker"},
      "licenses": [{"license": {"id": "GPL-2.0-only"}}],
      "purl": "pkg:generic/firecracker-vmlinux@${KERNEL_RESOLVED:-unknown}",
      "externalReferences": [{"url": "https://github.com/firecracker-microvm/firecracker", "type": "website"}],
      "hashes": [{"alg": "SHA-256", "content": "${KERNEL_SHA256:-unknown}"}],
      "properties": [
        {"name": "compatibility", "value": "firecracker-${FC_VERSION%.*}"},
        {"name": "interface", "value": "virtio-mmio"},
        {"name": "verification-method", "value": "record-at-first-download"},
        {"name": "pin-category", "value": "DERIVED"}
      ]
    }
  ],
  "dependencies": [
    {
      "ref": "pkg:generic/troskel@0.9.0",
      "dependsOn": [
        "pkg:generic/fedora-coreos@stable",
        "pkg:github/firecracker-microvm/firecracker@${FC_VERSION}",
        "pkg:debian/clamav@${DEBIAN_RELEASE}",
        "pkg:github/Neo23x0/Loki-RS@${LOKI_VERSION}",
        "pkg:generic/debian@${DEBIAN_RELEASE}"
      ]
    },
    {
      "ref": "pkg:github/firecracker-microvm/firecracker@${FC_VERSION}",
      "dependsOn": ["pkg:generic/firecracker-vmlinux@${KERNEL_RESOLVED:-unknown}"]
    },
    {
      "ref": "pkg:debian/clamav@${DEBIAN_RELEASE}",
      "dependsOn": ["pkg:generic/clamav-signatures@dynamic"]
    },
    {
      "ref": "pkg:github/Neo23x0/Loki-RS@${LOKI_VERSION}",
      "dependsOn": [
        "pkg:generic/yara-forge-core@${YARA_FORGE_TAG}",
        "pkg:github/Neo23x0/signature-base@${LOKI_IOC_BASE_VERSION}"
      ]
    },
    {
      "ref": "pkg:generic/fedora-coreos@stable",
      "dependsOn": [
        "pkg:github/coreos/butane@${BUTANE_VERSION}",
        "pkg:generic/coreos-installer@${COREOS_INSTALLER_TAG}"
      ]
    }
  ],
  "vulnerabilities": [],
  "compositions": [
    {
      "aggregate": "complete",
      "assemblies": ["pkg:generic/troskel@0.9.0"],
      "note": "Generated from versions.env and build-station state by scripts/generate-build-records.sh."
    }
  ],
  "properties": [
    {"name": "architecture-pattern", "value": "usb-air-gapped"},
    {"name": "detection-engines", "value": "clamav,loki-rs"},
    {"name": "virtualization", "value": "firecracker-microvm"},
    {"name": "network-isolation", "value": "air-gapped"},
    {"name": "persistence", "value": "none"},
    {"name": "signature-freshness-gate-clamav", "value": "30-days"},
    {"name": "signature-freshness-gate-yara", "value": "60-days"}
  ]
}
JSON

chown "$SBOM_OWNER" "${SBOM_OUT}.new"
mv "${SBOM_OUT}.new" "$SBOM_OUT"
echo "[+] SBOM written to ${SBOM_OUT}"

# ── Build manifest emission ───────────────────────────────────────────────────
# Per-build operational record. Schema documented in
# docs/roadmap/build-manifest.md. The values overlap with the SBOM but
# the document's purpose is different: this is "what was in this build"
# rather than "what can be in a build", and the readership is an admin
# investigating a verdict rather than an auditor reviewing the project.
echo "[*] Emitting build manifest..."
mkdir -p "$SIGDIR"
cat > "${MANIFEST_OUT}.new" <<JSON
{
  "manifest_version": "1",
  "generated_at": "${TIMESTAMP}",
  "build_environment": {
    "troskel_commit": "${TROSKEL_COMMIT}",
    "troskel_dirty": ${TROSKEL_DIRTY},
    "build_host_kernel": "${BUILD_HOST_KERNEL}",
    "debian_release": "${DEBIAN_RELEASE}"
  },
  "software": {
    "firecracker": {
      "version": "${FC_VERSION}",
      "sha256": "${FC_SHA256}",
      "verification": "sidecar"
    },
    "butane": {
      "version": "${BUTANE_VERSION}",
      "sha256": "${BUTANE_SHA256}",
      "verification": "gpg-bootstrap"
    },
    "loki_rs": {
      "version": "${LOKI_VERSION}",
      "sha256": "${LOKI_SHA256}",
      "verification": "sidecar"
    },
    "wordlist": {
      "version": "2016-07-18",
      "sha256": "${WORDLIST_SHA256}",
      "verification": "recorded"
    },
    "kernel": {
      "resolved_filename": "${KERNEL_RESOLVED:-unknown}",
      "sha256": "${KERNEL_SHA256:-unknown}",
      "verification": "record-at-first-download"
    },
    "coreos_stream": {
      "stream": "${COREOS_STREAM}",
      "verification": "upstream-signed"
    }
  },
  "detection_inputs": {
    "clamav_signatures": {
      "files": [
${CLAM_CVDS_JSON}
      ],
      "downloaded_at": "${SIG_DATE}",
      "verification": "freshclam-embedded-keys"
    },
    "yara_forge": {
      "resolved_tag": "${YARA_FORGE_TAG}",
      "archive_sha256": "${YARA_FORGE_SHA}",
      "downloaded_at": "${YARA_DATE}",
      "verification": "tls-only"
    },
    "loki_ioc_base": {
      "version": "${LOKI_IOC_BASE_VERSION}",
      "verification": "tag-pinning"
    }
  }
}
JSON

mv "${MANIFEST_OUT}.new" "$MANIFEST_OUT"
chmod 644 "$MANIFEST_OUT"
echo "[+] Build manifest written to ${MANIFEST_OUT}"
echo ""
echo "[+] Build records ready."
echo "    Troskel commit  : ${TROSKEL_COMMIT}"
echo "    Tree clean      : $([ "$TROSKEL_DIRTY" = "false" ] && echo yes || echo NO — uncommitted changes)"
echo "    YARA Forge tag  : ${YARA_FORGE_TAG}"