---
id: "orchestrator-progress-rewrite-2026-06-16"
status: "todo"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.785Z"
modified: "2026-06-17T16:01:56.368Z"
completedAt: null
labels: ["refactor", "infra"]
order: "a2"
---
# Orchestrator progress reporting rewrite

The `troskel-build.sh` orchestrator captures inner-script output
and replaces it with a spinner. Long stages look hung, failures
lose context, stage boundaries are unclear, and keypresses are
misinterpreted as confirmation prompts.

Full details and three implementation shapes in the existing
roadmap doc: `docs/roadmap/build-orchestrator-progress.md`.

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