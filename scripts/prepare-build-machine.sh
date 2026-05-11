#!/usr/bin/env bash
# scripts/prepare-build-machine.sh
# Checks that all required build tools are present. On Debian/Ubuntu,
# installs any that are missing via apt. On other systems, reports what
# is missing and exits cleanly — install the tools via your own mechanism
# and re-run; the script will proceed once everything is present.
#
# Usage: bash scripts/prepare-build-machine.sh
#        (sudo required only if packages need installing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../config/versions.env
source "${SCRIPT_DIR}/../config/versions.env"

# ── SHA-256 verification helper ───────────────────────────────────────────────
# Compares the SHA-256 of $FILE against $EXPECTED. Exits non-zero with a
# clear message on mismatch. The error path names the file and both values
# so a reader can identify which artefact failed and what to do about it.
verify_sha256() {
    local FILE="$1"
    local EXPECTED="$2"
    local LABEL="${3:-$FILE}"
    local ACTUAL
    ACTUAL="$(sha256sum "$FILE" | awk '{print $1}')"
    if [ "$ACTUAL" = "$EXPECTED" ]; then
        return 0
    fi
    echo ""
    echo "[!] SHA-256 mismatch for ${LABEL}"
    echo "    File     : ${FILE}"
    echo "    Expected : ${EXPECTED}"
    echo "    Got      : ${ACTUAL}"
    echo ""
    echo "    The downloaded artefact does not match the value recorded in"
    echo "    config/versions.env. Possible causes:"
    echo "      - The upstream release was re-published (compare against the"
    echo "        current .sha256 sidecar on the GitHub release page)."
    echo "      - The download was corrupted in transit (retry)."
    echo "      - A man-in-the-middle has substituted a tampered artefact."
    echo ""
    return 1
}

# Colour helpers
if [ -t 1 ]; then
    C_RESET='\033[0m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_DIM='\033[2m'
else
    C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi
ok()      { echo -e "  ${C_GREEN}✓${C_RESET} $*"; }
warn()    { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; }
fail()    { echo -e "  ${C_RED}✗${C_RESET} $*"; }
missing() { echo -e "  ${C_DIM}–${C_RESET} $* (missing)"; }

# ── Check all tools first ─────────────────────────────────────────────────────
echo ""
echo "=== Checking required tools ==="
echo ""

MISSING_APT=()       # installable via apt
MISSING_MANUAL=()    # must be installed manually (Firecracker, Butane, LOKI-RS)

check_tool() {
    local CMD="$1" PKG="${2:-$1}"
    if command -v "$CMD" >/dev/null 2>&1; then ok "$CMD"
    else missing "$CMD"; MISSING_APT+=("$PKG"); fi
}

check_tool debootstrap
check_tool mkfs.ext4     e2fsprogs
check_tool losetup       util-linux
check_tool parted
check_tool curl
check_tool wget
check_tool openssl
check_tool xorriso
check_tool sha256sum     coreutils
check_tool shellcheck
check_tool freshclam     clamav-freshclam
check_tool unzip

if command -v butane >/dev/null 2>&1; then
    ok "butane"
else
    missing "butane"
    MISSING_MANUAL+=("__butane__")
fi

if command -v firecracker >/dev/null 2>&1 || [ -x /usr/local/bin/firecracker ]; then
    ok "firecracker"
else
    missing "firecracker"
    MISSING_MANUAL+=("__firecracker__")
fi

if [ -x /opt/loki-rs/loki ]; then
    ok "loki-rs"
else
    missing "loki-rs"
    MISSING_MANUAL+=("__loki__")
fi

echo ""
echo "=== Docker ==="
echo ""
if command -v docker >/dev/null 2>&1; then
    ok "docker"
else
    missing "docker"
    warn "Docker is needed for 'make build' and 'make scan'."
    warn "Install it: https://docs.docker.com/engine/install/"
fi

# ── Install missing apt packages (Debian/Ubuntu only) ─────────────────────────
if [ "${#MISSING_APT[@]}" -gt 0 ]; then
    echo ""
    if command -v apt-get >/dev/null 2>&1; then
        echo "=== Installing missing packages via apt ==="
        echo ""
        [ "$(id -u)" -eq 0 ] || { fail "Root required to install packages. Re-run with sudo."; exit 1; }
        apt-get update -qq
        apt-get install -y --no-install-recommends "${MISSING_APT[@]}"
    else
        echo "=== Missing packages (apt not available) ==="
        echo ""
        warn "The following tools are missing and must be installed manually:"
        for PKG in "${MISSING_APT[@]}"; do
            warn "  $PKG"
        done
        echo ""
        warn "Install them via your system's package manager or nix-env,"
        warn "then re-run this script."
        echo ""
        exit 1
    fi
fi

# ── Install Firecracker ───────────────────────────────────────────────────────
if printf '%s\n' "${MISSING_MANUAL[@]}" | grep -q '__firecracker__'; then
    echo ""
    echo "=== Installing Firecracker ${FC_VERSION} ==="
    echo ""
    [ "$(id -u)" -eq 0 ] || { fail "Root required. Re-run with sudo."; exit 1; }
    TMPDIR_FC="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_FC"' EXIT
    curl -fsSL \
        "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-x86_64.tgz" \
        -o "${TMPDIR_FC}/firecracker.tgz"
    verify_sha256 "${TMPDIR_FC}/firecracker.tgz" "$FC_SHA256" "Firecracker ${FC_VERSION}"
    tar --no-same-owner -xzf "${TMPDIR_FC}/firecracker.tgz" -C "$TMPDIR_FC"
    cp "${TMPDIR_FC}/release-${FC_VERSION}-x86_64/firecracker-${FC_VERSION}-x86_64" \
        /usr/local/bin/firecracker
    chmod +x /usr/local/bin/firecracker
    rm -rf "$TMPDIR_FC"
    trap - EXIT
    ok "firecracker installed and verified"
fi

# ── Install Butane ────────────────────────────────────────────────────────────
if printf '%s\n' "${MISSING_MANUAL[@]}" | grep -q '__butane__'; then
    echo ""
    echo "=== Installing Butane ${BUTANE_VERSION} ==="
    echo ""
    [ "$(id -u)" -eq 0 ] || { fail "Root required. Re-run with sudo."; exit 1; }
    TMPDIR_BUTANE="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_BUTANE"' EXIT
    curl -fsSL \
        "https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-x86_64-unknown-linux-gnu" \
        -o "${TMPDIR_BUTANE}/butane"
    verify_sha256 "${TMPDIR_BUTANE}/butane" "$BUTANE_SHA256" "Butane ${BUTANE_VERSION}"
    install -m 0755 "${TMPDIR_BUTANE}/butane" /usr/local/bin/butane
    rm -rf "$TMPDIR_BUTANE"
    trap - EXIT
    ok "butane installed and verified (${BUTANE_VERSION})"
fi

# ── Install LOKI-RS ───────────────────────────────────────────────────────────
if printf '%s\n' "${MISSING_MANUAL[@]}" | grep -q '__loki__'; then
    echo ""
    echo "=== Installing LOKI-RS ${LOKI_VERSION} ==="
    echo ""
    [ "$(id -u)" -eq 0 ] || { fail "Root required. Re-run with sudo."; exit 1; }
    LOKI_DIR="/opt/loki-rs"
    TMPDIR_LOKI="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_LOKI"' EXIT
    curl -fsSL \
        "https://github.com/Neo23x0/Loki-RS/releases/download/${LOKI_VERSION}/loki-linux-x86_64-${LOKI_VERSION}.tar.gz" \
        -o "${TMPDIR_LOKI}/loki.tar.gz"
    verify_sha256 "${TMPDIR_LOKI}/loki.tar.gz" "$LOKI_SHA256" "LOKI-RS ${LOKI_VERSION}"
    tar --no-same-owner -xzf "${TMPDIR_LOKI}/loki.tar.gz" -C "$TMPDIR_LOKI"
    rm "${TMPDIR_LOKI}/loki.tar.gz"
    LOKI_BIN="$(find "$TMPDIR_LOKI" -type f -name loki | head -1)"
    mkdir -p "$LOKI_DIR"
    cp -r "$(dirname "$LOKI_BIN")/." "$LOKI_DIR/"
    chmod +x "${LOKI_DIR}/loki"
    [ -f "${LOKI_DIR}/loki-util" ] && chmod +x "${LOKI_DIR}/loki-util" || true
    rm -rf "$TMPDIR_LOKI"
    trap - EXIT
    ok "loki-rs installed and verified"
fi

# ── EFF wordlist ──────────────────────────────────────────────────────────────
echo ""
echo "=== EFF wordlist ==="
echo ""
bash "${SCRIPT_DIR}/download-wordlist.sh"

# ── Final check ───────────────────────────────────────────────────────────────
echo ""
echo "=== Final check ==="
echo ""

FINAL_FAIL=0
for CMD in debootstrap mkfs.ext4 losetup parted curl wget openssl xorriso sha256sum shellcheck freshclam unzip; do
    command -v "$CMD" >/dev/null 2>&1 && ok "$CMD" || { fail "$CMD still missing"; FINAL_FAIL=1; }
done

{ command -v butane >/dev/null 2>&1 || [ -x /usr/local/bin/butane ]; } \
    && ok "butane" || { fail "butane still missing"; FINAL_FAIL=1; }
{ command -v firecracker >/dev/null 2>&1 || [ -x /usr/local/bin/firecracker ]; } \
    && ok "firecracker" || { fail "firecracker still missing"; FINAL_FAIL=1; }
[ -x /opt/loki-rs/loki ] \
    && ok "loki-rs" || { fail "loki-rs still missing"; FINAL_FAIL=1; }
command -v docker >/dev/null 2>&1 \
    && ok "docker" || warn "docker not found (needed for make build/scan)"

echo ""
if [ "$FINAL_FAIL" -eq 0 ]; then
    echo -e "${C_GREEN}Build station ready.${C_RESET}"
else
    echo -e "${C_RED}Some tools are still missing. Install them and re-run.${C_RESET}"
    exit 1
fi