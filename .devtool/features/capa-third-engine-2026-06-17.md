---
id: "capa-third-engine-2026-06-17"
status: "backlog"
priority: "low"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T18:50:48.763Z"
modified: "2026-06-20T19:18:33.751Z"
completedAt: null
labels: ["feature"]
order: "a9"
---
# Capa as a third detection engine

The two current engines (ClamAV, LOKI-RS) are signature-based.
Capa is a behavioural-analysis engine from FLARE that identifies
malware capabilities by static analysis of compiled binaries.
Adding capa as a third engine widens detection coverage to
behaviours, not just signatures.

Roadmap doc: `docs/roadmap/capa-third-engine.md`.

## Why it matters

Capa catches malware that signature engines miss: novel families,
recompiled variants, packed samples whose unpacker is unrecognised.
At the cost of a longer scan and a richer verdict format.

## Acceptance criteria

See the roadmap doc. Two to three days plus open research
questions: rule-base management (capa rules update independently
of YARA), output integration into the verdict pipeline, runtime
budget (capa is slower than the signature engines).

## Sequencing

1.2.0 cluster. Wants `parallel-engines` to land first so capa is
a third independent VM rather than a third sequential step. Wants
`verdict-grammar` to land first so capa's behavioural categories
parse into the structured verdict cleanly.

Both are 1.2.0 cluster too, so capa is the natural last card in
that cluster. Realistically a 1.3.0 candidate.

## Open research

The roadmap doc lists open questions around licensing (capa is
Apache-2.0; the rule set has its own terms), runtime budget on
the scanning host, and the rule-base update workflow. None blocks
the technical work but each shapes it.