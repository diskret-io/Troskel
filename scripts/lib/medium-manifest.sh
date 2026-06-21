#!/usr/bin/env bash
# scripts/lib/medium-manifest.sh
# Directory-level operations for the signed TROSKEL-DATA medium manifest.
# Sourced by the producer (scripts/sign-data-usb.sh, on the offline signing
# machine) and the consumer (config/host-scripts/load-scanner, on the
# air-gapped scanning host). Operating on a directory rather than a device is
# what lets both the device scripts and the hermetic test exercise identical
# logic: the producer and consumer compute the file set the SAME way, so the
# set-equality contract cannot drift between them.
#
# This module is the single definition of:
#   - which files on the medium are covered by the signature (the walk),
#   - the manifest's on-disk shape,
#   - the set-equality check the host enforces on load.
#
# It does NOT mount, unmount, or touch devices. Callers pass a directory that
# is the mounted medium root. It does NOT embed or distribute keys; callers
# pass key paths. Cryptographic primitive: raw ed25519 via `openssl pkeyutl`.
#
# CONTRACT (shared by producer and consumer)
# ------------------------------------------
# Manifest file name : medium-manifest.json   (MEDIUM_MANIFEST_NAME)
# Signature file name: medium-manifest.json.sig (MEDIUM_SIG_NAME)
# Covered file set   : every regular file at the medium root EXCEPT those two.
#                      The medium is flat (-maxdepth 1); the producer emits no
#                      subdirectories, and the consumer's set check treats any
#                      file not reachable by this same walk as absent from the
#                      manifest (hence rejected). Names are bare basenames; a
#                      path component in a manifest name is a protocol
#                      violation (mirrors the verify-artefact sidecar rule).
# Manifest shape     : {"manifest_version":"1","troskel_commit":..,
#                      "troskel_dirty":bool,"generated_at":..,
#                      "files":[{"name":..,"sha256":..},..]}
# Signature          : raw ed25519 over the exact bytes of the manifest file,
#                      `openssl pkeyutl -sign -rawin`, 64 bytes, detached.
#
# Result tokens (printed on stdout; callers key on the EXIT CODE, the token is
# for logs). openssl prints its own pass/fail string to stdout AND sets rc, so
# downstream logic must never grep that string; it keys on rc only.
MEDIUM_MANIFEST_NAME="medium-manifest.json"
MEDIUM_SIG_NAME="medium-manifest.json.sig"

MM_OK="OK"
MM_BAD_SIG="BAD_SIGNATURE"        # signature does not verify against manifest+key
MM_MISSING_SIG="MISSING_SIGNATURE" # manifest and/or signature absent
MM_MALFORMED="MALFORMED_MANIFEST"  # manifest not parseable / wrong shape / bad name field
MM_SET_MISMATCH="SET_MISMATCH"     # medium files != manifest files
MM_HASH_MISMATCH="HASH_MISMATCH"   # a named file's bytes do not match its hash

# medium_manifest_filelist <dir>
# Prints, one per line LC_ALL=C-sorted, the basenames of every regular file at
# the medium root except the manifest and signature. Single definition of "the
# covered set" so producer and consumer cannot disagree.
medium_manifest_filelist() {
    local dir="$1"
    find "$dir" -maxdepth 1 -type f \
        ! -name "$MEDIUM_MANIFEST_NAME" \
        ! -name "$MEDIUM_SIG_NAME" \
        -printf '%f\n' | LC_ALL=C sort
}

# medium_manifest_build <dir> <commit> <dirty:true|false> <generated_at>
# Walks <dir>, hashes each covered file, prints the manifest JSON on stdout.
# Returns non-zero if the directory contains no covered files (a manifest over
# nothing is never legitimate here and must not be signed).
medium_manifest_build() {
    local dir="$1" commit="$2" dirty="$3" gen="$4" entries count
    entries="$(
        medium_manifest_filelist "$dir" | while IFS= read -r name; do
            # A name with a slash cannot occur from -printf '%f', but assert it
            # so a future change to the walk cannot silently admit a path.
            case "$name" in */*|"") echo "__BAD__"; break;; esac
            local sum
            sum="$(sha256sum "${dir}/${name}" | awk '{print $1}')"
            jq -nc --arg n "$name" --arg s "$sum" '{name:$n, sha256:$s}'
        done | jq -sc '.'
    )"
    case "$entries" in *__BAD__*) echo "[!] medium_manifest_build: path in filename" >&2; return 2;; esac
    count="$(printf '%s' "$entries" | jq 'length')"
    [ "$count" -ge 1 ] || { echo "[!] medium_manifest_build: no covered files" >&2; return 2; }
    jq -n \
        --arg ver "1" --arg commit "$commit" --arg dirty "$dirty" \
        --arg gen "$gen" --argjson files "$entries" \
        '{manifest_version:$ver, troskel_commit:$commit,
          troskel_dirty:($dirty=="true"), generated_at:$gen, files:$files}'
}

# medium_manifest_sign <dir> <private-key.pem>
# Signs the manifest already present in <dir> with the offline key, writing the
# detached signature into <dir>. Caller is responsible for the manifest already
# being on disk and for mount rw-ness. Returns non-zero on any openssl failure.
medium_manifest_sign() {
    local dir="$1" key="$2"
    openssl pkeyutl -sign -inkey "$key" -rawin \
        -in "${dir}/${MEDIUM_MANIFEST_NAME}" \
        -out "${dir}/${MEDIUM_SIG_NAME}"
}

# medium_manifest_verify_sig <dir> <public-key.pem>
# Verifies the detached signature in <dir> against the manifest in <dir> and
# the given public key. This is the AUTHENTICITY check. Prints a result token;
# RETURN CODE is the signal (0 = OK). Keys on openssl's exit code, never its
# printed string. Distinguishes "missing" from "bad" so the host can tell an
# unsigned/legacy medium from a tampered one.
medium_manifest_verify_sig() {
    local dir="$1" pub="$2"
    if [ ! -f "${dir}/${MEDIUM_MANIFEST_NAME}" ] || [ ! -f "${dir}/${MEDIUM_SIG_NAME}" ]; then
        echo "$MM_MISSING_SIG"; return 4
    fi
    # A structurally broken manifest must not be hashed/verified as if valid.
    if ! jq -e '.manifest_version == "1" and (.files|type=="array") and (.files|length>=1)' \
            "${dir}/${MEDIUM_MANIFEST_NAME}" >/dev/null 2>&1; then
        echo "$MM_MALFORMED"; return 5
    fi
    if openssl pkeyutl -verify -pubin -inkey "$pub" -rawin \
            -in "${dir}/${MEDIUM_MANIFEST_NAME}" \
            -sigfile "${dir}/${MEDIUM_SIG_NAME}" >/dev/null 2>&1; then
        echo "$MM_OK"; return 0
    fi
    echo "$MM_BAD_SIG"; return 3
}

# medium_manifest_verify_set <dir>
# Enforces set equality: the covered files on the medium must be EXACTLY the
# files named in the manifest. Catches an injected file (on medium, not in
# manifest) and a removed/substituted file (in manifest, not on medium). Must
# be called only AFTER the signature has verified, because it trusts the
# manifest's file list. Return code is the signal.
medium_manifest_verify_set() {
    local dir="$1" disk manifest
    disk="$(medium_manifest_filelist "$dir")"
    manifest="$(jq -r '.files[].name' "${dir}/${MEDIUM_MANIFEST_NAME}" 2>/dev/null | LC_ALL=C sort)"
    # Reject any manifest name carrying a path component before comparing.
    if printf '%s\n' "$manifest" | grep -q '/'; then
        echo "$MM_MALFORMED"; return 5
    fi
    if [ "$disk" != "$manifest" ]; then
        echo "$MM_SET_MISMATCH"; return 6
    fi
    echo "$MM_OK"; return 0
}

# medium_manifest_pubkey_fingerprint <key.pem> [pubin]
# Prints a canonical fingerprint of a public key: the SHA-256 of its DER
# encoding. This is immune to PEM formatting noise (trailing newlines, blank
# lines, line-wrap differences), which a naive text comparison is NOT: a public
# key file on disk typically carries a trailing newline that command-capture
# strips, so a byte comparison would report a false mismatch on a correct key.
# Always compare keys by this fingerprint, never by raw PEM text.
#
# With no second argument the input is treated as a PRIVATE key and its public
# half is derived. With "pubin" the input is treated as a PUBLIC key. Both
# routes emit the SAME fingerprint for the same underlying key, which is what
# lets the keypair-match check below work: derive from the private key, compare
# to the supplied public key.
#
# Shared by the signer's optional cross-check (scripts/sign-data-usb.sh) and
# the boot-build drift check (scripts/prepare-boot-usb.sh), so both sites
# canonicalise keys identically and cannot disagree on whether two keys match.
medium_manifest_pubkey_fingerprint() {
    local key="$1" mode="${2:-}"
    if [ "$mode" = "pubin" ]; then
        openssl pkey -pubin -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
    else
        openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
    fi
}

# medium_manifest_keypair_matches <private-key.pem> <public-key.pem>
# Returns 0 if the private key's public half equals the given public key, i.e.
# they are the same keypair; non-zero otherwise. Used by the signer to refuse
# signing with a key the target host will not trust (the silent self-mismatch
# failure mode). A blank fingerprint (unreadable key) never compares equal, so
# an unreadable key is treated as a mismatch, not a pass.
medium_manifest_keypair_matches() {
    local priv="$1" pub="$2" fp_priv fp_pub
    fp_priv="$(medium_manifest_pubkey_fingerprint "$priv")"
    fp_pub="$(medium_manifest_pubkey_fingerprint "$pub" pubin)"
    [ -n "$fp_priv" ] && [ -n "$fp_pub" ] && [ "$fp_priv" = "$fp_pub" ]
}

# medium_manifest_verify_hashes <dir>
# Checks every file named in the (already signature-verified, already
# set-verified) manifest against its recorded SHA-256, re-reading from <dir>.
# This is the INTEGRITY layer riding on the now-trusted hashes. Return code is
# the signal; on the first mismatch it reports the offending file and stops.
medium_manifest_verify_hashes() {
    local dir="$1" name want got
    while IFS=$'\t' read -r name want; do
        [ -n "$name" ] || continue
        got="$(sha256sum "${dir}/${name}" 2>/dev/null | awk '{print $1}')"
        if [ "$got" != "$want" ]; then
            echo "$MM_HASH_MISMATCH ${name}"; return 7
        fi
    done < <(jq -r '.files[] | "\(.name)\t\(.sha256)"' "${dir}/${MEDIUM_MANIFEST_NAME}")
    echo "$MM_OK"; return 0
}