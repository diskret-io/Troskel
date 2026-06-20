---
id: "verdict-grammar-2026-06-17"
status: "backlog"
priority: "low"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T18:50:48.772Z"
modified: "2026-06-20T19:15:05.325Z"
completedAt: null
labels: ["refactor", "feature"]
order: "a8"
---
# Verdict grammar

The verdict pipeline currently grep-matches free-form strings
(`THREAT DETECTED`, `CLEAN`, `ERROR`) emitted by the guest
entrypoint. The host wrapper parses these by regex. Any change
to the guest's wording risks a silent verdict misread, which for
a security tool is exactly the failure class the project cannot
tolerate.

The verdict-grammar work replaces free-form strings with a
structured grammar: machine-readable verdict lines with explicit
fields, parsed by a single shared parser, with QUALITY.md's
contract-comment discipline at both producer and consumer.

Roadmap doc: `docs/roadmap/verdict-grammar.md`.

## Why it matters

Three benefits:

1. **Removes a silent-misread risk** in the verdict pipeline.
2. **Foundation for output-USB certificates**: the signed scan
   certificate naturally references grammar fields rather than
   parsed-from-free-text strings.
3. **Foundation for ingest-VM**: the ingest VM's `INGEST:` line
   in the sealed verdict log was always going to need this
   structure.

## Acceptance criteria

See the roadmap doc. Three to five days. Touches guest entrypoint,
`scan-wrap`, and the verdict-display code in `troskel-build.sh`.

## Sequencing

1.2.0 cluster. Wants to land before `ingest-vm` (which produces
`INGEST:` grammar lines) and ideally before `output-usb`
(certificate format references the grammar). Composes with
`parallel-engines`: multiple engine streams aggregate more cleanly
under a structured grammar.

Strictly speaking the dependency on `output-usb` is one-way: if
output-USB ships first using ad-hoc parsing, then verdict-grammar
lands later and output-USB gets a small refactor commit. Workable
either way.