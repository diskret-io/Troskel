---
id: "bundle-vendored-regions-2026-06-21"
status: "todo"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-21T00:00:00.000Z"
modified: "2026-06-21T21:20:39.025Z"
completedAt: null
labels: ["refactor", "infra", "quality"]
order: "a1"
---
# Bundle vendored shell regions at build time

Replace hand-maintained vendored shell regions, and the drift tests that police
them, with a single authored source per shared region that the build splices
into the host scripts. One source of truth, generated copies, no drift test to
maintain.

## Motivation

The scanning host has no `scripts/lib/` at runtime, so shared shell functions
cannot be sourced there. The current solution copies the canonical code verbatim
into each host script between `BEGIN`/`END` sentinel comments, and a regression
test (`tests/test-manifest-propagation.sh` Test 0) asserts every copy is
byte-identical to the lib. This works, but it has three costs. The same code is
authored once and then maintained in N places by hand; a change requires editing
the lib and re-pasting into each consumer, in lockstep, by a human. The drift
test only catches a divergence after it has been committed, it is a tripwire, not
a prevention. And it adds reviewer burden: every change to a vendored region must
be checked against every copy.

The data-USB authenticity gate (`sign-data-usb-manifest`) introduced a second
vendored region (the medium-manifest verification functions in
`config/host-scripts/load-scanner`, canonical in `scripts/lib/medium-manifest.sh`),
which made the duplication concrete: two distinct shared regions, each needing
its own byte-identity discipline. This is the point to convert the mechanism
rather than accrue a third copy later.

## Current state

Two shared regions are hand-vendored:

- The manifest parser, canonical in `scripts/lib/manifest-parse.sh`, copied
  verbatim into `config/host-scripts/load-scanner` and
  `config/host-scripts/show-status`. Byte-identity enforced by
  `tests/test-manifest-propagation.sh` Test 0.
- The medium-manifest verification region, canonical in
  `scripts/lib/medium-manifest.sh`, copied into `config/host-scripts/load-scanner`
  (added by the authenticity gate).

Both rely on a human to keep the copies in step and on a test to catch them when
they fail to.

The build already substitutes sentinels into a temporary copy of host config at
build time: `prepare-boot-usb.sh` replaces `@@SCANNER_PASSWORD_HASH@@` with a
generated hash and `@@SIGN_PUBKEY_FILE_ENTRY@@` with a storage.files entry. The
mechanism for build-time region substitution therefore already exists and is
proven; this card generalises it from substituting a value to splicing a code
region.

## Target state

Each shared region is authored exactly once, in its lib, delimited by sentinels.
The committed host script carries a placeholder marker where the region belongs,
not a copy of the code. A build step splices the lib's region into the host
script before it is baked into the boot image, producing a self-contained host
script with no runtime `scripts/lib` dependency, exactly as today, but with the
copy generated rather than hand-maintained.

After this:

- The shared code exists in one authored place. A change is made once.
- The host scripts remain self-contained (the minimal-host constraint is
  preserved: no `scripts/lib/` on the host).
- The byte-identity drift tests are deleted, because there is no hand-maintained
  copy to drift. The property they asserted is now guaranteed by construction.

## Implementation outline

1. Define a region-splice helper (a small script or make function) that, given a
   lib file, a region name, and a target script, replaces the target's
   `@@REGION:<name>@@` marker with the lib's sentinel-delimited region.
2. Mark each shared region in its lib with named sentinels
   (`# >>> BEGIN <name> >>>` / `# <<< END <name> >>>`, already the convention).
3. Replace the vendored code in each committed host script with a single
   `@@REGION:<name>@@` marker line (a shell comment, so the committed script
   still parses and shellchecks: e.g. `# @@REGION:medium-manifest@@`).
4. Hook the splice into the boot build (`prepare-boot-usb.sh`), operating on the
   build copies of the host scripts before Butane embeds them, alongside the
   existing passphrase and key-entry substitutions. The committed host scripts
   are never the ones baked; the spliced build copies are.
5. Update `test-validate.sh` so shellcheck runs against a spliced copy (a host
   script with a bare region marker is incomplete; validate must splice before
   linting, just as it already dummy-substitutes the passphrase hash before
   `butane --check`).
6. Delete the byte-identity assertions (`test-manifest-propagation.sh` Test 0,
   and the medium-manifest drift test if one was added) and the now-unused
   re-vendoring discipline from the contract comments.
7. Migrate the two existing regions: manifest-parse first (three sites:
   load-scanner, show-status), then medium-manifest (load-scanner).

## Side effects

- The committed host scripts become non-runnable as-is (they carry region
  markers, not the spliced code). This is already true in spirit for
  `scanner-host.bu` (it carries sentinels), but host SCRIPTS are currently
  complete and directly runnable. After this they are templates. The validate
  tier must splice before shellcheck, or it will lint an incomplete script.
  This is the main behavioural change and the main risk: a developer running a
  host script directly from the repo would now get an inert marker. Mitigate by
  making the marker a loud no-op comment and documenting that host scripts are
  generated.
- shellcheck coverage shifts from the committed script to the spliced script.
  Net neutral (the spliced script is what ships), but the validate step changes.
- The drift tests are deleted, not weakened: the property is enforced by
  construction instead. Reviewers no longer audit copies.

## Estimated effort

Two to three days. The splice helper and build hook are small (the substitution
machinery exists). The bulk is migrating both regions carefully, updating the
validate tier to splice-before-lint, and confirming the spliced host scripts are
byte-identical to today's hand-vendored ones (a one-time equivalence check: splice
the new mechanism, diff against the current committed copies, expect no
functional change).

## Sequencing

After `sign-data-usb-manifest` lands. That card adds the second vendored region;
doing the migration first would force the gate to adopt a not-yet-built
mechanism, and doing the gate first gives the migration two real regions to
convert and a worked example (the gate's own region) to model on. No dependency
on the other backlog cards. Fits the same tidy-up spirit as the post-1.0.0 drift
work; a natural 1.1.x infra item.

## Open questions

- Splice at build time only, or also provide a `make` target that regenerates the
  committed host scripts in place (so they ARE runnable from the repo, at the cost
  of reintroducing a committed copy that could drift)? The pure build-time-only
  approach is cleaner but makes host scripts non-runnable from the tree; a
  regenerate-in-place target trades that back for a committed artefact. Leaning
  build-time-only with loud markers, but worth deciding.
- Should the splice helper live in `scripts/lib/` (build-station only, so no
  host concern) or be a make function? A lib script is more testable.
- Does any region need per-consumer variation (e.g. a function used by load-scanner
  but not show-status)? If so, the region granularity must be fine enough that a
  consumer splices only what it uses, rather than dragging in unused functions.
  The current regions are coarse; confirm the granularity before migrating.