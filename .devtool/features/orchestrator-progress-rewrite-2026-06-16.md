---
id: "orchestrator-progress-rewrite-2026-06-16"
status: "superseded"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.785Z"
modified: "2026-06-18T00:00:00.000Z"
completedAt: null
labels: ["refactor", "infra"]
order: "a1"
---
# Orchestrator progress reporting rewrite

The `troskel-build.sh` orchestrator captures inner-script output
and replaces it with a spinner. Long stages look hung, failures
lose context, stage boundaries are unclear, and keypresses are
misinterpreted as confirmation prompts.

Full details and three implementation shapes in the existing
roadmap doc: `docs/roadmap/build-orchestrator-progress.md`.

## Status: superseded

This umbrella card is superseded by
`orchestrator-progress-prompts-2026-06-18`, which carries the
remaining scope. It is closed as superseded, not done: the full
target state has not shipped. Tracking the outstanding work under
two cards would be drift, so the remaining scope lives in the
single follow-up card.

What shipped under this card:

- Failure context. `run_step` dumps captured output inline on
  failure rather than burying it behind a `--debug` rerun
  (landed with the 1.0.0 safety work,
  `fix-orchestrator-failure-propagation-2026-06-16`).
- Looks-hung, for the two captured USB-write stages. A liveness
  heartbeat was added to `_run_capture_with_heartbeat` in
  `scripts/lib/run-step.sh` and threaded through both the data
  and boot write paths (2026-06-18). Phase 3 (`make update`)
  already streamed live and was never silent.

What remains (now tracked by
`orchestrator-progress-prompts-2026-06-18`):

- Prompt framing: destructive confirmations are not visually
  distinct from progress output and accept a bare Enter as yes.
- Stage boundaries: no "Stage N of M" indicator, no per-stage
  expected-duration framing.

When the follow-up card lands in full, delete
`docs/roadmap/build-orchestrator-progress.md`.

## Acceptance criteria

See the roadmap doc. Target: 1.1.0 or whenever the project first
attracts external evaluators.

## Notes

This is the bigger sibling of
`fix-orchestrator-failure-propagation-2026-06-16`. That card is
the narrow safety-bug fix (orchestrator must not report success
against failed inner scripts) and is a 1.0.0 blocker. This card
is the broader UX rewrite (visible progress, failure context,
stage boundaries) and is post-1.0.0.

Keep separate: shipping the safety fix should not be held up by
the UX rewrite.