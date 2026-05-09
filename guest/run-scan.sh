#!/bin/sh
# Guest scan entrypoint. Runs inside the Firecracker microVM.
#
# Two engines run sequentially over the read-only scan target. Their
# verdicts are combined under OR semantics — either engine flagging a
# threat produces a red verdict (see ARCHITECTURE.md, "Why two engines").
#
#   ClamAV   — exit 0 = clean, 1 = infected, anything else = error.
#   LOKI-RS  — exit code is not a reliable verdict signal; we parse the
#              JSONL output for findings at ALERT severity (score ≥ 80).
#              The exit code is consulted only to detect hard failures.
#
# The host-side wrapper greps the serial log for the exact strings
# emitted below (THREAT DETECTED / CLEAN / ERROR) — see the verdict
# pipeline notes in ARCHITECTURE.md for why guest and host both perform
# verdict logic. Each engine also emits an ENGINE: summary line that the
# host displays under the verdict block, so the operator sees which
# engine flagged what without scrolling through the full log.
set -eu
SCANDIR="/mnt/scanfiles"
SERIAL="/dev/ttyS0"
LOKI_DIR="/opt/loki-rs"
LOKI_OUT="/tmp/loki-scan.jsonl"
log() { echo "[$(date -u +%H:%M:%S)] $*" > "$SERIAL"; }

# count_lines — robust replacement for `grep -c PAT FILE || echo 0`. The
# `grep -c` form prints "0" on no match AND exits non-zero, so paired
# with `|| echo 0` it produces a two-line value ("0\n0") that fails
# numeric comparison with [: Illegal number. wc -l on filtered output
# always prints exactly one number.
count_lines() {
    grep -c -- "$1" "$2" 2>/dev/null || true
}

log "=== Troskel scanner starting ==="
mkdir -p "$SCANDIR"
mount -o ro /dev/vdb "$SCANDIR" \
    || { log "[!] Failed to mount scan target — aborting"; sync; echo b > /proc/sysrq-trigger; }

# --- ClamAV ----------------------------------------------------------
# Capture ClamAV's output to a file so we can both (a) stream it to the
# serial console for transparency during the scan and (b) parse it
# afterwards for the per-engine summary line. With --infected, ClamAV
# prints one line per infected file: "<path>: <signature> FOUND".
#
# --quiet was previously included here but has been removed: in current
# ClamAV versions it suppresses the per-file FOUND lines that --infected
# would otherwise emit, leaving only the (also-suppressed) summary. The
# resulting empty output broke the count parser. We now accept the more
# verbose summary in exchange for reliably-captured FOUND lines.
log "--- ClamAV ---"
CLAMAV_EXIT=0
CLAMAV_OUT="/tmp/clamav-scan.log"
clamscan --recursive --infected --official-db-only=no \
    --database=/var/lib/clamav "$SCANDIR" > "$CLAMAV_OUT" 2>&1 || CLAMAV_EXIT=$?
cat "$CLAMAV_OUT" > "$SERIAL"
# Diagnostic: log the captured output size. If this is 0, ClamAV produced
# no output at all and the count parser will report 0 regardless of exit
# code — that's the symptom we hit before --quiet was removed.
log "ClamAV output: $(wc -c < "$CLAMAV_OUT") bytes"
log "ClamAV exit: $CLAMAV_EXIT"

# Per-engine summary for ClamAV. Status is independent of count: a
# non-zero exit code with no findings is an error, not a threat.
CLAMAV_COUNT=$(count_lines ' FOUND$' "$CLAMAV_OUT")
CLAMAV_COUNT="${CLAMAV_COUNT:-0}"
if [ "$CLAMAV_EXIT" -eq 1 ] && [ "$CLAMAV_COUNT" -gt 0 ]; then
    CLAMAV_STATUS="threat"
elif [ "$CLAMAV_EXIT" -eq 0 ] && [ "$CLAMAV_COUNT" -eq 0 ]; then
    CLAMAV_STATUS="clean"
else
    CLAMAV_STATUS="error"
fi
log "ENGINE: clamav status=${CLAMAV_STATUS} exit=${CLAMAV_EXIT} count=${CLAMAV_COUNT}"

# --- LOKI-RS ---------------------------------------------------------
# Flags chosen for an air-gap transfer scanner:
#   --no-tui, --no-html, --no-log : guest has no terminal or persistent
#                                   filesystem worth keeping reports on;
#                                   only --jsonl matters for verdict
#                                   parsing.
#   --no-procs                    : process scanning is irrelevant for a
#                                   file-transfer scanner and would scan
#                                   the guest's own processes anyway.
#   --scan-all-files              : extension-based filtering cannot be
#                                   trusted on adversarial input.
#   --max-file-size 4294967296    : 4 GiB cap. The upstream default is
#                                   64 MB, which would silently skip
#                                   anything larger — a false-negative
#                                   vector for a transfer scanner. The
#                                   value 0 does NOT mean "unlimited" in
#                                   LOKI-RS; it means "skip anything
#                                   larger than 0 bytes" (i.e. skip
#                                   everything). Use a concrete cap.
#   --threads 0                   : use all vCPUs (the guest is sized at
#                                   2 vCPUs in the Firecracker config).
#   --folder "$SCANDIR"           : scan the read-only mount, not /.
#
# LOKI-RS expects to find its signatures/ tree adjacent to the binary;
# we cd into its install dir before invocation.
log "--- LOKI-RS ---"
LOKI_EXIT=0
rm -f "$LOKI_OUT"
( cd "$LOKI_DIR" && ./loki \
    --no-tui --no-html --no-log --no-procs --scan-all-files \
    --max-file-size 4294967296 \
    --threads 0 \
    --folder "$SCANDIR" \
    --jsonl "$LOKI_OUT" ) > "$SERIAL" 2>&1 || LOKI_EXIT=$?
log "LOKI-RS exit: $LOKI_EXIT"

# Parse LOKI-RS findings. A finding at ALERT level (score ≥ 80, the
# upstream-recommended threshold) counts as a threat. WARNING and NOTICE
# are below the bar — including them would produce excessive false
# positives.
#
# Per-engine summary follows the same conventions as ClamAV's: status is
# independent of count.
LOKI_COUNT=0
if [ -f "$LOKI_OUT" ]; then
    LOKI_COUNT=$(count_lines '"level":"ALERT"' "$LOKI_OUT")
    LOKI_COUNT="${LOKI_COUNT:-0}"
fi
if [ "$LOKI_COUNT" -gt 0 ]; then
    LOKI_STATUS="threat"
elif [ "$LOKI_EXIT" -eq 0 ]; then
    LOKI_STATUS="clean"
else
    LOKI_STATUS="error"
fi
log "ENGINE: loki status=${LOKI_STATUS} exit=${LOKI_EXIT} count=${LOKI_COUNT}"

# --- Verdict combination (OR semantics) ------------------------------
# Threat from either engine → red. Clean requires both engines to have
# completed cleanly. Anything else (one or both engines errored without
# finding a threat) → ERROR, which the host treats as yellow.
if [ "$CLAMAV_STATUS" = "threat" ] || [ "$LOKI_STATUS" = "threat" ]; then
    log "VERDICT: THREAT DETECTED"
elif [ "$CLAMAV_STATUS" = "clean" ] && [ "$LOKI_STATUS" = "clean" ]; then
    log "VERDICT: CLEAN"
else
    log "VERDICT: ERROR (clamav=${CLAMAV_STATUS} loki=${LOKI_STATUS})"
fi

log "Shutting down guest..."
sync
# busybox doesn't ship a 'reboot' applet by default; trigger kernel reboot
# via sysrq instead.
echo b > /proc/sysrq-trigger