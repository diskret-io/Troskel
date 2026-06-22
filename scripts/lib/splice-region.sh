#!/usr/bin/env bash
# scripts/lib/splice-region.sh
# Build-time bundling: splice a named, sentinel-delimited region from a source
# lib into a target script, replacing the target's `# @@REGION:<name>@@` marker
# line with the region body. This is how shared shell code reaches the scanning
# host, which has no scripts/lib to source at runtime: the canonical code is
# authored once in a lib, and the build splices it into the host script before
# that script is baked into the boot image. There is no hand-maintained copy, so
# there is no drift to police.
#
# CONTRACT:
#   Source lib marks a region with, on their own lines:
#       # >>> BEGIN REGION:<name> >>>
#       ...region body...
#       # <<< END REGION:<name> <<<
#   Target script carries, on its own line, the marker:
#       # @@REGION:<name>@@
#   splice_region replaces that marker line with the region body (the lines
#   strictly BETWEEN the BEGIN/END sentinels, sentinels excluded). The result is
#   printed to stdout; the caller redirects it to the build copy.
#
# Named failure modes, all fatal (non-zero, nothing emitted), because a silent
# failure here would bake a host script with either no verification code or a
# stray marker:
#   - region not found in the source lib (typo, sentinel removed)
#   - marker not found in the target (the script does not expect this region)
#   - marker appears more than once (ambiguous: which one?)
# A successful splice is verified by the caller (the marker must be gone and the
# region's BEGIN sentinel content present); see prepare-boot-usb.sh.

# splice_region <source-lib> <region-name> <target-script> -> spliced script on stdout
splice_region() {
    local lib="$1" name="$2" target="$3"
    local begin="# >>> BEGIN REGION:${name} >>>"
    local end="# <<< END REGION:${name} <<<"
    local marker="# @@REGION:${name}@@"

    [ -f "$lib" ]    || { echo "[!] splice_region: source lib not found: $lib" >&2; return 1; }
    [ -f "$target" ] || { echo "[!] splice_region: target not found: $target" >&2; return 1; }

    # Extract the region body (strictly between sentinels).
    local body
    body="$(awk -v b="$begin" -v e="$end" '
        $0==b {inr=1; next}
        $0==e {inr=0; next}
        inr   {print}
    ' "$lib")"
    if [ -z "$body" ]; then
        echo "[!] splice_region: region '${name}' not found (or empty) in ${lib}" >&2
        return 1
    fi

    # The marker must appear exactly once in the target.
    local count
    count="$(grep -c -F -x "$marker" "$target" 2>/dev/null || true)"
    if [ "$count" -eq 0 ]; then
        echo "[!] splice_region: marker '${marker}' not found in ${target}" >&2
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "[!] splice_region: marker '${marker}' appears ${count} times in ${target}; must be unique" >&2
        return 1
    fi

    # Replace the marker line with the region body. awk with a sentinel var
    # avoids any regex interpretation of the marker or body content.
    awk -v marker="$marker" -v body="$body" '
        $0==marker { print body; next }
        { print }
    ' "$target"
}