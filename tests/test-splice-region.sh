#!/usr/bin/env bash
# tests/test-splice-region.sh
# Unit test for scripts/lib/splice-region.sh, the build-time region bundler that
# splices shared shell regions from a lib into host scripts (replacing the
# hand-vendored-plus-drift-test approach). Because the splice is what puts
# verification code onto the air-gapped host, a silent splice failure would bake
# a host script with no verification or a stray marker; every failure mode here
# must abort loudly. Needs only bash and coreutils (no jq, no openssl): the
# splice is pure text, so this test runs anywhere.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scripts/lib/splice-region.sh
source "${ROOT}/scripts/lib/splice-region.sh"

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
step() { echo ""; echo "=== $* ==="; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# A source lib with a known region.
cat > "$W/lib.sh" <<'LIB'
#!/usr/bin/env bash
# preamble (not in region)
# >>> BEGIN REGION:demo >>>
demo_var="hello"
demo_fn() { echo "$demo_var"; }
# <<< END REGION:demo <<<
# trailer (not in region)
producer_fn() { echo "build-station only"; }
LIB

# A target with the marker.
cat > "$W/target.sh" <<'TGT'
#!/bin/bash
echo "head"
# @@REGION:demo@@
echo "tail"
TGT

# ── Test 1: happy-path splice ────────────────────────────────────────────────
# Failure mode guarded: the region must replace the marker exactly, preserving
# surrounding lines and excluding the sentinels and out-of-region code.
step "Test 1: splice replaces marker with region body"
splice_region "$W/lib.sh" demo "$W/target.sh" > "$W/out.sh" || fail "splice returned non-zero on valid input"
grep -q '@@REGION:demo@@' "$W/out.sh" && fail "marker not consumed"
grep -q 'demo_fn()' "$W/out.sh" || fail "region body missing"
grep -q 'demo_var="hello"' "$W/out.sh" || fail "region var missing"
grep -q 'echo "head"' "$W/out.sh" && grep -q 'echo "tail"' "$W/out.sh" || fail "surrounding lines not preserved"
grep -q 'producer_fn' "$W/out.sh" && fail "out-of-region code leaked into splice"
grep -q 'BEGIN REGION' "$W/out.sh" && fail "sentinel line leaked into splice"
bash -n "$W/out.sh" || fail "spliced output is not valid bash"
pass "splice replaces marker with exactly the region body, sentinels and out-of-region code excluded"

# ── Test 2: missing marker aborts ────────────────────────────────────────────
# Failure mode guarded: a target that does not expect this region must not be
# silently emitted unchanged (which would bake a script missing the code).
step "Test 2: missing marker aborts"
printf '#!/bin/bash\necho hi\n' > "$W/nomark.sh"
splice_region "$W/lib.sh" demo "$W/nomark.sh" >/dev/null 2>&1 && fail "splice passed with no marker" || true
pass "missing marker aborts (non-zero)"

# ── Test 3: missing region aborts ────────────────────────────────────────────
# Failure mode guarded: a typo'd or removed region name must abort, not emit a
# target with an unreplaced marker.
step "Test 3: missing region in lib aborts"
splice_region "$W/lib.sh" no-such-region "$W/target.sh" >/dev/null 2>&1 && fail "splice passed with no region" || true
pass "missing region aborts (non-zero)"

# ── Test 4: duplicate marker aborts ──────────────────────────────────────────
# Failure mode guarded: two markers are ambiguous; splicing both could duplicate
# the region or leave one. Refuse.
step "Test 4: duplicate marker aborts"
printf '#!/bin/bash\n# @@REGION:demo@@\n# @@REGION:demo@@\n' > "$W/dup.sh"
splice_region "$W/lib.sh" demo "$W/dup.sh" >/dev/null 2>&1 && fail "splice passed with duplicate marker" || true
pass "duplicate marker aborts (non-zero)"

# ── Test 5: empty region aborts ──────────────────────────────────────────────
# Failure mode guarded: a region with sentinels but no body must not splice
# nothing into the target silently.
step "Test 5: empty region aborts"
cat > "$W/emptylib.sh" <<'EL'
# >>> BEGIN REGION:empty >>>
# <<< END REGION:empty <<<
EL
printf '#!/bin/bash\n# @@REGION:empty@@\n' > "$W/etgt.sh"
splice_region "$W/emptylib.sh" empty "$W/etgt.sh" >/dev/null 2>&1 && fail "splice passed with empty region" || true
pass "empty region aborts (non-zero)"

# ── Test 6: real medium-manifest region splices into a valid script ──────────
# Failure mode guarded: the ACTUAL region this project bundles must splice into a
# syntactically valid script. Guards against a future edit to the lib region that
# breaks the bundled host script (the bug class that motivated build-time
# bundling over hand-vendoring).
step "Test 6: real medium-manifest-verify region splices into valid bash"
REAL_LIB="${ROOT}/scripts/lib/medium-manifest.sh"
if [ -f "$REAL_LIB" ]; then
    printf '#!/bin/bash\nset -euo pipefail\ncleanup_mount(){ return 0; }\n# @@REGION:medium-manifest-verify@@\necho ok\n' > "$W/ls.sh"
    splice_region "$REAL_LIB" medium-manifest-verify "$W/ls.sh" > "$W/ls.baked" || fail "real region splice failed"
    grep -q 'medium_manifest_verify_sig()' "$W/ls.baked" || fail "real region body missing after splice"
    bash -n "$W/ls.baked" || fail "spliced real load-scanner stub is not valid bash"
    pass "real medium-manifest-verify region splices into valid bash"
else
    echo "[SKIP] $REAL_LIB not present"
fi

step "Result"
echo "[+] All ${PASS} assertions passed. Region splicer is correct."
echo ""
echo "[+] Tier 1 splice-region verification passed."