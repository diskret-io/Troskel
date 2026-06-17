---
id: "defer-1.0.0-tag-0.9.1-2026-06-16"
status: "done"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.762Z"
modified: "2026-06-17T17:41:11.775Z"
completedAt: "2026-06-17T17:41:11.775Z"
labels: ["docs", "infra"]
order: "Zu"
---
# Defer 1.0.0 tag; ship 0.9.1 with bugfixes

The 1.0.0 plan defined the tag as a documentation and polish
milestone. Two silent-failure bugs in the pre-tag test cycle show
that the build pipeline does not yet enforce the security posture
even within the bounds the plan claimed. 1.0.0 should mean "the
foundations are sound", not "the documentation is polished".

Tag 0.9.1 now with the bug fixes already landed and in-flight.
Tag 1.0.0 after the quality-foundations work
(`quality-foundations-2026-06-16`) is done.

## Acceptance criteria

- README project-status block updated: still `0.9.x`, demonstrator,
  with a sentence noting the deferred 1.0.0 target.
- `SBOM.json` and the generator heredoc both at `0.9.1`.
- The road-to-1.0.0 plan doc (`docs/roadmap/road-to-1.0.0.md` if
  still extant; if deleted, re-create or update the relevant
  sequencing) updated to reflect the deferral: 1.0.0 blocked on
  the quality-foundations cards.
- `git tag -a v0.9.1` and push.

## Sequencing

Lands after both bug fixes are in (sidecar fix is done;
orchestrator fix is in-progress). 0.9.1 is the right tag because
the changes between 0.9.0 and now are bugfixes, not features.

## Notes

This card replaces the original steps 7 and 8 in the road-to-1.0.0
plan. Those steps assumed 1.0.0 would tag once drift cleanup and
metadata bump were done; the bugs uncovered since make that
unrealistic. The new path is: 0.9.1 now, 1.0.0 after foundations.