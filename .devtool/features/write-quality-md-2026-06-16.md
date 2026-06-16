---
id: "write-quality-md-2026-06-16"
status: "todo"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.794Z"
modified: "2026-06-16T18:25:11.794Z"
completedAt: null
labels: ["quality", "docs"]
order: "a5"
---
# Write docs/QUALITY.md

A short document capturing the project's quality bar. Read by future
contributors (human and AI). The system-prompt card encodes the
operative rules; this document explains them.

## Acceptance criteria

`docs/QUALITY.md` exists and covers:

- The failure-modes-first principle. Before writing the success
  path, name at least one failure mode and how it will be tested.
- The success-indicator-must-be-substantive rule, with the recent
  sidecar bug as a worked example.
- The protocol-contract requirement, with the sidecar producer and
  consumers as a worked example.
- The destructive-operation verification requirement (re-read from
  destination, not source).
- The bash idioms catalogue: forbidden (`|| true` without
  justification, output-capturing wrappers that swallow stderr,
  silent failure with no exit propagation) and encouraged
  (`set -euo pipefail`, explicit exit codes propagated from inner
  scripts, contracts named in comments).
- A short section on how to write a regression test for a bug you
  just fixed: the bug is the test fixture; the test is the proof
  the fix works and the alarm if it regresses.

Target length: 200 to 400 lines. Long enough to be substantive,
short enough that contributors will read it.

## Sequencing

Should land before the system-prompt extension. The system prompt
should be able to reference QUALITY.md as the rationale source
("see docs/QUALITY.md for why").