---
id: "negative-case-test-orchestrator-2026-06-16"
status: "done"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.779Z"
modified: "2026-06-17T15:44:00.542Z"
completedAt: "2026-06-17T15:44:00.542Z"
labels: ["tests", "quality", "security"]
order: "a4"
---
# Negative-case test: orchestrator propagates inner-script failures

The orchestrator silently reported success against an inner script
that failed with `|| true`-swallowed errors. A test that proves the
orchestrator surfaces failures would have caught the regression.

## Acceptance criteria

A test (in `tests/`, run as part of `make test`) that:

1. Creates a mock inner script that exits non-zero.
2. Invokes the orchestrator's stage runner against the mock.
3. Asserts the orchestrator exits non-zero.
4. Asserts the orchestrator surfaces the mock's error message to
   stdout/stderr, not buried behind `--debug`.

A second test variant: the mock inner script swallows its own
exit code with `exit 0` after a destructive failure. The
orchestrator must detect this by checking observable side effects
(e.g. did the artefact get written) and fail loudly.

The second variant is harder and may need design work; if so, the
first variant lands now and the second becomes its own card. Both
must land before 1.0.0.

## Notes

Depends on the orchestrator failure-propagation fix
(`fix-orchestrator-failure-propagation-2026-06-16`) landing first.
This card is the regression alarm; the fix card is the fix.