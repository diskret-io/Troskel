---
id: "orchestrator-progress-prompts-2026-06-18"
status: "in-progress"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-18T00:00:00.000Z"
modified: "2026-06-18T17:11:13.894Z"
completedAt: null
labels: ["refactor", "infra"]
order: "a0"
---
# Orchestrator prompt framing and stage progress

Follow-up to `orchestrator-progress-rewrite-2026-06-16`. The
heartbeat slice (liveness lines on the two captured USB-write
stages) has landed; this card covers the remaining scope from
`docs/roadmap/build-orchestrator-progress.md`. The roadmap doc
is the full reference; this card scopes what is left and splits
it by risk so the safety-relevant half need not wait on the
polish.

## Motivation

Two distinct problems remain after the heartbeat work, with
different risk profiles.

The safety-relevant one: operator confirmation prompts in
`troskel-build.sh` (Phase 1 device assignment, the `[Y/n]` and
"enter number" reads) are not visually distinct from progress
output. They default to yes on a bare Enter. The recorded
near-miss that motivated the parent card was an operator pressing
Enter into a stage that looked hung; the heartbeat removes the
"looks hung" trigger, but a stray keystroke arriving while a
prompt happens to be on screen can still be consumed as
confirmation of a destructive USB write. The prompt itself should
be unmistakable and should not treat a bare Enter as assent for
the destructive steps.

The polish one: stages give no sense of position or expected
duration. There is no "Stage N of M" framing and no indication
that, say, the boot-USB write typically takes 10 to 15 minutes.
The heartbeat now shows elapsed seconds, which tells the operator
work is happening but not whether that is normal or alarming.

## Current state

Confirmation prompts use `read -r -p` with a `[Y/n]` default of
yes (Phase 1, both the single-device and multi-device paths). The
prompt text is plain, the same weight as surrounding progress
lines. There is no explicit "this is destructive" framing and no
distinction between a confirmation and an informational pause.

Stage headers use `header()` (a cyan rule) and individual steps
use `progress()`. There is no counter, no M-total, and no
per-stage duration hint. `_run_capture_with_heartbeat` emits
elapsed seconds but no expected range.

## Target state

Prompt framing (safety half):

- Destructive-write confirmations are visually distinct from
  progress output (a framed block or distinct colour) so a prompt
  cannot be mistaken for a status line.
- The confirmation for an irreversible step (USB device
  assignment, the final proceed gate) does not accept a bare
  Enter as yes. The operator types something deliberate
  (`yes`, or the device, depending on the prompt). Non-
  destructive informational prompts may keep a default.
- A keystroke buffered before the prompt appears does not satisfy
  the prompt. Flush pending input immediately before reading a
  destructive confirmation so a stray Enter pressed during a
  long preceding stage is discarded rather than consumed.

Stage progress (polish half):

- Each `header` carries a "Stage N of M" indicator, M derived
  from the selected `USB_MODE` (the phase set is known up front).
- Long stages announce an expected duration range before
  starting (for example, "typically 10 to 15 minutes" for the
  boot-USB write), so the heartbeat's elapsed count has a
  reference the operator can judge against.

## Implementation outline

Prompt framing:

- A `confirm_destructive()` helper in `scripts/lib/run-step.sh`
  alongside the existing UI helpers. It frames the prompt
  distinctly, flushes pending stdin (read with a zero timeout in
  a loop until empty), reads a deliberate response, and returns
  non-zero on anything that is not explicit assent. The Phase 1
  reads in `troskel-build.sh` call it for the destructive gates.
- Keep the existing non-destructive `[Y/n]` reads as they are;
  only the irreversible gates change. Name which prompts are
  destructive in a comment so the distinction is not lost.

Stage progress:

- Compute M from `USB_MODE` once after argument parsing and
  thread a stage counter through the `header` calls, or add a
  `stage_header "N" "M" "label"` variant rather than overloading
  `header`.
- A small table mapping the long stages to duration-range
  strings, printed by the stage's `progress` line. Ranges, not
  point estimates: USB-write and download durations vary with
  hardware and bandwidth, and a single number invites the wrong
  expectation.

## Side effects

- A flush-stdin-before-destructive-read changes input behaviour:
  an operator who has learned to "type ahead" through the prompts
  will find buffered input discarded at the destructive gates.
  This is the point, but it is a behaviour change worth a line in
  ADMIN.md.
- `stage_header` or a threaded counter touches every `header`
  call site in `troskel-build.sh`. Mechanical, but it is a wide
  diff; keep it in its own commit separate from the prompt work.
- Duration ranges are a maintenance surface: if a stage's typical
  time shifts materially (a larger image, a slower mirror) the
  range goes stale. Low cost, worth noting.

## Failure modes to handle (per QUALITY.md)

- A stdin flush that blocks. Reading with a zero (or very short)
  timeout in a loop must terminate when the buffer is empty
  rather than waiting for input. Test: feed buffered input ahead
  of the prompt, assert the flush discards it and the subsequent
  read still waits for a fresh deliberate response. The success
  indicator is substantive only if the test can distinguish
  "stray Enter was discarded" from "prompt accepted the stray
  Enter", so the test must assert the destructive action did NOT
  proceed on the buffered keystroke.
- A wrong M-of-N count. If M is computed from `USB_MODE` but a
  phase is added or removed without updating the derivation, the
  counter lies. Cheap guard: assert the printed N never exceeds
  the computed M, and that the final stage's N equals M.

## Estimated effort

Prompt framing: half a day including the flush test.
Stage progress: half a day, most of it the mechanical counter
threading.

## Sequencing

Both halves are being done in one pass; the broad scope is the
deliberate choice for this card. The two halves remain
independent in implementation (prompt framing is safety-relevant,
stage progress is polish) and should land as separate commits for
a clean history, but neither is being deferred. Within the card,
do the prompt-framing half first: it carries the safety weight,
and if effort runs short it is the half that must not be the one
left undone.

This card is the sole remaining child of (and supersedes the open
scope of) `orchestrator-progress-rewrite-2026-06-16`; the
heartbeat slice already shipped under that umbrella. When this
card lands in full, close it and delete
`docs/roadmap/build-orchestrator-progress.md`, whose entire scope
(heartbeat, prompt framing, stage progress) will then have
shipped.

Target window unchanged: 1.1.0, or whenever the project first
attracts external evaluators, since these are evaluation-context
UX issues. Not a blocker for anything else.

## Open questions

1. For the device-assignment gate, what counts as deliberate
   assent: typing `yes`, or re-typing the device node? The
   latter is stronger (confirms the operator read the specific
   device) but more onerous. Lean: `yes` for the proceed gate,
   device-node echo for the single-device path where a wrong
   device is the most damaging mistake.
2. Stage progress carries a maintenance cost (duration ranges go
   stale). It is in scope for this card regardless, but keep the
   duration table small and treat a stale range as a low-severity
   docs-style fix rather than a correctness bug. If operator
   feedback later shows the heartbeat's elapsed-seconds line is
   sufficient on its own, the duration ranges can be dropped in a
   follow-up without reopening this card.
3. Should `confirm_destructive` live in `run-step.sh` (shared
   with any future caller) or local to `troskel-build.sh` (the
   only current caller)? Lean: `run-step.sh`, consistent with the
   other UI helpers, and testable in `test-run-step.sh`.