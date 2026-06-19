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

# Shared stage runner and UI helpers. Lives in scripts/lib/run-step.sh
# so that tests/test-run-step.sh can exercise the same function this
# orchestrator uses, with no risk of the two implementations drifting.
# See scripts/lib/run-step.sh header for the function contract.
source "${SCRIPT_DIR}/lib/run-step.sh"

# Stage plan ("Stage N of M" framing). Single source of truth for which
# stages run lives in scripts/lib/stage-plan.sh; see its contract. The
# plan is built from the flags below, after argument parsing.
source "${SCRIPT_DIR}/lib/stage-plan.sh"

# Sidecar verification protocol. Single implementation shared with
# prepare-data-usb.sh and build-scanner-image.sh; see the module header for
# the result contract. Phase 5 uses it as a consumer.
# shellcheck source=lib/verify-artefact.sh
source "${SCRIPT_DIR}/lib/verify-artefact.sh"

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

# Build the stage plan from the parsed flags, so "Stage N of M" reflects
# exactly the stages that will run. compute_stage_plan (stage-plan.sh)
# is the single source of truth; each stage_header call below must have
# a matching label there. tests/test-run-step.sh enforces the match.
mapfile -t STAGES < <(compute_stage_plan "$USB_MODE" "$UPDATE_ONLY")
stage_plan "${STAGES[@]}"

# ── Post-condition helpers ────────────────────────────────────────────────────
# Each writes its diagnostic to stderr on failure and returns non-zero.
# Kept small so the failure mode they detect is obvious; combine
# multiple post-conditions in a wrapper if a stage needs more than one
# check.

# Mount the data USB read-only, confirm scanner-rootfs.ext4 is present
# and non-empty, unmount, return success. This is the lightweight
# "did anything get written" check; the deeper checksum verification
# lives in Phase 5.
postcond_data_usb_written() {
    local DEV="${DATA_DEV:?postcond_data_usb_written needs DATA_DEV}"
    local PART="${DEV}1"
    [ -b "${DEV}p1" ] && PART="${DEV}p1"
    local M
    M="$(mktemp -d)"
    if ! mount -o ro "$PART" "$M" 2>/dev/null; then
        echo "[!] Data USB partition ${PART} did not mount post-write." >&2
        rm -rf "$M"
        return 1
    fi
    local RC=0
    if [ ! -s "$M/scanner-rootfs.ext4" ]; then
        echo "[!] Data USB does not contain scanner-rootfs.ext4 post-write." >&2
        RC=1
    fi
    umount "$M" 2>/dev/null || true
    rm -rf "$M"
    return "$RC"
}

# For the boot USB the post-condition is "the first 512 bytes of the
# device do not look like the pre-existing filesystem". We compare the
# MBR signature against what blkid reports the device contains: after
# dd of a CoreOS ISO, blkid should report iso9660 (the ISO carries an
# iso9660 signature) or "" (some Fedora ISOs scrub this); before dd,
# blkid reported whatever the previous content was. The cheapest
# usable post-condition is "the device's filesystem signature now
# matches the ISO's", which we approximate by re-reading blkid and
# requiring it to be iso9660 or empty.
postcond_boot_usb_written() {
    local DEV="${BOOT_DEV:?postcond_boot_usb_written needs BOOT_DEV}"
    udevadm settle
    local FS
    FS="$(blkid -s TYPE -o value "$DEV" 2>/dev/null || true)"
    case "$FS" in
        iso9660|"") return 0 ;;
        *)
            echo "[!] Boot USB ${DEV} filesystem signature is '${FS}', expected iso9660." >&2
            echo "    The dd write may not have completed; the device still appears" >&2
            echo "    to carry its previous content." >&2
            return 1
            ;;
    esac
}

# Verify data USB checksums by re-mounting and checking. Defined as a
# named function rather than an inline expression so the failure mode
# is explicit at each step rather than buried in a chain of `&& ... ||`.
# Called via run_step at Phase 5.
verify_data_usb_checksums() {
    local DATA_PART="${DATA_DEV}1"
    [ -b "${DATA_DEV}p1" ] && DATA_PART="${DATA_DEV}p1"
    local VMOUNT
    VMOUNT="$(mktemp -d)"
    if ! mount -o ro "$DATA_PART" "$VMOUNT" 2>/dev/null; then
        echo "[!] Could not mount ${DATA_PART} for verification." >&2
        rm -rf "$VMOUNT"
        return 1
    fi
    local RC=0
    # Verify via the shared module: resolves the artefact under $VMOUNT and
    # rejects a path-carrying sidecar, so the check cannot be redirected to the
    # source (bug 2). Result token suppressed; we set RC and let the caller's
    # diagnostic stand. Module stderr (mismatch hashes etc.) still surfaces.
    if ! verify_artefact_check "$VMOUNT" "$VMOUNT/scanner-rootfs.ext4.sha256" >/dev/null; then
        echo "[!] Checksum verification failed — do not use this USB." >&2
        RC=1
    fi
    umount "$VMOUNT" 2>/dev/null || true   # ro mount; unmount failure is non-fatal, the tmpdir is removed next regardless
    rm -rf "$VMOUNT"
    return "$RC"
}

# ── Phase 0: Runtime detection ────────────────────────────────────────────────
stage_header "Runtime detection"

if command -v docker >/dev/null 2>&1; then
    ok "Container runtime: docker"
else
    fail "Docker not found. Install Docker: https://docs.docker.com/engine/install/"
    exit 1
fi

# ── Phase 1: USB detection and assignment ─────────────────────────────────────
if [ "$UPDATE_ONLY" -eq 0 ]; then
    stage_header "USB detection"

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
        if ! confirm_destructive "  Use this device? [y to confirm] "; then
            echo "Aborted."; exit 0
        fi
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
        if ! confirm_destructive "  Proceed? [y to confirm] "; then
            echo "Aborted."; exit 0
        fi
    fi
fi

# ── Phase 2: Preflight checks ─────────────────────────────────────────────────
stage_header "Preflight checks"

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
stage_header "Updating artefacts"

# This stage downloads signatures and rebuilds the scanner image; it is
# the longest in a typical run. Announce a range so the streamed output
# (and, on the write stages, the heartbeat) has a reference the operator
# can judge against. Range, not a point estimate: time varies with
# bandwidth and whether the image cache is warm.
progress "Refreshing signatures and rebuilding (typically 5-20 min, first run longer)..."

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
stage_header "Writing USBs"

# Inner scripts (prepare-data-usb.sh, prepare-boot-usb.sh) carry their
# own "Continue? [y/N]" confirmation prompt as a safety net for direct
# invocation outside the orchestrator. The orchestrator already
# obtained operator confirmation in Phase 1 (device assignment), so
# the inner prompts would re-ask the same question against captured
# stdin. We signal "already confirmed" via the environment so the
# inner scripts skip their own prompt; direct invocation outside the
# orchestrator (without this env var set) gets the prompt as usual.
export TROSKEL_CONFIRMED=1

# Capture passphrase output from prepare-boot-usb.sh so we can display
# it prominently in the final summary rather than buried in scroll.
PASSPHRASE_FILE="$(mktemp)"
trap 'rm -f "$PASSPHRASE_FILE"' EXIT

if [ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "data" ]; then
    DATA_DEV="${ROLE_ASSIGNMENT[TROSKEL-DATA]}"
    POSTCOND=postcond_data_usb_written run_step \
        "Writing TROSKEL-DATA (${DATA_DEV}) (typically 3-8 min)" \
        bash "${SCRIPT_DIR}/prepare-data-usb.sh" "$DATA_DEV"
fi

# Boot USB write goes through run_step like every other captured stage.
# The one extra need here is reading the captured output afterwards to
# extract the scanner passphrase, which run_step supports via KEEP_OUT:
# on success it copies the captured output to the named file, and (per
# the KEEP_OUT contract in run-step.sh) the consumer must check its own
# extraction result rather than trusting the file is populated. POSTCOND
# carries the same iso9660-signature side-effect check the hand-rolled
# wrapper used; run_step dumps captured output and exits non-zero on
# either a non-zero write or a failed post-condition, so the failure-mode
# discipline is identical and no longer duplicated here.
#
# In debug mode run_step streamed the boot script's output live and
# leaves BOOT_OUT empty by construction; the passphrase-extraction check
# below then fails loudly, which is correct: an operator running --debug
# sees the passphrase in the streamed output directly, and a silent
# empty summary box must never be the result.
if [ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "boot" ]; then
    BOOT_DEV="${ROLE_ASSIGNMENT[TROSKEL-BOOT]}"
    BOOT_OUT="$(mktemp)"
    POSTCOND=postcond_boot_usb_written KEEP_OUT="$BOOT_OUT" run_step \
        "Writing TROSKEL-BOOT (${BOOT_DEV}) (typically 10-15 min)" \
        bash "${SCRIPT_DIR}/prepare-boot-usb.sh" "$BOOT_DEV"

    # Extract the passphrase from the captured boot-script output. The
    # boot script prints a banner block:
    #
    #     ============================================================
    #       SCANNER PASSPHRASE — RECORD THIS NOW
    #     ============================================================
    #
    #         <four-word-passphrase>
    #
    #       <explanatory text...>
    #     ============================================================
    #
    # The awk state machine: enter header mode on the title line, switch
    # to passphrase mode on the banner closing the header, exit on the
    # banner closing the passphrase block, capture the first non-empty
    # line in passphrase mode (the passphrase itself, ahead of the
    # explanatory paragraph).
    #
    # CONTRACT NOTE (KEEP_OUT consumer): BOOT_OUT may be empty (debug
    # mode, or a boot-script output-format change). The emptiness check
    # below is mandatory, not optional: without it a missed extraction
    # would produce a summary box with no passphrase and the operator
    # would lose an unrecoverable per-build credential.
    awk '
        /SCANNER PASSPHRASE/        { in_header=1; next }
        in_header && /^====/        { in_header=0; in_pass=1; next }
        in_pass && /^====/          { exit }
        in_pass && NF && !captured  { print $0; captured=1 }
    ' "$BOOT_OUT" > "$PASSPHRASE_FILE"

    if [ ! -s "$PASSPHRASE_FILE" ]; then
        fail "Passphrase capture failed — could not extract from boot script output"
        if [ "$DEBUG" -eq 1 ]; then
            echo "  Running in --debug: the passphrase was printed in the streamed"
            echo "  output above. Record it from there."
        else
            echo ""
            echo -e "${C_DIM}--- output ---${C_RESET}"
            cat "$BOOT_OUT"
            echo -e "${C_DIM}--------------${C_RESET}"
            echo ""
            echo "  The boot USB was written, but the scanner passphrase could"
            echo "  not be extracted from prepare-boot-usb.sh's output. Without"
            echo "  the passphrase the boot USB is unusable. Boot script output"
            echo "  format may have changed since this orchestrator was written."
        fi
        rm -f "$BOOT_OUT"
        exit 1
    fi
    rm -f "$BOOT_OUT"
fi

# ── Phase 5: Verification ─────────────────────────────────────────────────────
stage_header "Verification"

if [ "$USB_MODE" = "all" ] || [ "$USB_MODE" = "data" ]; then
    run_step "Verifying TROSKEL-DATA checksums" verify_data_usb_checksums
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
    grep -v "^$" "$PASSPHRASE_FILE" \
        | sed 's/^[[:space:]]*/    /'
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