---
id: "boot-passphrase-contract-comment-2026-06-19"
status: "backlog"
priority: "low"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-19T00:00:00.000Z"
modified: "2026-06-20T13:31:22.535Z"
completedAt: null
labels: ["docs", "quality"]
order: "Zy"
---
# Boot passphrase banner is an undocumented cross-script contract

`scripts/troskel-build.sh` parses the output of
`scripts/prepare-boot-usb.sh` to extract the per-build scanner
passphrase: an awk state machine keys on the `SCANNER PASSPHRASE` title
line and the `====` banner rules around the passphrase block. The
orchestrator side now documents this dependency (a CONTRACT NOTE on the
KEEP_OUT consumer, plus the mandatory emptiness check that fails loudly
if the format drifts). The producer side does not. `prepare-boot-usb.sh`
prints the banner with no comment noting that another script parses it,
so a well-meaning change to the banner wording or layout would silently
break extraction, caught only at runtime by the orchestrator's emptiness
guard.

## Motivation

QUALITY.md principle 3: any protocol spanning more than one script gets
a paragraph-length contract comment at both producer and consumer
sites, each naming the other. This one currently has the consumer half
only. The asymmetry is exactly the drift risk the principle exists to
prevent: the person most likely to change the banner is editing
`prepare-boot-usb.sh`, which is the file that carries no warning.

The emptiness check means a drift fails closed rather than silently
losing the passphrase, so this is low severity, but the contract
comment is near-zero cost and closes the gap the rule names.

## Current state

`prepare-boot-usb.sh` emits the banner block (title line containing
`SCANNER PASSPHRASE`, a `====` rule, the passphrase line, explanatory
text, a closing `====` rule) with no comment about downstream parsing.
`troskel-build.sh` carries the awk and a CONTRACT NOTE describing the
expected shape and the mandatory emptiness check.

## Target state

A paragraph-length contract comment at the banner-emitting site in
`prepare-boot-usb.sh` that:

- names `scripts/troskel-build.sh` as the consumer;
- states what is promised: the title line contains the literal
  `SCANNER PASSPHRASE`, the passphrase is the first non-empty line after
  the `====` rule that closes the header, and the block is closed by a
  `====` rule;
- warns that changing the banner layout requires updating the awk in the
  orchestrator, and that the orchestrator fails closed (aborts the run)
  rather than silently emitting an empty passphrase if the format
  drifts.

## Implementation outline

- Add the comment immediately above the banner-printing code in
  `prepare-boot-usb.sh`.
- Cross-check the wording against the orchestrator's CONTRACT NOTE so
  the two halves describe the same promise in the same terms.

## Side effects

None: comment only, no behaviour change.

## Failure modes to handle (per QUALITY.md)

Not applicable (documentation change). The runtime failure mode it
documents (banner drift) is already handled by the orchestrator's
emptiness check; this card does not change that path, only records it
at the producer.

## Estimated effort

Fifteen minutes.

## Sequencing

Not a blocker. Can ride along with any future edit to
`prepare-boot-usb.sh`, or with the manifest-propagation work
(`prepare-data-usb.sh` and friends) since that pass is already in those
scripts. Surfaced during the `troskel-build.sh` orchestration cleanup
when the boot stage was refactored to use run_step's KEEP_OUT.