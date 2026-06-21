#!/usr/bin/env bash
# scripts/lib/boot-sign-key.sh
# Boot-build half of the data-USB authenticity gate: decides whether the boot
# ISO is built as a SIGNING host (a verifier public key baked in) or a
# PERMISSIVE host (none), embeds the key into the Butane build copy, and
# verifies after compilation that the key actually baked into the Ignition
# matches the source key.
#
# Sourced by scripts/prepare-boot-usb.sh. Depends on scripts/lib/medium-manifest.sh
# for the canonical key fingerprint (so this site and the signer canonicalise
# keys identically). See docs/medium-authenticity-contract.md for the full
# behavioural contract; the host-type decision table below is its boot-build row.
#
# CONTRACT (producer side: baked verifier key)
# --------------------------------------------
# Consumer: config/host-scripts/load-scanner, which reads the public key from
# BAKED_KEY_PATH on the running host and verifies the data-USB signature against
# it. This script promises load-scanner that:
#   - On a SIGNING build, a valid PEM ed25519 public key is present at
#     BAKED_KEY_PATH (/etc/troskel/sign.pub) in the Ignition config, mode 0644,
#     and that key is byte-identical (by canonical fingerprint) to the key the
#     admin supplied in TROSKEL_SIGN_PUBKEY. The post-compile drift check below
#     guarantees this; a mismatch aborts the build.
#   - On a PERMISSIVE build, NO file exists at BAKED_KEY_PATH. load-scanner keys
#     its SIGNING-vs-PERMISSIVE behaviour on the presence of that file, so its
#     absence is the signal, and this script guarantees absence by removing the
#     sentinel block entirely from the Butane build copy.
# load-scanner must therefore treat "file present at BAKED_KEY_PATH" as "this is
# a SIGNING host" and "file absent" as "this is a PERMISSIVE host", and nothing
# else. If this path or that contract changes, update load-scanner in the same
# commit.
#
# The committed config/scanner-host.bu carries a sentinel line
# @@SIGN_PUBKEY_FILE_ENTRY@@ on its own line where the storage.files key entry
# belongs. This script replaces that sentinel in the BUILD COPY with either the
# real storage.files entry (SIGNING) or nothing (PERMISSIVE). The committed file
# never contains a key, only the sentinel.

BAKED_KEY_PATH="/etc/troskel/sign.pub"
SIGN_KEY_FILESDIR_NAME="troskel-sign.pub"   # name within Butane --files-dir (config/)
SIGN_PUBKEY_SENTINEL="@@SIGN_PUBKEY_FILE_ENTRY@@"

# boot_sign_resolve_mode
# Reads TROSKEL_SIGN_PUBKEY and TROSKEL_ALLOW_UNSIGNED and prints one of:
#   "signing <path>"   a key was supplied; build a SIGNING host
#   "permissive"       opt-out flag set, no key; build a PERMISSIVE host
# or aborts the build (non-zero) on the two ambiguous combinations. This runs
# BEFORE the ISO download so an ambiguous invocation fails fast and cheap, not
# after a multi-hundred-MB download. The named failure mode here is not "no key"
# but "no key, yet the operator believed there was one": silence must never
# resolve to a permissive host, so neither-set is a hard abort with guidance.
boot_sign_resolve_mode() {
    local key="${TROSKEL_SIGN_PUBKEY:-}"
    local allow="${TROSKEL_ALLOW_UNSIGNED:-}"

    if [ -n "$key" ] && [ -n "$allow" ]; then
        echo "[!] Both TROSKEL_SIGN_PUBKEY and TROSKEL_ALLOW_UNSIGNED are set." >&2
        echo "    These are contradictory: one bakes a verifier key, the other" >&2
        echo "    asks for a host that enforces nothing. Refusing to guess." >&2
        echo "    Set exactly one." >&2
        return 1
    fi
    if [ -n "$key" ]; then
        if [ ! -f "$key" ]; then
            echo "[!] TROSKEL_SIGN_PUBKEY points at a missing file: ${key}" >&2
            return 1
        fi
        if ! openssl pkey -pubin -in "$key" -noout 2>/dev/null; then
            echo "[!] TROSKEL_SIGN_PUBKEY is not a readable public key: ${key}" >&2
            return 1
        fi
        echo "signing ${key}"
        return 0
    fi
    if [ -n "$allow" ]; then
        echo "permissive"
        return 0
    fi
    # Neither set: the dangerous ambiguity. Abort with both remedies.
    echo "[!] No signing key supplied and unsigned operation not explicitly" >&2
    echo "    requested. Refusing to build a host whose authenticity posture" >&2
    echo "    was not chosen deliberately." >&2
    echo "" >&2
    echo "    To build a SIGNING host (recommended): generate a key with" >&2
    echo "      make gen-signing-key" >&2
    echo "    then re-run with TROSKEL_SIGN_PUBKEY=/path/to/troskel-sign.pub" >&2
    echo "" >&2
    echo "    To build a PERMISSIVE host that does NOT verify medium" >&2
    echo "    authenticity, re-run with TROSKEL_ALLOW_UNSIGNED=1" >&2
    return 1
}

# boot_sign_apply_mode <mode> <key-path-or-empty> <config-build-copy> <files-dir>
# Given the resolved mode, prepares the Butane build copy and files-dir:
#   SIGNING    -> copy the key into <files-dir>/<SIGN_KEY_FILESDIR_NAME> and
#                 replace the sentinel with the storage.files entry that embeds
#                 it at BAKED_KEY_PATH.
#   PERMISSIVE -> remove the sentinel line entirely (no key entry).
# The sed for the SIGNING entry writes a small YAML block; the indentation
# matches the existing storage.files entries (4-space list item under
# "  files:"). A trailing newline on the source key is harmless (the fingerprint
# comparison canonicalises it away), but we copy the key verbatim so the baked
# bytes equal the source bytes for any consumer that reads them directly.
boot_sign_apply_mode() {
    local mode="$1" key="$2" cfg="$3" filesdir="$4"
    case "$mode" in
        signing)
            cp "$key" "${filesdir}/${SIGN_KEY_FILESDIR_NAME}"
            # Build the storage.files entry. Use a temp file for the multi-line
            # replacement so sed does not have to embed newlines awkwardly.
            local entry
            entry="$(cat <<YAML
    - path: ${BAKED_KEY_PATH}
      mode: 0644
      contents:
        local: ${SIGN_KEY_FILESDIR_NAME}
YAML
)"
            # Replace the sentinel line with the entry. awk handles the
            # multi-line insertion cleanly where sed would need escaping.
            awk -v sent="$SIGN_PUBKEY_SENTINEL" -v repl="$entry" '
                index($0, sent) { print repl; next } { print }
            ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
            ;;
        permissive)
            # Remove the sentinel line entirely; no key entry is emitted.
            awk -v sent="$SIGN_PUBKEY_SENTINEL" '
                index($0, sent) { next } { print }
            ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
            ;;
        *)
            echo "[!] boot_sign_apply_mode: unknown mode '$mode'" >&2
            return 1
            ;;
    esac
}

# boot_sign_extract_baked_key <ignition.json>
# Prints the PEM bytes of the public key baked at BAKED_KEY_PATH in the compiled
# Ignition, by decoding its data-URL contents.source. Prints nothing and returns
# non-zero if no such file entry exists (which is the correct, expected result
# for a PERMISSIVE build). Butane embeds a local file's contents as a
# "data:;base64,<payload>" (or "data:<mediatype>;base64,<payload>") URL; we take
# everything after "base64," and decode it.
boot_sign_extract_baked_key() {
    local ign="$1" src
    src="$(jq -r --arg p "$BAKED_KEY_PATH" \
        '.storage.files[]? | select(.path==$p) | .contents.source // empty' "$ign" 2>/dev/null)"
    [ -n "$src" ] || return 1
    case "$src" in
        *base64,*) printf '%s' "${src#*base64,}" | base64 -d ;;
        *) return 1 ;;
    esac
}

# boot_sign_verify_drift <mode> <key-path-or-empty> <ignition.json>
# Post-compile drift check (destructive-operation rule: verify against the
# produced artefact, not the source). Re-reads the key actually baked into the
# compiled Ignition and confirms it matches the source key by canonical
# fingerprint. The named failure mode: a stale key from a previous build, a key
# mangled during compilation, or a sentinel that failed to substitute, any of
# which would silently ship a host trusting the wrong key (or no key). This
# check makes that loud and fails the build. For a PERMISSIVE build it asserts
# the opposite: NO key baked. Either direction failing aborts the build.
#
# Requires medium_manifest_pubkey_fingerprint (sourced from medium-manifest.sh).
boot_sign_verify_drift() {
    local mode="$1" key="$2" ign="$3"
    case "$mode" in
        signing)
            local baked_pem src_fp baked_fp
            baked_pem="$(boot_sign_extract_baked_key "$ign")" || {
                echo "[!] DRIFT CHECK FAILED: no verifier key found at ${BAKED_KEY_PATH}" >&2
                echo "    in the compiled Ignition, but a SIGNING build was requested." >&2
                echo "    The sentinel substitution or Butane embed did not happen." >&2
                return 1
            }
            src_fp="$(medium_manifest_pubkey_fingerprint "$key" pubin)"
            baked_fp="$(printf '%s' "$baked_pem" | medium_manifest_pubkey_fingerprint /dev/stdin pubin)"
            if [ -z "$baked_fp" ] || [ "$src_fp" != "$baked_fp" ]; then
                echo "[!] DRIFT CHECK FAILED: the key baked into the Ignition does not" >&2
                echo "    match the source key (${key})." >&2
                echo "    source fingerprint: ${src_fp:-<none>}" >&2
                echo "    baked  fingerprint: ${baked_fp:-<none>}" >&2
                echo "    The boot ISO would trust the wrong key. Aborting." >&2
                return 1
            fi
            echo "[+] Drift check passed: baked verifier key matches source (${src_fp})."
            ;;
        permissive)
            if boot_sign_extract_baked_key "$ign" >/dev/null 2>&1; then
                echo "[!] DRIFT CHECK FAILED: a key was baked at ${BAKED_KEY_PATH} but a" >&2
                echo "    PERMISSIVE build was requested. The sentinel was not removed." >&2
                return 1
            fi
            echo "[+] Drift check passed: no verifier key baked (permissive host)."
            ;;
        *)
            echo "[!] boot_sign_verify_drift: unknown mode '$mode'" >&2
            return 1
            ;;
    esac
}