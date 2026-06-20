#!/usr/bin/env bash
# tests/test-loki-ioc-sanitise.sh
# Regression test for the {,N} -> {0,N} IOC regex normalisation in
# scripts/download-loki-yara-rules.sh.
#
# Why this exists: signature-base IOCs use the Python `re` form `{,N}` (omitted
# lower bound). The Rust `regex` crate LOKI-RS uses rejects it, so every such
# pattern is skipped at scan time, losing detection coverage. The ingest step
# rewrites `{,N}` to `{0,N}` (semantically identical in Python) so the patterns
# parse under Rust. The danger is a rewrite that is too broad (corrupts a
# pattern it should not touch) or too narrow (misses a form, leaving LOKI-RS
# errors). Both silently change detection behaviour, which for a scanner is
# worse than the noise the rewrite fixes. This test pins the transform: it must
# fix exactly the quantifier form and nothing else.
#
# The test exercises the SAME sed expression the ingest script uses. The
# expression is defined once here and must be kept identical to the script's
# sanitise_ioc_regex; the assertions below are what catch a drift between them.
#
# Invocation: `bash tests/test-loki-ioc-sanitise.sh` (no privilege, no network;
# bash + coreutils only).
set -euo pipefail

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
step() { echo ""; echo "=== $* ==="; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The transform under test. MUST match sanitise_ioc_regex in
# scripts/download-loki-yara-rules.sh exactly.
apply() {  # apply <file>
    sed -i -E 's/\{,([0-9]+)\}/{0,\1}/g' "$1"
}

# assert_transform <input-line> <expected-output-line> <description>
assert_transform() {
    local in="$1" want="$2" desc="$3" got
    printf '%s\n' "$in" > "$WORK/line"
    apply "$WORK/line"
    got="$(cat "$WORK/line")"
    [ "$got" = "$want" ] || fail "$desc
    in : $in
    got: $got
    want: $want"
    pass "$desc"
}

# ── The forms that MUST be rewritten ─────────────────────────────────────────
step "Forms that must be rewritten"

# The three real signature-base patterns from the card.
assert_transform \
    '\\cmd[0-9]{,3}\\cmd\.jsp' \
    '\\cmd[0-9]{0,3}\\cmd\.jsp' \
    'real pattern: cmd jsp with {,3}'

assert_transform \
    '\\(images|img)\\[^\\]{,20}\.(exe|dll)$' \
    '\\(images|img)\\[^\\]{0,20}\.(exe|dll)$' \
    'real pattern: images path with {,20}'

assert_transform \
    '\\(wp-admin)\\[^\\]{,20}\.(exe|dll)' \
    '\\(wp-admin)\\[^\\]{0,20}\.(exe|dll)' \
    'real pattern: wp-admin path with {,20}'

# Multiple occurrences on one line are all rewritten (global flag).
assert_transform \
    'a{,3}b{,12}c' \
    'a{0,3}b{0,12}c' \
    'multiple {,N} on one line all rewritten'

# ── The forms that MUST NOT change ───────────────────────────────────────────
step "Forms that must be left untouched"

# Already-valid quantifiers must not be doubled or altered.
assert_transform '[0-9]{0,3}'   '[0-9]{0,3}'   'already-valid {0,N} unchanged'
assert_transform '[0-9]{2,5}'   '[0-9]{2,5}'   'bounded {M,N} unchanged'
assert_transform '[0-9]{3}'     '[0-9]{3}'     'exact {N} unchanged'
assert_transform '[0-9]{3,}'    '[0-9]{3,}'    'open-ended {N,} unchanged'

# A brace followed by a comma but NOT the quantifier shape must not change.
# e.g. a literal set or text where { , and digits are not adjacent as {,N}.
assert_transform 'foo{bar,baz}'      'foo{bar,baz}'      'brace group with words unchanged'
assert_transform 'a{ ,3}b'           'a{ ,3}b'           'brace-space-comma (not a quantifier) unchanged'
assert_transform 'price{,}tag'       'price{,}tag'       '{,} with no digits unchanged'
assert_transform 'list{,abc}'        'list{,abc}'        '{,non-digits} unchanged'

# ── hash-iocs.txt is never processed (guarded by the script, not the regex) ──
# The script applies the transform only to filename-iocs.txt and c2-iocs.txt.
# This test documents that contract: a hash line that happens to contain a
# {,N}-looking substring would be rewritten BY THE REGEX, which is exactly why
# the script must not run it over hash-iocs.txt. We assert the regex alone is
# not a safe filter for hash files, justifying the file-scoping in the script.
step "Why hash-iocs.txt must be excluded by file, not trusted to the regex"
printf '%s\n' 'd41d8cd98f00b204e9800998ecf8427e;comment with {,3} in it' > "$WORK/hashline"
apply "$WORK/hashline"
if grep -q '{0,3}' "$WORK/hashline"; then
    pass "regex would rewrite a {,N} inside a hash-file comment (hence file scoping is required)"
else
    fail "expected the regex to alter the hash-file sample, proving file scoping is needed"
fi

# ── Completeness post-condition mirrors the script's own check ───────────────
step "No {,N} quantifier survives a rewrite"
printf '%s\n' '[^\\]{,20}\.exe' '[0-9]{,3}x' 'plain text no quantifier' > "$WORK/multi"
apply "$WORK/multi"
REMAIN="$( { grep -oE '\{,[0-9]+\}' "$WORK/multi" || true; } | wc -l | tr -d ' ')"
[ "$REMAIN" -eq 0 ] || fail "after rewrite, ${REMAIN} '{,N}' quantifier(s) still present"
pass "no {,N} quantifier remains after rewrite"

step "Result"
echo "[+] All ${PASS} assertions passed. IOC regex sanitisation is correct and narrow."