---
id: "extend-system-prompt-quality-bar-2026-06-16"
status: "done"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.766Z"
modified: "2026-06-17T12:41:36.131Z"
completedAt: "2026-06-17T12:41:36.131Z"
labels: ["quality", "docs"]
order: "a2"
---
# Extend system prompt with quality-bar rules

The current Troskel project instructions cover communication style,
formatting, and project conventions. They do not encode a quality
bar. Add a section that makes the rules from QUALITY.md operative
for AI-assisted work: any code Claude produces against this project
should follow them by default, not just when reminded.

## Acceptance criteria

The system prompt gains a "Quality bar" section covering:

- Success indicators must describe checks that could plausibly fail.
  Decorative checks are forbidden.
- `|| true` and similar error-swallowing patterns require a comment
  at the site of use naming why the failure is acceptable and what
  downstream code guards against the failure case.
- Cross-script protocols (file formats, env var contracts, exit code
  semantics) require a short contract comment at producer and
  consumer sites pointing at each other.
- Destructive operations (USB writes, partition table modification,
  any irrevocable action) require a verification step that re-reads
  from the destination, not from the source.
- Before writing the success path, name at least one failure mode
  the code must handle and how it will be tested.

The new section lives alongside the existing communication-style and
project-convention sections, not replacing them.

## Notes

This is the cheapest single change with the largest immediate
effect: it changes what gets written from now on, ahead of any code
rewrites. The QUALITY.md card produces the longer-form rationale;
this card produces the operative rules.