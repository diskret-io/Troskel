---
id: "automate-manual-tests-2026-06-17"
status: "backlog"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T18:50:48.761Z"
modified: "2026-06-19T22:25:23.527Z"
completedAt: null
labels: ["tests", "infra"]
order: "a0"
---
# Automate manual tests

`tests/manual-tests-scan.md` lists procedures that cannot run in CI
today: real-USB workflows, BadUSB simulation, freshness-gate
behaviour, HID injection scenarios. Each procedure is documented;
none is exercised by `make test`. A regression in any of them only
surfaces when an admin or operator runs the manual procedure by hand,
which they may not do.

The roadmap doc identifies which procedures are automatable in CI
(loop-device USB simulation, mocked freshness dates) versus which
need a hardware test rig (real HID injection, real BadUSB devices).

Roadmap doc: `docs/roadmap/automate-manual-tests.md`.

## Why it matters

The freshness-gate procedure is the one with the worst failure
shape: a silent regression here produces green verdicts against
stale signatures. The roadmap doc explicitly flags it as worth
pulling forward if the rest of this card slips. That carve-out
remains a fallback if 1.1.0 itself slips.

## Acceptance criteria

See the roadmap doc. Two days of work for the automatable
procedures; the rest stays manual with the existing documentation.

## Sequencing

1.1.0 cluster. No hard dependencies on other cards. The
freshness-gate piece can be carved out and landed earlier if
needed.