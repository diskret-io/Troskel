---
id: "parallel-engines-2026-06-17"
status: "backlog"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T18:50:48.770Z"
modified: "2026-06-17T18:50:48.770Z"
completedAt: null
labels: ["refactor", "security"]
order: "a6"
---
# Parallel engines with per-engine isolation

The two detection engines (ClamAV and LOKI-RS) currently run
sequentially inside a single Firecracker microVM. A bug or
exploit in one engine has full visibility into the other engine's
state during the same scan. The Tier 2 remediation plan calls
for per-engine isolation: each engine runs in its own microVM,
each VM receives the file image, results aggregate at the host.

Roadmap doc: `docs/roadmap/parallel-engines.md`.

## Why it matters

Three benefits:

1. **Defence in depth.** A compromise of one engine cannot
   interfere with the other's scan or read the other's findings.
2. **Performance.** Two engines in parallel halve the scan
   wall-clock time on multi-core hosts.
3. **Foundation for capa.** Capa as a third engine
   (`capa-third-engine`) composes more cleanly atop a per-engine
   isolation model than atop the current sequential model.

## Acceptance criteria

See the roadmap doc. Significant refactor of `scan-wrap` and the
guest entrypoint. Verdict aggregation needs to handle one VM
succeeding while the other fails (or returns nothing).

## Sequencing

1.1.0 cluster. Best landed before `capa-third-engine` (1.2.0).
Composes with `verdict-grammar` (1.2.0): the structured grammar
becomes more useful when there are multiple verdict streams to
aggregate.