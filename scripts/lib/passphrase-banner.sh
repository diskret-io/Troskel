#!/usr/bin/env bash
# scripts/lib/passphrase-banner.sh
#
# Single implementation of the per-build scanner-passphrase banner protocol.
# Sourced, not executed. Replaces a producer/consumer pair that lived as
# uncommented copies in two scripts: prepare-boot-usb.sh printed the banner
# with echo lines, and troskel-build.sh re-derived the passphrase with an
# inline awk state machine that keyed on the banner's exact layout. The two
# could drift independently: a well-meaning edit to the banner wording or the
# "====" rules in the producer would silently stop the consumer's awk from
# matching, caught only at runtime when a full boot-USB build aborted on the
# emptiness guard. Co-locating producer and consumer here makes the coupling
# visible and testable: tests/test-passphrase-banner.sh round-trips the two and
# asserts the passphrase survives, so a layout change that breaks extraction
# fails in Tier 1 rather than in front of an operator.
#
# ── PROTOCOL CONTRACT ─────────────────────────────────────────────────────────
# The banner is a block of lines written to stdout by the producer:
#
#     ============================================================
#       SCANNER PASSPHRASE
#     ============================================================
#
#         <passphrase>
#
#       <explanatory text...>
#     ============================================================
#
# The consumer extracts <passphrase> from a captured copy of that stdout. The
# extraction depends on exactly three invariants, and ONLY these three. The
# explanatory wording, indentation, and any decorative title suffix are free
# to change; these three are not, without updating both sides in one commit:
#
#   1. A line containing the literal string "SCANNER PASSPHRASE" opens the
#      block (the header).
#   2. A line beginning with "====" closes the header. The passphrase is the
#      FIRST non-empty line after that rule. Nothing other than blank lines
#      may sit between the header rule and the passphrase: do not move
#      explanatory text above the passphrase.
#   3. A line beginning with "====" closes the block, after the passphrase.
#
# Producer:  emit_passphrase_banner <passphrase>
#   Writes the banner block above to stdout. The passphrase is printed as the
#   first non-empty line after the header rule, satisfying invariant 2 by
#   construction. Returns 0; returns non-zero (and writes nothing) if called
#   with an empty passphrase, since an empty passphrase banner would extract
#   to nothing and trip the consumer's emptiness guard with no useful cause.
#
# Consumer:  extract_passphrase <captured-output-file>
#   Reads the file, applies the three-invariant awk, and prints the captured
#   passphrase line to stdout (leading whitespace preserved; the caller is
#   responsible for trimming for display, as troskel-build.sh's summary does).
#   Prints nothing and returns non-zero if no passphrase line is found, which
#   is the signal the orchestrator's mandatory emptiness check keys on. The
#   consumer does NOT decide what to do about a miss; failing closed is the
#   caller's job. This keeps the extractor pure and testable.
#
# Producer in the tree:
#   - scripts/prepare-boot-usb.sh   (prints the banner after writing the USB)
# Consumer in the tree:
#   - scripts/troskel-build.sh      (captures the boot script's stdout via
#                                    run_step KEEP_OUT, then extracts here)
#
# Tests: tests/test-passphrase-banner.sh round-trips producer -> consumer and
# exercises the miss cases (no banner, empty block, text wrongly placed before
# the passphrase). Any change to the invariants above must update that test in
# the same commit.

# Guard against direct execution. Sourcing is the supported mode.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    echo "[!] scripts/lib/passphrase-banner.sh must be sourced, not executed." >&2
    echo "    Use: source scripts/lib/passphrase-banner.sh" >&2
    exit 1
fi

# emit_passphrase_banner <passphrase>
# See PROTOCOL CONTRACT (producer). Prints the banner to stdout. The passphrase
# is the first non-empty line after the header rule by construction, so the
# producer cannot, on its own, violate invariant 2.
emit_passphrase_banner() {
    local passphrase="$1"

    # Failure mode: an empty passphrase would print a banner that the consumer
    # extracts to nothing, tripping the orchestrator's emptiness guard with a
    # misleading "format may have changed" message when the real fault is an
    # empty argument here. Refuse loudly at the source instead.
    if [ -z "$passphrase" ]; then
        echo "[!] emit_passphrase_banner: refusing to print an empty passphrase." >&2
        return 1
    fi

    echo "============================================================"
    echo "  SCANNER PASSPHRASE"
    echo "============================================================"
    echo ""
    echo "    ${passphrase}"
    echo ""
    echo "  WRITE THIS DOWN NOW. It is not stored anywhere and cannot"
    echo "  be recovered once this script exits. You need it to log in"
    echo "  as the user 'scanner' on the scanning host."
    echo "============================================================"
}

# extract_passphrase <captured-output-file>
# See PROTOCOL CONTRACT (consumer). Prints the passphrase line (leading
# whitespace preserved) and returns 0 on success; prints nothing and returns 1
# if no passphrase line is found. The awk is the single source of truth for the
# three invariants; troskel-build.sh no longer carries its own copy.
extract_passphrase() {
    local captured="$1" out

    if [ ! -f "$captured" ]; then
        return 1
    fi

    # The three invariants, in awk:
    #   - "SCANNER PASSPHRASE" present  -> enter header mode
    #   - "====" while in header        -> header closed, enter passphrase mode
    #   - "====" while in passphrase     -> block closed, stop
    #   - first non-empty line in passphrase mode is the passphrase
    out="$(awk '
        /SCANNER PASSPHRASE/        { in_header=1; next }
        in_header && /^====/        { in_header=0; in_pass=1; next }
        in_pass && /^====/          { exit }
        in_pass && NF && !captured  { print $0; captured=1 }
    ' "$captured")"

    # Post-condition: a non-empty capture is the only success. An empty result
    # means one of the invariants did not hold (no banner, empty block, or the
    # first post-header line was blank all the way to the closing rule). Report
    # the miss via exit code; the caller decides how loudly to fail.
    if [ -z "$out" ]; then
        return 1
    fi

    printf '%s\n' "$out"
}