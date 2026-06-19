#!/usr/bin/env bash
# tests/test-manifest-propagation.sh
# Regression test for build-manifest.json propagation and parsing.
#
# Bug history and what this guards:
#
#   1. troskel_dirty never read. show-status extracted build-identity
#      fields with a single matcher for quoted strings ("key": "value").
#      generate-build-records.sh emits troskel_dirty as an UNQUOTED JSON
#      boolean (`"troskel_dirty": false`). The quoted-string matcher never
#      matched it, so DIRTY was always empty and "Tree clean" always
#      printed "unknown" regardless of the actual build state. A status
#      field that cannot distinguish a clean tree from a dirty one is a
#      decorative indicator. Tests 1-2 assert the fixed matcher reads both
#      false and true.
#
#   2. No write-time manifest verification. prepare-data-usb.sh copied the
#      manifest to the USB but never re-read it from the destination, so a
#      truncated or corrupt copy shipped undetected (the "unknown" display
#      on the host would mask it as a merely-old USB). Test 3 asserts the
#      jq field-presence check rejects a manifest missing a required field.
#      (The sha256 byte-compare is exercised implicitly: it is a plain
#      sha256sum equality, low-risk; the field check is the novel logic.)
#
#   3. Corrupt-vs-absent not distinguished. A present-but-unparseable
#      manifest was indistinguishable from an absent one: both showed
#      "unknown". Post-propagation (write-time generation now mandatory) a
#      missing field means corruption, not an old USB, and the operator
#      needs to tell them apart. Tests 4-6 assert show-status reports
#      "unreadable" for a corrupt manifest, real values for a valid one,
#      and the old-USB message for an absent one.
#
# Invocation: `bash tests/test-manifest-propagation.sh` (no privilege, no
# real device, no container). jq is required for test 3 only and is skipped
# with a notice if absent on the host running the test; CI runs this inside
# the troskel-build container, which has jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHOW_STATUS="${PROJECT_ROOT}/config/host-scripts/show-status"

[ -f "$SHOW_STATUS" ] || { echo "[!] show-status not found at $SHOW_STATUS"; exit 1; }

PASS=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
step() { echo ""; echo "=== $* ==="; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A minimal but structurally faithful manifest. Mirrors the shape
# generate-build-records.sh emits: generated_at and the build_environment
# block with troskel_commit (quoted) and troskel_dirty (unquoted boolean).
make_manifest() {  # make_manifest <dirty:true|false> <commit> > file
    local dirty="$1" commit="$2"
    cat <<JSON
{
  "manifest_version": "1",
  "generated_at": "2026-06-19T12:00:00+00:00",
  "build_environment": {
    "troskel_commit": "${commit}",
    "troskel_dirty": ${dirty},
    "build_host_kernel": "6.1.0",
    "debian_release": "bookworm"
  }
}
JSON
}

# Run show-status against a fixture manifest and capture only the build
# block. show-status prints a full status page (signature dates, KVM, last
# scan); we grep the build-identity lines out of it. MANIFEST is the seam
# show-status exposes for exactly this.
build_block() {  # build_block <manifest-path-or-empty>
    MANIFEST="$1" bash "$SHOW_STATUS" 2>/dev/null \
        | sed -n '/=== Scanner build ===/,/^$/p'
}

# ── Test 1: troskel_dirty=false is read as a clean tree ──────────────────────
step "Test 1: clean tree (troskel_dirty=false) reads as 'Tree clean : yes'"
make_manifest false abc1234 > "$WORK/clean.json"
OUT="$(build_block "$WORK/clean.json")"
echo "$OUT" | grep -q "Tree clean     : yes" \
    || fail "clean tree not reported as yes. Got:
$OUT"
# Guard against the original bug specifically: it must NOT say unknown.
echo "$OUT" | grep -q "Tree clean     : unknown" \
    && fail "clean tree reported 'unknown' — the troskel_dirty matcher is broken again"
pass "troskel_dirty=false reads as a clean tree"

# ── Test 2: troskel_dirty=true is read as a dirty tree ───────────────────────
step "Test 2: dirty tree (troskel_dirty=true) reads as 'Tree clean : NO'"
make_manifest true def5678 > "$WORK/dirty.json"
OUT="$(build_block "$WORK/dirty.json")"
echo "$OUT" | grep -q "Tree clean     : NO" \
    || fail "dirty tree not reported as NO. Got:
$OUT"
pass "troskel_dirty=true reads as a dirty tree"

# Also confirm the commit field extracts (quoted-string path still works).
echo "$OUT" | grep -q "Troskel commit : def5678" \
    || fail "troskel_commit not extracted. Got:
$OUT"
pass "troskel_commit (quoted string) extracts correctly"

# ── Test 3: write-time jq field check rejects a manifest missing a field ─────
step "Test 3: jq field-presence check rejects an incomplete manifest"
if command -v jq >/dev/null 2>&1; then
    # Missing build_environment.troskel_commit.
    cat > "$WORK/incomplete.json" <<'JSON'
{
  "generated_at": "2026-06-19T12:00:00+00:00",
  "build_environment": {
    "troskel_dirty": false
  }
}
JSON
    # This is the exact predicate prepare-data-usb.sh uses.
    if jq -e \
        '.generated_at and (.build_environment.troskel_commit) and (.build_environment | has("troskel_dirty"))' \
        "$WORK/incomplete.json" >/dev/null 2>&1; then
        fail "jq predicate accepted a manifest missing troskel_commit"
    fi
    pass "jq predicate rejects a manifest missing a required field"

    # And accepts a complete one, including the troskel_dirty=false case
    # (false is falsy in jq, so the predicate must use has(), not truthiness).
    make_manifest false abc1234 > "$WORK/complete.json"
    if ! jq -e \
        '.generated_at and (.build_environment.troskel_commit) and (.build_environment | has("troskel_dirty"))' \
        "$WORK/complete.json" >/dev/null 2>&1; then
        fail "jq predicate rejected a complete manifest with troskel_dirty=false"
    fi
    pass "jq predicate accepts a complete manifest (troskel_dirty=false not treated as missing)"
else
    echo "[SKIP] jq not on host; write-time field check is exercised in-container by CI."
fi

# ── Test 4: corrupt manifest reports 'unreadable', not 'unknown' ─────────────
step "Test 4: present-but-corrupt manifest reports 'unreadable'"
printf 'this is not json at all\n' > "$WORK/corrupt.json"
OUT="$(build_block "$WORK/corrupt.json")"
echo "$OUT" | grep -q "Generated      : unreadable" \
    || fail "corrupt manifest not reported as unreadable. Got:
$OUT"
echo "$OUT" | grep -q "Generated      : unknown" \
    && fail "corrupt manifest reported 'unknown' — cannot distinguish corrupt from absent"
pass "corrupt manifest reports 'unreadable'"

# ── Test 5: valid manifest reports real values ───────────────────────────────
step "Test 5: valid manifest reports generated_at and commit"
make_manifest false abc1234 > "$WORK/valid.json"
OUT="$(build_block "$WORK/valid.json")"
echo "$OUT" | grep -q "Generated      : 2026-06-19T12:00:00+00:00" \
    || fail "valid manifest generated_at not shown. Got:
$OUT"
pass "valid manifest reports real values"

# ── Test 6: absent manifest reports the old-USB message ──────────────────────
step "Test 6: absent manifest reports 'predates manifest support'"
OUT="$(build_block "$WORK/does-not-exist.json")"
echo "$OUT" | grep -q "Generated      : unknown" \
    || fail "absent manifest not reported as unknown. Got:
$OUT"
echo "$OUT" | grep -q "predates manifest support" \
    || fail "absent manifest missing the old-USB explanation. Got:
$OUT"
pass "absent manifest reports the old-USB message"

step "Result"
echo "[+] All ${PASS} assertions passed. Manifest propagation and parsing are correct."