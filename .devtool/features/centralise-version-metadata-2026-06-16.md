---
id: "centralise-version-metadata-2026-06-16"
status: "backlog"
priority: "low"
assignee: "k"
labels: ["refactor", "docs"]
order: 2
---

# Centralise version metadata

Project version currently lives in seven string locations across
three files (README, generator heredoc, committed SBOM.json). The
0.9.0 to 1.0.0 bump audit found a stale `0.1.0` reference that
had survived multiple version bumps.

Full details and two implementation shapes in the existing roadmap
doc: `docs/roadmap/centralise-version-metadata.md`.

## Acceptance criteria

See the roadmap doc. Target: land in the same commit as whatever
first triggers the next version bump after 0.9.1 (so likely the
1.0.0 tag itself).

## Notes

Standalone work; no dependencies on other cards. Cheap enough
to land opportunistically.