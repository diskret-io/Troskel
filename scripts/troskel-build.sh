#!/usr/bin/env bash
# scripts/troskel-build.sh
# Guided admin workflow for Troskel. Orchestrates the full build and USB
# write cycle with runtime detection, USB assignment, progress reporting,
# and post-write verification.
#
# Usage:
#   sudo bash scripts/troskel-build.sh [OPTIONS]
#
# Options:
#   --container     Insist on a container runtime; fail if none found.
#   --usb-all       Write both boot USB and data USB (default).
#   --usb-data      Write data USB only; expects one USB device.
#   --usb-boot      Write boot USB only; expects one USB device.
#   --update        Update artefacts only; skip USB writing.
#   --debug         Show full output from all sub-scripts.
#
# For developer use, run the make targets instead:
#   make validate   make test   make update
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/../config/versions.env"

# ── Colour helpers ────────────────────────────────────────────────────────────
# Only emit colour codes if stdout is a terminal.
if [ -t 1 ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_CYAN='\033[0;36m'
    C_DIM='\033[2m'
else
    C_RESET='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_DIM=''
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
USB_MODE="all"        # all | data | boot
UPDATE_ONLY=0
DEBUG=0

for arg in "$@"; do
    case "$arg" in
        --usb-all)    USB_MODE="all" ;;
        --usb-data)   USB_MODE="data" ;;
        --usb-boot)   USB_MODE="boot" ;;
        --update)     UPDATE_ONLY=1 ;;
        --debug)      DEBUG=1 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg  (use --help for usage)"
            exit 1
            ;;
    esac
done

# ── Output helpers ────────────────────────────────────────────────────────────
header() {
    echo ""
    echo -e "${C_BOLD}${C_CYAN}══ $* ══${C_RESET}"
}

progress() { echo -e "  ${C_DIM}▸${C_RESET} $*"; }
ok()       { echo -e "  ${C_GREEN}✓${C_RESET} $*"; }
warn()     { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; }
fail()     { echo -e "  ${C_RED}✗${C_RESET} $*"; }

# Run a sub-script. In normal mode suppress its output and show a
# single progress/ok line. In debug mode stream everything.
run_step() {
    local LABEL="$1"; shift
    progress "${LABEL}..."
    if [ "$DEBUG" -eq 1 ]; then
        "$@"
    else
        local OUT
        OUT="$(mktemp)"
        if "$@" > "$OUT" 2>&1; then
            ok "$LABEL"
            rm -f "$OUT"
        else
            fail "$LABEL"
            echo ""
            echo -e "${C_DIM}--- output ---${C_RESET}"
            cat "$OUT"
            echo -e "${C_DIM}--------------${C_RESET}"
            rm -f "$OUT"
            echo ""
            echo -e "${C_RED}Build failed at: ${LABEL}${C_RESET}"
            echo "  Run with --debug for full output."
            exit 1
        fi
    fi
}

# ── Phase 0: Runtime detection ────────────────────────────────────────────────
header "Runtime detection"

if command -v docker >/dev/null 2>&1; then
    ok "Container runtime: docker"
else
    fail "Docker not found. Install Docker: https://docs.docker.com/engine/install/"
    exit 1
fi

# ── Phase 1: USB detection and assignment ─────────────────────────────────────
if [ "$UPDATE_ONLY" -eq 0 ]; then
    header "USB detection"

    # How many USB devices do we need?
    case "$USB_MODE" in
        all)  NEEDED=2 ROLES=("TROSKEL-BOOT" "TROSKEL-DATA") ;;
        data) NEEDED=1 ROLES=("TROSKEL-DATA") ;;
        boot) NEEDED=1 ROLES=("TROSKEL-BOOT") ;;
    esac

    # Enumerate USB block devices (exclude partitions, exclude system disk).
    ROOT_DEV="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || true)"
    mapfile -t USB_DEVS < <(
        lsblk -dpno NAME,TRAN,SIZE,LABEL,MODEL \
        | awk '$2=="usb" {print $0}' \
        | grep -v "^${ROOT_DEV:-NOMATCH}" \
        | awk '{print $1}' \
        || true
    )

    FOUND="${#USB_DEVS[@]}"

    if [ "$FOUND" -lt "$NEEDED" ]; then
        fail "Found ${FOUND} USB device(s), need ${NEEDED}."
        case "$USB_MODE" in
            all)  echo "    Insert the TROSKEL-BOOT USB and TROSKEL-DATA USB and retry." ;;
            data) echo "    Insert the TROSKEL-DATA USB and retry." ;;
            boot) echo "    Insert the TROSKEL-BOOT USB and retry." ;;
        esac
        exit 1
    fi

    ok "Found ${FOUND} USB device(s)."
    echo ""

    # Build a display table of available devices.
    declare -A USB_INFO
    for DEV in "${USB_DEVS[@]}"; do
        SIZE="$(lsblk -dno SIZE "$DEV" 2>/dev/null || echo '?')"
        MODEL="$(lsblk -dno MODEL "$DEV" 2>/dev/null | xargs || echo 'Unknown')"
        LABEL="$(lsblk -dno LABEL "$DEV" 2>/dev/null | xargs || echo '—')"
        USB_INFO["$DEV"]="$SIZE  $MODEL  ($LABEL)"
    done

    # If exactly the right number of devices, auto-assign if labels match.
    # Otherwise prompt the admin.
    declare -A ROLE_ASSIGNMENT  # role -> device

    if [ "$NEEDED" -eq 1 ]; then
        # Single device — assign it directly, confirm with the admin.
        DEV="${USB_DEVS[0]}"
        ROLE="${ROLES[0]}"
        echo -e "  Device: ${C_BOLD}${DEV}${C_RESET}  ${USB_INFO[$DEV]}"
        echo -e "  Role  : ${C_BOLD}${ROLE}${C_RESET}"
        echo ""
        read -r -p "  Use this device? [Y/n] " CONFIRM
        CONFIRM="${CONFIRM:-y}"
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
        ROLE_ASSIGNMENT["$ROLE"]="$DEV"
    else
        # Multiple devices — present numbered list, ask admin to assign each role.
        echo "  Connected USB devices:"
        echo ""
        IDX=1
        declare -A IDX_TO_DEV
        for DEV in "${USB_DEVS[@]}"; do
            printf "    [%d]  %-12s  %s\n" "$IDX" "$DEV" "${USB_INFO[$DEV]}"
            IDX_TO_DEV["$IDX"]="$DEV"
            IDX=$((IDX + 1))
        done
        echo ""

        USED_IDXS=()
        for ROLE in "${ROLES[@]}"; do
            while true; do
                read -r -p "  Assign ${C_BOLD}${ROLE}${C_RESET} → enter number: " SEL
                # Validate: must be a number, in range, not already used.
                if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ -z "${IDX_TO_DEV[$SEL]+x}" ]; then
                    warn "Invalid selection. Enter a number from the list."
                    continue
                fi
                if printf '%s\n' "${USED_IDXS[@]}" | grep -qx "$SEL"; then
                    warn "Device already assigned. Choose a different one."
                    continue
                fi
                ROLE_ASSIGNMENT["$ROLE"]="${IDX_TO_DEV[$SEL]}"
                USED_IDXS+=("$SEL")
                ok "${ROLE} → ${IDX_TO_DEV[$SEL]}"
                break
            done
        done

        echo ""
        echo "  Confirm assignments:"
        for ROLE in "${ROLES[@]}"; do
            DEV="${ROLE_ASSIGNMENT[$ROLE]}"
            printf "    %-16s  %s  %s\n" "$ROLE" "$DEV" "${USB_INFO[$DEV]}"
        done
        echo ""
        read -r -p "  Proceed? [Y/n] " CONFIRM
        CONFIRM="${CONFIRM:-y}"
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi
fi

# ── Phase 2: Preflight checks ─────────────────────────────────────────────────
header "Preflight checks"

PREFLIGHT_FAIL=0

# Internet connectivity
progress "Internet connectivity..."
if curl -fsSL --max-time 5 https://github.com >/dev/null 2>&1; then
    ok "Internet reachable"
else
    fail "No internet access — signature downloads will fail."
    PREFLIGHT_FAIL=1
fi



# EFF wordlist (needed by prepare-boot-usb.sh for passphrase generation).
# Download automatically if missing rather than failing preflight.
if [ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "boot" ]; then
    WORDLIST="${PROJECT_ROOT}/config/eff-large-wordlist.txt"
    if [ -f "$WORDLIST" ]; then
        ok "EFF wordlist present"
    else
        progress "EFF wordlist not found — downloading..."
        if bash "${SCRIPT_DIR}/download-wordlist.sh" >/dev/null 2>&1; then
            ok "EFF wordlist downloaded and verified"
        else
            fail "EFF wordlist download failed — check internet connectivity"
            PREFLIGHT_FAIL=1
        fi
    fi
fi

# Disk space under /var/lib/troskel (rough check: need ~5 GB)
AVAIL_KB="$(df -k /var/lib/troskel 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
if [ "$AVAIL_GB" -ge 5 ]; then
    ok "Disk space: ${AVAIL_GB} GB available"
else
    warn "Low disk space: ${AVAIL_GB} GB available under /var/lib/troskel (need ~5 GB)"
    PREFLIGHT_FAIL=1
fi

if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
    echo ""
    fail "Preflight checks failed. Resolve the issues above and retry."
    exit 1
fi

# ── Phase 3: Update artefacts ─────────────────────────────────────────────────
# Delegate to `make update`, which runs scripts/run-update.sh inside the
# troskel-build container. One canonical refresh path: a developer typing
# `make update` and an admin running troskel-build.sh both go through the
# same target. Container output streams to stdout so the user sees real
# progress during the rebuild rather than a silent prompt that looks hung.
header "Updating artefacts (via make update)"

cd "$PROJECT_ROOT"
if ! make update; then
    echo ""
    fail "make update failed."
    echo "  Run 'make update' directly for the same output without this wrapper."
    exit 1
fi

SIG_DATE="$(cat /var/lib/troskel/signature-date 2>/dev/null || echo 'unknown')"
ok "Artefacts ready. Signature date: ${SIG_DATE}"

if [ "$UPDATE_ONLY" -eq 1 ]; then
    echo ""
    ok "Update complete (--update mode, skipping USB write)."
    exit 0
fi

# ── Phase 4: Write USBs ───────────────────────────────────────────────────────
header "Writing USBs"

# Capture passphrase output from prepare-boot-usb.sh so we can display
# it prominently in the final summary rather than buried in scroll.
PASSPHRASE_FILE="$(mktemp)"
trap 'rm -f "$PASSPHRASE_FILE"' EXIT

if [ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "data" ]; then
    DATA_DEV="${ROLE_ASSIGNMENT[TROSKEL-DATA]}"
    run_step "Writing TROSKEL-DATA (${DATA_DEV})" \
        bash "${SCRIPT_DIR}/prepare-data-usb.sh" "$DATA_DEV"
fi

if [ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "boot" ]; then
    BOOT_DEV="${ROLE_ASSIGNMENT[TROSKEL-BOOT]}"
    progress "Writing TROSKEL-BOOT (${BOOT_DEV})..."
    if [ "$DEBUG" -eq 1 ]; then
        bash "${SCRIPT_DIR}/prepare-boot-usb.sh" "$BOOT_DEV"
    else
        OUT="$(mktemp)"
        if bash "${SCRIPT_DIR}/prepare-boot-usb.sh" "$BOOT_DEV" > "$OUT" 2>&1; then
            ok "TROSKEL-BOOT written (${BOOT_DEV})"
            # Extract the passphrase block from prepare-boot-usb.sh output.
            sed -n '/SCANNER PASSPHRASE/,/======/p' "$OUT" > "$PASSPHRASE_FILE"
            rm -f "$OUT"
        else
            fail "TROSKEL-BOOT write failed"
            cat "$OUT"; rm -f "$OUT"
            exit 1
        fi
    fi
fi

# ── Phase 5: Verification ─────────────────────────────────────────────────────
header "Verification"

# Verify data USB checksums by re-mounting and checking.
if [ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "data" ]; then
    progress "Verifying TROSKEL-DATA checksums..."
    VMOUNT="$(mktemp -d)"
    DATA_PART="${DATA_DEV}1"
    [ -b "${DATA_DEV}p1" ] && DATA_PART="${DATA_DEV}p1"
    mount -o ro "$DATA_PART" "$VMOUNT" 2>/dev/null \
        && cd "$VMOUNT" \
        && sha256sum --check scanner-rootfs.ext4.sha256 >/dev/null 2>&1 \
        && ok "TROSKEL-DATA checksums verified" \
        || { fail "TROSKEL-DATA checksum verification failed — do not use this USB."; exit 1; }
    cd /; umount "$VMOUNT"; rm -rf "$VMOUNT"
fi

# ── Phase 6: Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${C_BOLD}${C_GREEN}╔══════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}║  Build complete                                  ║${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}╚══════════════════════════════════════════════════╝${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Signature date${C_RESET}  $(cat /var/lib/troskel/signature-date 2>/dev/null || echo '—')"
echo -e "  ${C_BOLD}Written${C_RESET}         $(date -u --iso-8601=seconds)"
[ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "data" ] && \
    echo -e "  ${C_BOLD}Data USB${C_RESET}        ${DATA_DEV:-—}  (TROSKEL-DATA)"
[ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "boot" ] && \
    echo -e "  ${C_BOLD}Boot USB${C_RESET}        ${BOOT_DEV:-—}  (TROSKEL-BOOT)"

# Show passphrase prominently if we captured it.
if [ -s "$PASSPHRASE_FILE" ]; then
    echo ""
    echo -e "${C_BOLD}${C_YELLOW}╔══════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_YELLOW}║  SCANNER PASSPHRASE — RECORD THIS NOW            ║${C_RESET}"
    echo -e "${C_BOLD}${C_YELLOW}╚══════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    grep -v "===\|PASSPHRASE\|This passphrase\|not stored\|Write it" "$PASSPHRASE_FILE" \
        | grep -v "^$" \
        | sed 's/^/  /'
    echo ""
    echo -e "  ${C_DIM}This passphrase is not stored anywhere. Record it on the"
    echo -e "  boot USB label or in your password manager before continuing.${C_RESET}"
fi

echo ""
echo -e "  ${C_BOLD}Next steps${C_RESET}"
echo "  1. Label each USB with the signature date."
echo "  2. Transport to the air-gapped room."
echo "  3. Insert both USBs into the scanning host and power on."
echo ""