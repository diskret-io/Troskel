---
id: "test-scan-back-to-back-flake-2026-06-17"
status: "backlog"
priority: "low"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T18:50:48.770Z"
modified: "2026-06-17T18:50:48.770Z"
completedAt: null
labels: ["bug", "tests"]
order: "a7"
---
# Back-to-back scan flake

When `tests/test-scan.sh` runs two scans consecutively without delay,
the second Firecracker launch sometimes fails with
`MicroVMStoppedWithError(GenericError)` before the guest kernel prints.
The current workaround in tree is a `sync && sleep 2` between scans.

Investigation attempted ahead of 1.0.0; the flake did not reproduce on
the development host, leaving no confirmed cause to fix. Deferred to
1.0.1. The `sync && sleep 2` mitigation stays in place for now.

Roadmap doc: `docs/roadmap/test-scan-back-to-back-flake.md`.

## What would unblock this

Any of:

- The flake reproduces consistently on a development host or CI runner,
  giving a concrete failure to investigate.
- A planned change (verdict-grammar work, parallel-engines refactor)
  makes the suspected cause (tee-subshell lifetime in `scan-wrap`)
  moot by other means.
- The `sync && sleep 2` mitigation becomes a problem (test-suite
  runtime, timing-sensitive future test).

Until then, leave it. The roadmap doc records what is known.

## Sequencing

1.0.1 or whichever release first sees the flake reproduce. Not a
1.0.0 blocker (the mitigation works; the underlying cause is
unconfirmed).