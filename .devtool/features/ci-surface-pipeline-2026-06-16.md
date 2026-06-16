---
id: "ci-surface-pipeline-2026-06-16"
status: "todo"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.759Z"
modified: "2026-06-16T18:25:11.759Z"
completedAt: null
labels: ["infra", "quality"]
order: "a0"
---
# Surface CI pipeline state explicitly

Project conventions describe a three-tier CI (validate on PRs,
test and scan on push to main). Verify the pipeline is actually
running and surface its state in the README so the project's
quality posture is visible.

## Acceptance criteria

- Confirm via `.github/workflows/` (or equivalent) that the three
  tiers run on the right triggers. If they do not, set them up.
- Add a CI status badge to the README near the project-status
  block, so the visible status of the build is part of the
  landing-page information.
- Confirm `make validate`, `make test`, and `make test-scan` all
  pass under CI on a clean main branch.
- The two negative-case tests (`negative-case-test-sidecar`,
  `negative-case-test-orchestrator`) run under `make test` in CI.

## Sequencing

Lands after the two negative-case tests; CI is the venue that
makes the tests load-bearing rather than aspirational.

## Notes

If the CI configuration is already correct and tests are running,
this card is just the badge addition plus a verification commit.
If not, this card subsumes the CI setup work and may expand.