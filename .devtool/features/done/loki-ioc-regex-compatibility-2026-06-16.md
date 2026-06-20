---
id: "loki-ioc-regex-compatibility-2026-06-16"
status: "done"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.776Z"
modified: "2026-06-20T19:06:10.693Z"
completedAt: "2026-06-20T19:06:10.693Z"
labels: ["bug", "infra"]
order: "Zt"
---
# LOKI-RS regex parse errors against signature-base IOCs

`make test` surfaces LOKI-RS `[ERROR]` lines about invalid regex
patterns in the filename IOC list from upstream `signature-base`:

```
\\cmd[0-9]{,3}\\cmd\.jsp
\\(images|img|...)\\[^\\]{,20}\.(exe|dll)$
\\(wp-admin|...)\\[^\\]{,20}\.(exe|dll)
```

Python's `re` accepts `{,N}` as a synonym for `{0,N}`. Rust's
`regex` crate (used by LOKI-RS) rejects it; the lower bound is
mandatory. Upstream IOCs were written for Python LOKI and have
crossed into the Rust port that does not accept the same dialect.

LOKI-RS appears to log and continue rather than abort, so this is
noise rather than a hard failure. But the noise erodes confidence
in test output and may mask other LOKI errors.

## Acceptance criteria (one of)

- File upstream issue against `Neo23x0/Loki-RS` requesting
  `{,N}` → `{0,N}` normalisation; track resolution.
- Or: add a sanitisation step in
  `scripts/download-loki-yara-rules.sh` that rewrites `{,N}` to
  `{0,N}` in downloaded IOC files before they reach LOKI.
- Or: pin `LOKI_IOC_BASE_VERSION` to a known-good earlier release
  that does not contain the problematic patterns.

Option C is cheapest; option B is most durable; option A is
correct architecturally but slowest.

## Sequencing

Not a 1.0.0 blocker; LOKI continues to function. Revisit at 1.1.0
or whenever the noise becomes intolerable.

## Notes

If `make test` is reported as failing because of these errors
(rather than logging and passing), upgrade priority and treat as
1.0.0 blocker. Current evidence: LOKI logs and exits zero.