---
id: "quality-foundations-2026-06-16"
status: "done"
priority: "critical"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T18:50:48.792Z"
modified: "2026-06-17T18:50:48.792Z"
completedAt: null
labels: ["quality", "infra", "docs"]
order: "a6"
---
# Quality foundations before 1.0.0

Umbrella card. Two silent-failure bugs in the pre-1.0.0 test
cycle (sidecar absolute path; orchestrator hides write failures)
revealed that the project did not have the quality scaffold
appropriate to a trusted security product. 1.0.0 was originally
scoped as "documentation and polish"; that framing was insufficient.
This card collected the work that made 1.0.0 mean "the foundations
are sound" rather than "the documentation is polished".

## What landed

All six sub-cards delivered:

- `extend-system-prompt-quality-bar` — operative rules in the
  contributor instructions.
- `write-quality-md` — `QUALITY.md` at the repo root, the
  rationale source.
- `fix-orchestrator-failure-propagation` — orchestrator's
  `run_step` gained POSTCOND; inner-script `|| true` patterns
  removed.
- `negative-case-test-sidecar` — `tests/test-usb-verify.sh`
  exercises the sidecar protocol; catches the absolute-path
  bug class at introduction.
- `negative-case-test-orchestrator` — `tests/test-run-step.sh`
  exercises the orchestrator's failure-mode discipline; catches
  silent-success failures.
- `ci-surface-pipeline` — verified the three-tier CI runs on
  the right triggers; both negative-case tests run under CI.

## Why it mattered

Both bugs shared the same shape: a success indicator that did
not, in principle, distinguish success from the failure mode it
claimed to detect. The check was decorative rather than
substantive. The clean-code principle now codified in
QUALITY.md:

> A success indicator must be the result of a check that could
> plausibly have failed.

The foundations make this class of bug structurally harder to
introduce, not just easier to detect.

## Closed

Closed alongside the 0.9.1 tag.