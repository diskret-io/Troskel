#!/bin/sh
# Guest scan entrypoint. Runs inside the Firecracker microVM.
#
# Two engines run sequentially over the read-only scan target. Their
# verdicts are combined under OR semantics — either engine flagging a
# threat produces a red verdict (see architecture.md, "Why two engines").
#
#   ClamAV   — exit 0 = clean, 1 = infected, anything else = error.
#   LOKI-RS  — exit code is not a reliable verdict signal; we parse the
#              JSONL output for findings at ALERT severity (score ≥ 80).
#              The exit code is consulted only to detect hard failures.
#
# The host-side wrapper greps the serial log for the exact strings
# emitted below (THREAT DETECTED / CLEAN / ERROR). See the verdict
# pipeline notes in architecture.md for why guest and host both perform
# verdict logic. Each engine also emits an ENGINE: summary line that the
# host displays under the verdict block, so the operator sees which
# engine flagged what without scrolling through the full log.
set -eu
SCANDIR="/mnt/scanfiles"
SERIAL="/dev/ttyS0"
LOKI_DIR="/opt/loki-rs"
LOKI_OUT="/tmp/loki-scan.jsonl"
log() { echo "[$(date -u +%H:%M:%S)] $*" > "$SERIAL"; }

# Load engine config injected by build-scanner-image.sh.
# shellcheck source=/dev/null
[ -f /etc/troskel-engine.env ] && . /etc/troskel-engine.env
# Fallbacks: match the scanner.env defaults so the guest is safe even if
# the config file is absent (e.g. during a manual rootfs test).
LOKI_MAX_FILE_SIZE="${LOKI_MAX_FILE_SIZE:-4294967296}"
CLAM_MAX_FILE_SIZE="${CLAM_MAX_FILE_SIZE:-4294967296}"

# count_lines: robust replacement for `grep -c PAT FILE || echo 0`. The
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
# Flags chosen for an air-gap transfer scanner:
#   --recursive               : walk into subdirectories.
#   --infected                : emit one "FOUND" line per finding; suppress
#                               per-file scan summaries. The count parser
#                               greps the "FOUND" suffix.
#   --official-db-only=no     : permit third-party signature databases
#                               alongside the official .cvd files, in
#                               case a deployment ever adds one. Today
#                               only the official set is present.
#   --database=/var/lib/clamav: explicit database path.
#   --heuristic-alerts        : engage ClamAV's structural / format-aware
#                               detection (broken executables, encrypted
#                               documents, phishing-style URL constructs)
#                               in addition to signature matching. The
#                               findings appear as Heuristics.* signature
#                               names in the FOUND output, so the count
#                               parser handles them with no change.
#   --bytecode                : explicitly enable bytecode signatures
#                               (.cbc files in the database). On by
#                               default upstream, but stated explicitly
#                               so a future ClamAV config change cannot
#                               silently disable a detection capability.
#   --max-filesize / --max-scansize : explicit per-file and per-archive
#                               size caps. The upstream defaults (100 MiB
#                               and 400 MiB) silently skip larger content
#                               — a false-negative vector for a transfer
#                               scanner. Both are set to CLAM_MAX_FILE_SIZE
#                               from scanner.env (default 4 GiB).
#   --alert-encrypted, --alert-encrypted-archive, --alert-encrypted-doc :
#                               treat encrypted content as suspicious.
#                               The scanner cannot see inside an
#                               encrypted ZIP; passing it as clean
#                               would be a lie. Operator-facing red
#                               verdicts on legitimate password-protected
#                               archives are deliberate, the right
#                               response is to provide an unencrypted
#                               copy alongside, not to wave the
#                               unscanned bytes across the air gap.
#   --alert-broken, --alert-broken-media : flag malformed PE/ELF/media
#                               files. These are commonly used as
#                               deliberate evasion against signature
#                               scanners; a structurally invalid PE
#                               with a benign-looking extension is
#                               suspicious by construction.
#
# Note: --detect-pua (Potentially Unwanted Applications) is deliberately
# NOT enabled here. PUA detection brings false positives on dual-use
# tools (network scanners, password recovery utilities) that legitimate
# transfers may include. Enabling it without first calibrating against
# a corpus of expected transfers would produce excessive red verdicts
# in initial deployment. Revisit after 1.0.0 with operator feedback.
log "--- ClamAV ---"
CLAMAV_EXIT=0
CLAMAV_OUT="/tmp/clamav-scan.log"
clamscan --recursive --infected --official-db-only=no \
    --database=/var/lib/clamav \
    --heuristic-alerts \
    --bytecode \
    --max-filesize="$CLAM_MAX_FILE_SIZE" \
    --max-scansize="$CLAM_MAX_FILE_SIZE" \
    --alert-encrypted \
    --alert-encrypted-archive \
    --alert-encrypted-doc \
    --alert-broken \
    --alert-broken-media \
    "$SCANDIR" > "$CLAMAV_OUT" 2>&1 || CLAMAV_EXIT=$?
cat "$CLAMAV_OUT" > "$SERIAL"
# Diagnostic: log the captured output size. If this is 0, ClamAV produced
# no output at all and the count parser will report 0 regardless of exit
# code — the symptom we hit before --quiet was removed.
log "ClamAV output: $(wc -c < "$CLAMAV_OUT") bytes"
log "ClamAV exit: $CLAMAV_EXIT"

# Per-engine summary for ClamAV. Status is independent of count: a
# non-zero exit code with no findings is an error, not a threat.
# The count parser is unchanged from the signature-only invocation —
# every flag added above produces findings in the same "<path>: <name> FOUND"
# format, so the grep continues to count them correctly.
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
    --max-file-size "${LOKI_MAX_FILE_SIZE}" \
    --threads 0 \
    --alert-level 60 \
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
# Exit codes: 0=clean, 1=error, 2=warnings found (below alert threshold).
# With --alert-level 60, score>=60 becomes ALERT and exit code 1.
# Exit code 2 means findings exist but all scored below alert-level —
# treat as clean since no ALERTs were emitted.
if [ "$LOKI_COUNT" -gt 0 ]; then
    LOKI_STATUS="threat"
elif [ "$LOKI_EXIT" -eq 0 ] || [ "$LOKI_EXIT" -eq 2 ]; then
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