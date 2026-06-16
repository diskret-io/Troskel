# Build orchestrator progress reporting

## Motivation

The current `scripts/troskel-build.sh` orchestrates a multi-stage
build and USB-write workflow whose individual stages take from
seconds (preflight checks) to many minutes (CoreOS ISO download,
4 GiB image writes to USB, debootstrap-based rootfs construction).
The wrapper captures stdout and stderr from the underlying tools
and replaces them with a compact progress display: a stage name,
a spinner, and a tick or cross at the end.

This is fine when stages succeed quickly and unambiguously. It
fails the operator in three observable ways:

1. **Long stages look hung.** Writing the boot USB via
   `coreos-installer` can take 10 to 15 minutes silently from the
   operator's perspective. There is no indication that work is
   progressing, no estimate of how long the stage normally takes,
   and no recourse other than to wait or interrupt. During a 1.0.0
   pre-tag build the operator reported the boot-USB write stage
   appearing stuck and pressing Enter, which was both a UX failure
   (silence implied "waiting for input") and a near-miss (Enter
   could plausibly have been interpreted as confirmation of
   something destructive in a different stage).
2. **Failures lose context.** When a stage fails, the captured
   output is summarised as a one-line message ("Build failed at:
   Writing TROSKEL-DATA"), and the operator is instructed to
   rerun with `--debug`. The underlying tool's actual error
   message, which would let the operator diagnose without rerunning
   a 20-minute build, is buried in the suppressed output.
3. **Stage boundaries are unclear.** Operators cannot tell whether
   silence after a stage's tick means the next stage hasn't
   started, is starting, or is mid-execution. There is no
   "Stage N of M" framing and no indication of the expected
   total duration.

## Current state

`troskel-build.sh` runs each substantive stage via a function that
captures output to a temp file, displays a spinner, and prints a
tick or cross based on exit status. On failure, the operator is
told to rerun with `--debug` to see the captured output. There is
no per-stage time estimate, no progress within a stage, no
indication of expected total duration, and no surfacing of the
underlying tool's progress reporting where it exists
(`coreos-installer`, `dd`, `debootstrap` all produce useful output
that is currently hidden).

## Target state

An orchestrator that gives the operator continuous, accurate
information about what is happening at each stage and what to
expect next. Specifically:

- Each stage announces itself with name and expected duration
  range before starting.
- Long-running stages surface the underlying tool's progress
  output verbatim, optionally framed by the orchestrator with
  headers and footers.
- Failures show the underlying tool's last N lines of output
  inline, not buried behind a `--debug` rerun. The full output
  is also written to a stage-specific log file for later
  examination.
- A "Stage N of M" indicator runs throughout, with a running
  estimate of remaining time.
- Operator confirmation prompts are visually distinct from
  progress output (different colour, explicit framing) so
  pressing Enter cannot be misinterpreted as confirming
  something the operator did not see.

## Implementation outline

Three substantive shapes; one to pick at implementation time.

**Option A: thin wrapper, verbose tools.**

Replace the output-capturing pattern with direct pass-through.
The orchestrator prints headers and footers; the underlying tool
prints what it normally prints. `coreos-installer` already has
progress reporting; `dd` can be invoked with `status=progress`;
`debootstrap` is verbose by default.

Pros: minimal code change, smallest surface area, the most
information for the operator. Cons: output volume is high and
the visual cohesion of the current display is lost. Distinguishing
orchestrator messages from tool messages becomes a discipline
question.

**Option B: structured progress with TUI library.**

Introduce a TUI library (whiptail, dialog, or a more modern
choice) and present stages as a structured progress display with
per-stage progress bars where the underlying tool can be parsed
for percentage, and an unparseable-output panel where it cannot.
Failures pop up a dialog with the last N lines and offer to write
the full log to disk.

Pros: highest polish; clearly delineates orchestrator from tool.
Cons: a new dependency, harder to debug, harder to test in CI
(non-interactive terminals need a fallback path), and the polish
is somewhat at odds with the project's spartan-by-design tone.

**Option C: structured logging to a parallel log file, live tail.**

The orchestrator writes structured progress events to a log file
(`/var/lib/troskel/logs/build-orchestrator.log`) with timestamps,
stage names, and verdicts; underlying tool output goes
verbatim to the terminal. A second terminal or `tail -f` shows
machine-readable progress; the operator sees what they always
see for the underlying tool. Failures cite the log file and the
underlying tool's exit line.

Pros: separates concerns cleanly; the log file is useful for
later diagnosis; minimal change to the visible operator
experience apart from removing the output suppression. Cons: two
streams of information now exist and the operator must learn
they exist.

Recommendation lean: option A for the smallest change that fixes
the observed UX problems, with option C as a follow-up if logs
turn out to be useful for support requests.

## Side effects

- Output volume increases substantially in the operator's
  terminal during long stages. This is the point.
- The captured-output-on-failure pattern is gone; if anything
  in the operator's environment depended on it (e.g. a CI
  consumer of `troskel-build.sh`'s stdout structure), it
  breaks.
- The `--debug` flag changes meaning. Currently it shows
  captured output after a failure; in the new model the
  captured output is always shown and `--debug` becomes a
  flag for extra orchestrator-level tracing (which stages
  ran, in what order, with what arguments).

## Estimated effort

Option A: half a day. Most of the work is removing the
output-capture wrapper functions and adapting the failure path.

Option B: three to four days. A real TUI requires test
coverage for terminal-detection paths, fallback paths for
non-interactive use, and design work for the failure-dialog
flow.

Option C: one to two days. Mostly a logging library design and
wiring it through the existing orchestrator without disrupting
the operator-visible flow.

## Sequencing

Standalone with respect to other roadmap items. The natural
landing window is 1.1.0 or whichever release first attracts
external evaluators, since the UX failures are precisely the
kind of thing that erodes confidence in an evaluation context.
Not a 1.0.0 blocker; the operator workflow works, it just
doesn't work pleasantly.

If the verdict-grammar work (`docs/roadmap/verdict-grammar.md`)
lands before this, that work introduces structured output
parsing in the scanner pipeline which may inform the structured-
logging shape chosen here.

## Open questions

1. Option A, B, or C? Lean: option A first, with option C
   added later if support-burden data suggests it is needed.
2. Should the orchestrator stop capturing output entirely, or
   capture-and-tee (output goes to terminal AND a log file
   simultaneously)? Lean: capture-and-tee, since the log file
   has independent value for post-hoc diagnosis.
3. How is "expected duration" derived for stages whose
   duration varies wildly (USB writes, depending on USB
   speed; ISO downloads, depending on bandwidth)? A range
   ("typically 5 to 15 minutes") seems honest; a single
   number invites the wrong kind of operator expectation.
4. Does the `--debug` flag get repurposed or retired? Lean:
   repurposed for orchestrator-level tracing only.