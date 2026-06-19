#!/usr/bin/env bash
# scripts/lib/verify-artefact.sh
#
# Single implementation of the sidecar produce/verify protocol. Sourced,
# not executed. Replaces three hand-rolled copies (build-scanner-image.sh
# emission, prepare-data-usb.sh verification, troskel-build.sh phase 5
# verification) that could drift independently and once did: the
# "sidecar absolute path" bug (bug 2) existed because each site rolled its
# own and one baked an absolute path into the sidecar, causing verification
# to follow that path back to the source on the host rather than reading the
# copy on the USB. Verification then passed against a USB that may never have
# been written. This module makes that failure mode impossible by
# construction: the producer emits a basename-only sidecar, and the consumer
# refuses any sidecar whose path field is absolute or contains a directory
# separator, resolving the artefact strictly as <mount_dir>/<basename>.
#
# ── PROTOCOL CONTRACT ─────────────────────────────────────────────────────────
# A sidecar is a single line in GNU coreutils `sha256sum` format:
#
#     <64 lowercase hex chars><two spaces><basename>
#
# The two-space separator is the `sha256sum` convention (one space for the
# mode indicator, one separator). The basename field MUST be a bare filename:
# no leading slash, no embedded slash, no "..". This is the whole point of the
# module. Sidecars emitted here are byte-identical to `sha256sum <basename>`
# run from the file's own directory, so they remain interoperable with
# `sha256sum --check` and with sidecars already written to existing USBs.
#
# Producer:  verify_artefact_emit <artefact_path>
#   Writes <artefact_path>.sha256 next to the artefact, containing the hash
#   and the artefact's BASENAME only. Returns 0 on success, non-zero if the
#   artefact does not exist or the write fails. Never writes an absolute path.
#
# Consumer:  verify_artefact_check <mount_dir> <sidecar_path>
#   Reads <sidecar_path>, resolves the artefact as <mount_dir>/<basename>
#   (NEVER as the sidecar's literal path field), hashes it, and compares.
#   Prints one of the result tokens below to stdout and returns the matching
#   exit code. The caller keys on the exit code; the stdout token is for logs.
#
# Result tokens / exit codes (consumer):
#   VERIFIED          0   artefact present and hash matches
#   MISMATCH_ON_DISK  3   artefact present, hash differs (corruption/truncation)
#   MISSING_FILE      4   artefact named by the sidecar is absent from mount_dir
#   MALFORMED_SIDECAR 5   sidecar empty, wrong shape, or path field unsafe
#                         (absolute, contains '/', or contains '..')
#   (usage error      2   wrong number of arguments to a function)
#
# Exit codes start at 3 to stay clear of bash conventions (0 success, 1
# generic error, 2 misuse) so a caller can distinguish a protocol result from
# an interpreter-level failure.
#
# Consumers in the tree (keep this list current):
#   - scripts/prepare-data-usb.sh         (verify, USB mount)
#   - scripts/troskel-build.sh phase 5    (verify, USB mount)
# Producer in the tree:
#   - scripts/build-scanner-image.sh      (emit, alongside scanner-rootfs.ext4)
#
# Tests: tests/test-verify-artefact.sh exercises every result variant,
# including the absolute-path and traversal rejections that correspond to the
# historical bug. Any change to the format or the result set must update that
# test in the same commit.

# Guard against direct execution. Sourcing is the supported mode.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    echo "[!] scripts/lib/verify-artefact.sh must be sourced, not executed." >&2
    echo "    Use: source scripts/lib/verify-artefact.sh" >&2
    exit 1
fi

# Result tokens as readonly names so callers may reference them symbolically
# and a typo becomes an unbound-variable error rather than a silent miss.
# Guard the readonly declarations so re-sourcing the module does not abort
# under `set -e` with "readonly variable" errors.
if [ -z "${VERIFY_ARTEFACT_TOKENS_DEFINED:-}" ]; then
    readonly VERIFY_VERIFIED="VERIFIED"
    readonly VERIFY_MISMATCH="MISMATCH_ON_DISK"
    readonly VERIFY_MISSING="MISSING_FILE"
    readonly VERIFY_MALFORMED="MALFORMED_SIDECAR"
    readonly VERIFY_RC_VERIFIED=0
    readonly VERIFY_RC_MISMATCH=3
    readonly VERIFY_RC_MISSING=4
    readonly VERIFY_RC_MALFORMED=5
    readonly VERIFY_RC_USAGE=2
    readonly VERIFY_ARTEFACT_TOKENS_DEFINED=1
fi

# Compute the SHA-256 of a file, printing the 64-hex digest only (no
# filename, no trailing space). Single chokepoint so the hash tool is named
# in exactly one place. coreutils sha256sum is in the build container.
_verify_artefact_hash() {
    sha256sum "$1" | awk '{print $1}'
}

# Producer. Emit <artefact>.sha256 next to the artefact, basename-only.
#
# Implementation note: we `cd` into the artefact's directory and run
# sha256sum on the bare basename, so the filename field in the output is the
# basename by construction. This is the same trick the old inline code used,
# now in one place. We then sanity-check our own output (defence in depth:
# if some future coreutils emitted a path, we catch it here rather than
# shipping a poisoned sidecar).
verify_artefact_emit() {
    if [ "$#" -ne 1 ]; then
        echo "[!] verify_artefact_emit: usage: verify_artefact_emit <artefact_path>" >&2
        return "$VERIFY_RC_USAGE"
    fi
    local artefact="$1"
    if [ ! -f "$artefact" ]; then
        echo "[!] verify_artefact_emit: artefact not found: $artefact" >&2
        return "$VERIFY_RC_MISSING"
    fi
    local dir base sidecar
    dir="$(dirname "$artefact")"
    base="$(basename "$artefact")"
    sidecar="${artefact}.sha256"

    ( cd "$dir" && sha256sum "$base" ) > "$sidecar" || {
        echo "[!] verify_artefact_emit: failed to write sidecar: $sidecar" >&2
        rm -f "$sidecar"
        return 1
    }

    # Post-condition: the sidecar we just wrote must itself parse as a safe,
    # basename-only sidecar. If it does not, the protocol is broken at the
    # producer and we must not ship it. This is the producer half of the
    # invariant the consumer relies on.
    local line file_field
    line="$(head -n1 "$sidecar")"
    file_field="$(printf '%s' "$line" | sed 's/^[0-9a-f]\{64\}  //')"
    if ! printf '%s' "$line" | grep -qE '^[0-9a-f]{64}  [^/]+$' \
        || [ "$file_field" = ".." ] \
        || printf '%s' "$file_field" | grep -q '/' ; then
        echo "[!] verify_artefact_emit: produced an unsafe sidecar (not basename-only):" >&2
        echo "      $line" >&2
        rm -f "$sidecar"
        return 1
    fi
    return 0
}

# Consumer. Verify the artefact named by a sidecar against a mount point.
# Prints a result token and returns the matching exit code.
verify_artefact_check() {
    if [ "$#" -ne 2 ]; then
        echo "[!] verify_artefact_check: usage: verify_artefact_check <mount_dir> <sidecar_path>" >&2
        return "$VERIFY_RC_USAGE"
    fi
    local mount_dir="$1" sidecar="$2"

    # The sidecar file itself must exist and be non-empty.
    if [ ! -s "$sidecar" ]; then
        echo "$VERIFY_MALFORMED"
        echo "[!] sidecar missing or empty: $sidecar" >&2
        return "$VERIFY_RC_MALFORMED"
    fi

    local line
    line="$(head -n1 "$sidecar")"

    # Shape check: exactly 64 lowercase hex, two spaces, then a filename that
    # contains no slash. This single regex rejects: empty/garbage lines, the
    # wrong hash length, uppercase hex, a missing filename, AND any absolute
    # path or path with a directory component (the historical bug). The
    # explicit ".." check below covers a bare "filename of .." which has no
    # slash but is still a traversal.
    if ! printf '%s' "$line" | grep -qE '^[0-9a-f]{64}  [^/]+$'; then
        echo "$VERIFY_MALFORMED"
        echo "[!] sidecar not in safe 'sha256sum <basename>' form: $line" >&2
        echo "    A path field that is absolute or contains '/' is rejected here;" >&2
        echo "    this is the guard against verifying the source instead of the copy." >&2
        return "$VERIFY_RC_MALFORMED"
    fi

    local expected_hash file_field
    expected_hash="$(printf '%s' "$line" | awk '{print $1}')"
    file_field="$(printf '%s' "$line" | sed 's/^[0-9a-f]\{64\}  //')"

    if [ "$file_field" = ".." ] || [ "$file_field" = "." ]; then
        echo "$VERIFY_MALFORMED"
        echo "[!] sidecar filename field is a directory traversal: '$file_field'" >&2
        return "$VERIFY_RC_MALFORMED"
    fi

    # Resolve the artefact strictly under the mount point. We use the
    # basename from the sidecar but join it to the CALLER's mount_dir, never
    # trusting the sidecar to tell us where the file lives.
    local artefact="${mount_dir%/}/${file_field}"

    if [ ! -f "$artefact" ]; then
        echo "$VERIFY_MISSING"
        echo "[!] artefact named by sidecar not present at: $artefact" >&2
        return "$VERIFY_RC_MISSING"
    fi

    local actual_hash
    actual_hash="$(_verify_artefact_hash "$artefact")"

    if [ "$actual_hash" = "$expected_hash" ]; then
        echo "$VERIFY_VERIFIED"
        return "$VERIFY_RC_VERIFIED"
    else
        echo "$VERIFY_MISMATCH"
        echo "[!] hash mismatch for $artefact" >&2
        echo "    expected: $expected_hash" >&2
        echo "    actual  : $actual_hash" >&2
        return "$VERIFY_RC_MISMATCH"
    fi
}