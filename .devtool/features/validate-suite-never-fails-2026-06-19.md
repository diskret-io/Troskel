---
id: "validate-suite-never-fails-2026-06-19"
status: "in-progress"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-19T00:00:00.000Z"
modified: "2026-06-19T00:00:00.000Z"
completedAt: null
labels: ["bug", "quality", "tests", "infra"]
order: "a0"
---
# Tier 1 validate suite tallies failures but never fails

`tests/test-validate.sh` increments a `FAIL` counter via its `result`
helper but never reads that counter at the end of the run, and the
script has no final exit keyed on it. Every check in the file (Butane
compile, shellcheck, guest bashisms, run_step unit tests, SBOM version
agreement) records `[FAIL]` lines on failure and then the script exits
zero regardless. `make validate` therefore passes even when a check
inside it has failed.

This is the project's own silent-success failure class, applied to the
harness meant to detect it. A Tier 1 check that cannot fail the run is
decorative in the QUALITY.md sense: the green result it contributes to
cannot be distinguished from the red one it claims to detect. Because
Tier 1 runs on every PR (CI surface, `ci-surface-pipeline`), the
practical effect is that any Tier 1 regression lands green.

## Motivation

The CI gate that is supposed to make the negative-case tests and the
static checks load-bearing does not currently gate anything. A
shellcheck warning, a Butane compile error, a failing run_step
assertion, or a stale SBOM version would all report `[FAIL]` in the
log and still exit zero, so CI would mark the PR green and the operator
or reviewer would have to read the log line by line to notice. This
defeats the purpose of `ci-surface-pipeline` (which made Tier 1
load-bearing on paper) and silently weakens the 1.0.0 quality posture.

Discovered while adding the deprecated-make-alias check during the
`troskel-build.sh` orchestration cleanup. That check was made to exit
non-zero on its own as a stopgap so it would be load-bearing despite
the surrounding harness; this card fixes the harness so the stopgap can
be removed and every check benefits.

## Current state

`result()` does:

    result() {
        local STATUS="$1" DESC="$2"
        if [ "$STATUS" = "ok" ]; then
            printf "  [PASS] %s\n" "$DESC"; PASS=$((PASS + 1))
        else
            printf "  [FAIL] %s\n" "$DESC"
            printf "         %s\n" "$STATUS"; FAIL=$((FAIL + 1))
        fi
    }

`PASS` and `FAIL` are incremented but never consulted again. The script
ends after the last check's `fi` with no summary line and no
`exit`. Under `set -euo pipefail` the exit status is that of the last
command run, which on a passing-or-failing-equally basis is zero.

The deprecated-make-alias check (section 6, added this session) is the
sole check that currently exits non-zero on its own failure, via an
explicit `exit 1`. It does so precisely because the tally is not read;
its inline NOTE points here.

## Target state

`make validate` exits non-zero if and only if at least one check
failed, and prints a one-line summary of the pass/fail tally before
exiting. No individual check needs its own `exit` to be load-bearing;
the harness enforces it centrally. The alias check's stopgap `exit 1`
is removed once the harness handles it.

## Implementation outline

- Add a final summary block: print `PASS`/`FAIL` counts, then
  `[ "$FAIL" -eq 0 ]` as the script's last command (or an explicit
  `exit` keyed on `$FAIL`). Under `set -e` the trailing test sets the
  exit status cleanly.
- Audit the existing checks for the assumption that a `[FAIL]` line was
  cosmetic. Some checks may have been failing unnoticed since the
  harness never enforced them; a green local `make validate` today does
  not prove they pass. Run the suite once with the fix in place and
  resolve anything that newly goes red on its own merits (each such
  failure is a real defect the harness was hiding, not a false alarm
  introduced by this card).
- Remove the stopgap `exit 1` from the deprecated-make-alias section
  (section 6) and let it report through `result` like the others.

## Side effects

- This will, by design, start failing CI runs that were previously
  passing if any Tier 1 check is currently red. That is the point, but
  it means this card can surface latent failures that then need their
  own fixes before main is green again. Sequence accordingly: land this
  on a branch, see what goes red, fix or card each, then merge.

## Failure modes to handle (per QUALITY.md)

- The summary itself must be substantive: a test that forces one check
  to fail must make `make validate` exit non-zero. Add a self-check or
  a documented manual verification (temporarily break the Butane input,
  confirm non-zero exit) so the gate cannot silently regress to
  always-zero again. The cheapest durable form is a tiny meta-assertion:
  run the suite in a mode that injects one forced failure and assert the
  overall exit is non-zero. If that is awkward to wire without
  recursion, a comment recording the manual verification step is the
  minimum.
- A check that exits the script early (like the current alias stopgap)
  would short-circuit later checks and the summary. After centralising,
  no check should `exit` on failure; they report and let the harness
  decide. Grep for `exit 1` inside the check body region as part of the
  fix.

## Estimated effort

Half a day, most of it the audit of what newly goes red once the gate
actually bites.

## Sequencing

Before 1.0.0. This is a quality-foundations gap of the same kind the
foundations work was meant to close (`quality-foundations`,
`ci-surface-pipeline`): the CI venue exists but the Tier 1 harness it
runs is not enforcing. Pairs naturally with a re-confirmation that the
two negative-case tests actually fail the suite when their fixes are
reverted, which this harness fix is a precondition for.

## Open questions

1. (Resolved) Does `make test` (which chains validate, test-build,
   test-scan) propagate a non-zero from `validate`, and do the other two
   harnesses share the tally-not-read shape? Checked. They do not. Both
   `test-build.sh` and `test-scan.sh` are fail-fast: `set -euo pipefail`
   plus an explicit `exit 1` at every check site, so any failed check
   exits non-zero immediately and the "pipeline OK" line is reached only
   when all checks passed. `test-build.sh` accumulates `PREFLIGHT_FAIL`
   but, unlike the old `test-validate.sh`, explicitly acts on it with an
   `exit 1`. The defect was unique to `test-validate.sh`, whose
   `result()` design deliberately continues past failures to report them
   all in one run and therefore needed (and lacked) a final exit keyed on
   the tally. Scope stays narrow: this card fixes `test-validate.sh`
   only; no sibling card needed.