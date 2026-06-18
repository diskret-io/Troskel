#!/usr/bin/env bash
# tests/canary/check-upstream.sh
# Tier-0 canary: verify that every upstream artefact Troskel depends on is
# still reachable at the URL the build expects. Issues HEAD requests only;
# does not download or extract. Runs in seconds.
#
# Intended to be invoked from the upstream-canary GitHub Actions workflow
# on a daily schedule. Can also be run locally to sanity-check the
# dependency surface before a release:
#
#   bash tests/canary/check-upstream.sh
#
# Exit codes:
#   0  all upstream artefacts reachable
#   1  one or more failures (details printed to stderr)
#
# This script is deliberately conservative: it should fail when an upstream
# moves, renames, or 404s, even if the change is benign. A canary that
# self-heals against upstream changes has stopped being a canary.
#
# Note on per-endpoint accept-lists: a few upstreams return non-2xx codes
# *as their healthy response* and require an explicit accept-list:
#   - quay.io/v2/ returns 401 Unauthorized per the OCI Distribution Spec;
#     it means "registry is up, auth here for data". 401 is healthy.
#   - ClamAV's freshclam mirror returns 403 to HEAD requests as an abuse
#     mitigation. We cannot HEAD daily.cvd directly; the canonical
#     freshness oracle is the TXT record at current.cvd.clamav.net,
#     which freshclam itself uses. We DNS-resolve that instead of HTTP.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../../config/versions.env
source "${PROJECT_ROOT}/config/versions.env"

PASS=0
FAIL=0
FAILED_URLS=()

# ── Helpers ───────────────────────────────────────────────────────────────────

# check URL DESCRIPTION [ACCEPT_REGEX]
#   Issues a HEAD request following redirects. Treats any 2xx or 3xx as
#   success by default; ACCEPT_REGEX (a POSIX ERE) extends that, e.g.
#   "^(2..|3..|401)$" to also accept 401.
#
#   Note: we do NOT pass -f to curl. With -f, curl exits non-zero on a
#   4xx/5xx and never writes %{http_code}, leaving the variable empty.
#   Without -f, curl returns the HTTP code regardless and we make the
#   pass/fail decision ourselves. This is the only correct shape for a
#   reachability check that needs to distinguish "registry is up but
#   demands auth" from "registry is down".
check() {
    local URL="$1"
    local DESC="$2"
    local ACCEPT_REGEX="${3:-^[23][0-9][0-9]$}"
    local CODE

    CODE="$(curl -sSLI -o /dev/null -w '%{http_code}' --max-time 20 "$URL" 2>/dev/null)"
    CODE="${CODE:-000}"

    if [[ "$CODE" =~ $ACCEPT_REGEX ]]; then
        printf "  [PASS] %-40s %s\n" "$DESC" "($CODE)"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %-40s %s\n" "$DESC" "($CODE) $URL" >&2
        FAIL=$((FAIL + 1))
        FAILED_URLS+=("${DESC}: ${URL} (HTTP ${CODE})")
    fi
}

# check_butane_resolves
#   Butane floats to "latest"; we cannot HEAD a specific tarball. Instead,
#   verify that the redirect from /releases/latest still resolves to a
#   concrete tag, which is what prepare-build-machine.sh relies on.
check_butane_resolves() {
    local URL="https://github.com/coreos/butane/releases/latest"
    local RESOLVED
    RESOLVED="$(curl -sSLI -o /dev/null -w '%{url_effective}' --max-time 20 "$URL" 2>/dev/null || echo "")"

    if [[ "$RESOLVED" =~ /releases/tag/v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        printf "  [PASS] %-40s %s\n" "Butane latest resolves" "(${RESOLVED##*/})"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %-40s %s\n" "Butane latest resolves" "(unexpected: '$RESOLVED')" >&2
        FAIL=$((FAIL + 1))
        FAILED_URLS+=("Butane /releases/latest did not resolve to a tag (got '${RESOLVED}')")
    fi
}

# check_kernel_listing
#   The Firecracker CI kernel S3 bucket has no per-asset checksums, and
#   download-kernel.sh resolves the latest patch via an S3 ListObjectsV2
#   call. Replicate that call and confirm at least one matching key is
#   returned for the current FC_VERSION.
check_kernel_listing() {
    local CI_VERSION="${FC_VERSION%.*}"   # v1.7.0 -> v1.7
    local ARCH="x86_64"
    local URL="http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-&list-type=2"
    local KEY

    KEY="$(curl -fsSL --max-time 20 "$URL" 2>/dev/null \
        | grep -oP "(?<=<Key>)(firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
        | sort -V | tail -1 || echo "")"

    if [ -n "$KEY" ]; then
        printf "  [PASS] %-40s %s\n" "Firecracker CI kernel listing" "(${KEY##*/})"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %-40s %s\n" "Firecracker CI kernel listing" "(no kernel under ${CI_VERSION})" >&2
        FAIL=$((FAIL + 1))
        FAILED_URLS+=("Firecracker CI kernel: no vmlinux-* key found under firecracker-ci/${CI_VERSION}/${ARCH}/")
    fi
}

# check_clamav_freshness_oracle
#   freshclam queries a DNS TXT record at current.cvd.clamav.net to learn
#   the latest signature versions before deciding whether to download.
#   This is the canonical freshness oracle for the entire ClamAV update
#   path; if it answers, freshclam can update. We use this instead of an
#   HTTP HEAD on daily.cvd because the CDN rejects HEAD with 403 as part
#   of its abuse mitigation.
check_clamav_freshness_oracle() {
    local TXT
    TXT="$(dig +short TXT current.cvd.clamav.net 2>/dev/null | head -1)"

    # Expected format is a colon-separated string starting with a version
    # field, e.g. "0.103.13:62:27577:1731499200:1:90:54:333".
    if [[ "$TXT" =~ ^\"?[0-9]+\.[0-9]+\.[0-9]+: ]]; then
        printf "  [PASS] %-40s %s\n" "ClamAV freshness oracle" "(TXT ok)"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %-40s %s\n" "ClamAV freshness oracle" "(unexpected TXT: '$TXT')" >&2
        FAIL=$((FAIL + 1))
        FAILED_URLS+=("ClamAV freshness oracle current.cvd.clamav.net returned unexpected TXT: '${TXT}'")
    fi
}

# check_coreos_stream
#   The CoreOS stream metadata is fetched implicitly by `coreos-installer
#   download`. A 200 on the JSON metadata is sufficient evidence that the
#   stream still publishes; a missing stream would 404.
check_coreos_stream() {
    local URL="https://builds.coreos.fedoraproject.org/streams/${COREOS_STREAM}.json"
    check "$URL" "CoreOS stream (${COREOS_STREAM})"
}

# ── Header ────────────────────────────────────────────────────────────────────

echo ""
echo "=== Tier 0: upstream reachability ==="
echo ""
echo "Pinned versions:"
echo "  FC_VERSION       = ${FC_VERSION}"
echo "  LOKI_VERSION     = ${LOKI_VERSION}"
echo "  BUTANE_VERSION   = ${BUTANE_VERSION}"
echo "  DEBIAN_RELEASE   = ${DEBIAN_RELEASE}"
echo "  COREOS_STREAM    = ${COREOS_STREAM}"
echo ""

# ── Pinned tarballs ───────────────────────────────────────────────────────────

# Firecracker release tarball + its sidecar checksum file.
check "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-x86_64.tgz" \
      "Firecracker tarball"
check "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-x86_64.tgz.sha256.txt" \
      "Firecracker SHA-256 sidecar"

# LOKI-RS release tarball.
check "https://github.com/Neo23x0/Loki-RS/releases/download/${LOKI_VERSION}/loki-linux-x86_64-${LOKI_VERSION}.tar.gz" \
      "LOKI-RS tarball"

# ── Floating / resolved-at-runtime ────────────────────────────────────────────

check_butane_resolves
check_kernel_listing
check_coreos_stream
check_clamav_freshness_oracle

# ── Static / well-known endpoints ─────────────────────────────────────────────

# EFF wordlist: used by prepare-boot-usb.sh for diceware passphrase generation.
check "https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt" \
      "EFF Long Wordlist"

# Debian mirror: used by debootstrap during scanner-image build.
check "https://deb.debian.org/debian/dists/${DEBIAN_RELEASE}/Release" \
      "Debian ${DEBIAN_RELEASE} mirror"

# CoreOS installer container image registry, pulled by prepare-boot-usb.sh.
# The OCI Distribution Spec mandates that /v2/ on a working registry returns
# 401 Unauthorized when accessed without credentials. 401 here means
# "registry is up, auth here for data". It is the healthy response.
# A 5xx or connection failure would mean the registry is genuinely down.
check "https://quay.io/v2/" \
      "Quay.io registry (coreos-installer)" \
      "^(2[0-9][0-9]|3[0-9][0-9]|401)$"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "Failures:" >&2
    for F in "${FAILED_URLS[@]}"; do
        echo "  - ${F}" >&2
    done
    echo "" >&2
    echo "An upstream artefact has moved, been renamed, or is unreachable." >&2
    echo "Check config/versions.env and the relevant download script." >&2
    exit 1
fi

echo "All upstream artefacts reachable."