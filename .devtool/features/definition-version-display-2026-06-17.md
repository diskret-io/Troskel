---
id: "definition-version-display-2026-06-17"
status: "todo"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T18:50:48.765Z"
modified: "2026-06-20T19:19:38.914Z"
completedAt: null
labels: ["feature", "ops"]
order: "a1"
---
# Definition-version pre-login display

The scanning host's pre-login MOTD does not currently show the
signature versions of the loaded scanner. An operator logging in
cannot tell whether they are working with current detection rules
without running `show-status` first. For ad-hoc verification of
data-USB freshness, this is more friction than the value warrants.

Roadmap doc: `docs/roadmap/definition-version-display.md`.

## What this card delivers

A pre-login banner (via CoreOS Ignition or the host-scripts) that
shows the signature and YARA rules dates from the loaded data USB.
Read-only display; the actual freshness check stays in
`check-system-ready`.

## Acceptance criteria

See the roadmap doc. Half a day of work; isolated to host-scripts
and the Butane config.

## Sequencing

1.1.0 cluster. No dependencies on other backlog cards. Cheapest
operator-facing win in the 1.1.0 cluster; reasonable first card to
pick up when 1.0.0 ships.