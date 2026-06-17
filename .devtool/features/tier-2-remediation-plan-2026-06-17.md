---
id: "tier-2-remediation-plan-2026-06-17"
status: "backlog"
priority: "low"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T18:50:48.771Z"
modified: "2026-06-17T18:50:48.771Z"
completedAt: null
labels: ["security", "epic"]
order: "a8"
---
# Tier 2 remediation: epic

The roadmap doc captures what is required for Troskel to claim a
Tier 2 (ISO/IEC 27001 / mid-market enterprise) security posture.
At 0.9.0 / 1.0.0 the project is explicitly sub-Tier-2: it is a
demonstrator / evaluation-grade tool, not a production deployment
for regulated environments. This epic is the path from there to
Tier 2.

Roadmap doc: `docs/roadmap/security/tier-2-remediation-plan.md`.

## What this is

An epic. Multi-week programme of work that pulls together:

- Architectural changes (ingest VM, parallel engines, signed
  certificates, verdict grammar) — covered by individual 1.1.0
  and 1.2.0 cards.
- Supply-chain attestation work (in-toto, reproducible builds,
  signed releases) — not yet captured as cards.
- Process and documentation work (threat-model refresh, formal
  audit trail of decisions, incident-response procedures) —
  not yet captured as cards.

This card exists to record that the Tier 2 horizon is real and
that the project has a plan; it is not itself actionable. When
1.2.0 lands and the architectural prerequisites are in place,
this card splits into a per-deliverable set of cards covering
the supply-chain and process work.

## Sequencing

Post-1.2.0. The architectural prerequisites (ingest-VM,
parallel-engines, verdict-grammar, output-usb) all land first.

## Status

Not actionable as a single card. Status remains `backlog`
indefinitely; the card is here for navigation, not work
allocation.