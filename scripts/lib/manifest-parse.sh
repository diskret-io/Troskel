#!/usr/bin/env bash
# scripts/lib/manifest-parse.sh
# Canonical host-side parser for build-manifest.json.
#
# This file is the SINGLE SOURCE OF TRUTH for how the air-gapped scanning host
# reads build-manifest.json. It is NOT sourced at runtime by the host scripts:
# those deploy standalone to /usr/local/bin via the Butane config (see
# config/scanner-host.bu), with no scripts/lib present on the host. Instead, the
# region between the BEGIN/END sentinels below is VENDORED verbatim into
# config/host-scripts/load-scanner and config/host-scripts/show-status, and
# tests/test-manifest-propagation.sh asserts all three copies are byte-identical.
# That keeps one definition without adding a runtime dependency to the host.
#
# PROTOCOL CONTRACT (consumer side, shared by load-scanner and show-status)
# -------------------------------------------------------------------------
# The manifest is produced by scripts/generate-build-records.sh and written to
# the data USB by scripts/prepare-data-usb.sh, which verifies it against the USB
# at write time (sha256 byte-identity plus a jq field-presence predicate). The
# build station has jq; the scanning host does not, so host verification is
# grep/sed only, defined here. The field set MUST stay in step with the jq
# predicate in prepare-data-usb.sh: if generate-build-records.sh adds or renames
# a build-identity field the host displays, change the matcher here AND that
# predicate together, then re-vendor (the drift test will fail until you do), or
# a manifest the host cannot read would still pass write-time verification.
#
# Two value shapes appear and need different matchers:
#   - generated_at, troskel_commit : quoted JSON strings.
#   - troskel_dirty                : an UNQUOTED JSON boolean
#     (generate-build-records.sh emits `"troskel_dirty": false`, no quotes).
# An earlier inline copy used the quoted-string matcher for troskel_dirty; it
# never matched, so "Tree clean" always printed "unknown". That bug is why
# troskel_dirty has its own matcher and why this is now one vendored definition.
#
# Public function:
#   manifest_parse <path>
#     On a readable manifest with all three required fields present, sets the
#     globals below and prints "ok". On a file that exists but yields no usable
#     required field set, prints "corrupt" and returns 1. The caller handles the
#     ABSENT case itself (file not existing) before calling; manifest_parse is
#     only meaningful on a file that exists.
#
#     Required-field rule: "ok" iff generated_at, troskel_commit AND
#     troskel_dirty all extract non-empty. Any one missing is "corrupt". The
#     strict reading: a manifest that has dropped a displayed field is reported,
#     not partially shown, so the operator can tell corrupt from an old USB.
#
#   Globals set after a return of "ok":
#     MANIFEST_GENERATED  generated_at value
#     MANIFEST_COMMIT     troskel_commit value
#     MANIFEST_DIRTY      "true" | "false"

# >>> BEGIN manifest-parse vendored region (keep byte-identical across copies) >>>
_manifest_extract_str() {  # _manifest_extract_str <key> <path> -> quoted-string value or empty
    grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null \
        | head -1 \
        | sed 's/.*"\([^"]*\)"$/\1/'
}

_manifest_extract_dirty() {  # _manifest_extract_dirty <path> -> true|false or empty
    grep -o "\"troskel_dirty\"[[:space:]]*:[[:space:]]*\(true\|false\)" "$1" 2>/dev/null \
        | head -1 \
        | grep -o '\(true\|false\)$'
}

manifest_parse() {  # manifest_parse <path> ; sets MANIFEST_* globals, prints ok|corrupt
    local path="$1"
    MANIFEST_GENERATED="$(_manifest_extract_str generated_at "$path")"
    MANIFEST_COMMIT="$(_manifest_extract_str troskel_commit "$path")"
    MANIFEST_DIRTY="$(_manifest_extract_dirty "$path")"
    if [ -n "$MANIFEST_GENERATED" ] && [ -n "$MANIFEST_COMMIT" ] && [ -n "$MANIFEST_DIRTY" ]; then
        printf 'ok\n'
        return 0
    fi
    printf 'corrupt\n'
    return 1
}
# <<< END manifest-parse vendored region <<<