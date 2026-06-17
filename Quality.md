# QUALITY.md

The quality bar this project holds itself to. Read by contributors
before opening a pull request. The rules below are not aspirational;
they are how the code in this repository is expected to be written.
Reviewers will hold changes to them.

This is a security-critical project. The cost of a silent failure
in a security-critical project is not "an irritated user"; it is
"an operator who carries a compromised artefact into an air-gapped
environment believing it to be clean." The standards below exist to
make that class of failure structurally harder to introduce, not
just easier to detect after the fact.

## Posture

Troskel is a security tool. The standards below apply to every
script, every test, every documentation change. The intent is not
ceremonial rigour; the intent is that a reader six months from now,
debugging a failure in production, can understand what each line
was supposed to do and how the author expected it to fail.

If a change cannot meet the standards below, it does not land. The
project would rather ship slower than ship a green tick that
guarantees nothing.

## The five principles

### 1. The failure-modes-first principle

Before writing the success path, name at least one failure mode the
code must handle, and how that failure will be tested. The success
path is the easy part; the failure path is what determines whether
the project is safe.

This is not a documentation requirement at the comment level; it is
a thinking requirement. Knowing what the code is supposed to do
when something goes wrong shapes the success path itself. Code
written without an answer to "what fails here, and how do I know?"
tends to be brittle in the specific way that produces silent
failures.

Concrete: a function that writes a file should be written with a
clear answer to "what if the disk is full," "what if the file is
on a busy mountpoint," "what if the write succeeds but the data is
wrong." A function that verifies a checksum should be written with
a clear answer to "what if the file does not exist," "what if the
checksum file points at the wrong file," "what if the checksum
algorithm is wrong." If the answer is "the function returns
success," the function is not yet ready.

### 2. Success indicators must be substantive

A success indicator (an `ok` log line, a tick in a progress
display, a return code of zero, a green box at the end of a build)
must be the result of a check that could plausibly have failed. If
the check cannot, in principle, distinguish success from the
failure mode it claims to detect, the check is decorative.
Decorative checks are forbidden.

This is the principle that would have caught the project's two
recent silent-failure bugs. Worked example:

**The sidecar absolute-path bug.** The verification step in
`prepare-data-usb.sh` ran `sha256sum --check` against
`scanner-rootfs.ext4.sha256`. The check reported `OK` and the
script proceeded. What the check actually did: read the sidecar,
which contained the absolute path
`/var/lib/troskel/scanner-rootfs.ext4`, follow that absolute path
back to the source file on the build station, and verify the
source against its own sidecar. The check could not have failed
unless the source file changed mid-build; it had no relationship
to whether the USB write succeeded. The `OK` was decorative.

The fix is in `scripts/build-scanner-image.sh`: emit the sidecar
with a relative path so the verifier's `cd "$MOUNT"` actually
matters. With the fix, the check can plausibly fail (if the USB
write was incomplete, the checksum will not match), and so the
`OK` carries information.

The lesson: every time a check reports success, ask "what would
this check report if the thing it is checking were broken?" If the
answer is "it would still report success in the failure mode I
care about," the check is decorative.

### 3. Cross-script protocols need contracts

Any protocol that spans more than one script (a file format, an
exit code convention, an environment variable, an output format
the next stage parses) requires a contract comment at both
producer and consumer sites. The comment names the other end and
states what is promised in both directions.

This is light-touch: a paragraph at each end, not a formal spec.
But it must exist, because the alternative is a producer and a
consumer that drift independently, each locally correct, globally
wrong.

Worked example. The sidecar protocol now lives across three
scripts: `build-scanner-image.sh` emits the sidecar,
`prepare-data-usb.sh` verifies, `troskel-build.sh` re-verifies.
With the fix landed, each site carries (or should carry) a
contract comment noting that the sidecar contains a relative path,
the verifier expects to `cd` into the mount before checking, and
both expectations must move together.

A protocol with no written contract is a protocol that will drift.
The contract comment is the cheapest form of insurance against
drift; it makes the assumption explicit at the site of the
assumption, where the next person to touch the code will see it.

### 4. Destructive operations require destination verification

Any operation that produces an artefact (a USB write, a file
emission, a partition table modification) requires a verification
step that re-reads from the destination, not from the source.

This is a corollary of principle 2, called out separately because
the failure mode is uniquely bad: the operation reports success,
the artefact exists in the source, the artefact is missing or
corrupt at the destination, and downstream code consumes the
artefact assuming it is correct. For a security workflow, the
downstream consumption may be an operator carrying a USB to an
air-gapped environment.

Worked example. The orchestrator's Phase 5 verification of the
data USB reads the sidecar from `/var/lib/troskel/` and verifies
against the file at the same path (the source, before the fix).
The fix routes the verification through `cd "$VMOUNT"` so it reads
from the USB. The verification step is the only thing between
"data USB was written" and "operator carries it to the air-gapped
environment"; if the verification reads from the wrong place, the
operator is told the USB is good when it is not.

Where re-reading from the destination is expensive, prefer two
checks: a cheap post-condition immediately after the operation
(file exists, non-zero size, expected filesystem signature) and a
heavier verification before the artefact is used. The cheap check
catches "nothing was written"; the heavy check catches "wrong
content was written." They catch different failure modes; both
should run.

### 5. Exit codes are not the only signal worth trusting

When orchestration code wraps a sub-script and treats the
sub-script's exit code as the sole signal of success, every layer
of swallowed errors inside the sub-script becomes invisible.
`set -euo pipefail` is necessary but not sufficient; `|| true` and
similar patterns can defeat it locally; the outer wrapper has no
way to know.

Where a wrapper invokes a sub-script that produces an observable
side effect (a file written, a device modified, a network call
made), the wrapper should also check the side effect. The sub-
script's exit code is one input; the post-condition is another.
Both must agree.

The orchestrator's `run_step` function (`scripts/troskel-build.sh`)
implements this with an optional `POSTCOND` argument. A caller that
wants the side-effect check passes a function name; `run_step`
calls it after the sub-script returns zero, and a non-zero return
from the post-condition fails the stage. This pattern caught a
real failure on its first run: a sub-script that aborted on a
missing confirmation prompt returned zero, the orchestrator would
have reported success, the USB was not written, and the post-
condition detected the absent artefact.

## Bash idioms

### Forbidden

- **`|| true` without justification.** This pattern converts "fail
  safely" into "fail silently". Every use requires a comment at
  the site naming why this particular failure is acceptable and
  what downstream code guards against the failure case. A use
  without a comment will be removed during review.

- **Output-capturing wrappers that swallow stderr without
  preserving it for diagnosis.** A wrapper that captures output to
  hide normal-run noise must dump the captured output on failure.
  An operator looking at a failed run must see the underlying tool's
  error message.

- **Silent failure with no exit propagation.** A sub-script that
  catches an error internally and continues, ultimately exiting
  zero, defeats every outer wrapper. If the sub-script cannot
  proceed, it must `exit` non-zero. The wrapper trusts the exit
  code; the sub-script must make the exit code mean something.

- **Decorative checks.** `echo "[+] OK"` after an operation that
  has no actual verification is forbidden. The `OK` line must
  follow a check that could have reported failure.

### Encouraged

- **`set -euo pipefail` at the top of every script.** Default.
  Combined with discipline about `|| true`, this gives sound
  error propagation without ceremony.

- **Explicit exit codes from sub-scripts.** A sub-script's exit
  code is its contract with the orchestrator. Make it accurate.
  Zero means the work is done; non-zero means it is not. No third
  state.

- **Named functions over inline expressions for any logic that
  needs error handling.** The chain
  `cmd1 && cmd2 && cmd3 || handle_error` looks compact but conceals
  which step failed. A named function with explicit `if` blocks at
  each step makes the failure mode explicit at the failure site.

- **Post-condition checks alongside exit codes.** Where the side
  effect is observable, check it. The `run_step` function in
  `troskel-build.sh` is the project's reference implementation.

- **Contract comments at both ends of any cross-script protocol.**
  See principle 3. A paragraph at the producer site and a
  paragraph at the consumer site, each naming the other.

## Regression tests

For every bug fixed, the test that proves the fix works is the
same test that would have caught the bug at introduction. Write
the test as part of the fix.

This is light-touch: the test does not need to be elaborate. The
bug is the fixture. The test reproduces the bug's preconditions,
applies the verification or operation the fix touched, and asserts
the verification fails or the operation succeeds, as appropriate.

Concrete: the sidecar bug. The proof the fix works is "deliberately
corrupt the USB after writing, rerun verification, assert
verification fails." That test, run on every PR, would have caught
the original bug at introduction. It is now part of the project's
test inventory (kanban card `negative-case-test-sidecar`).

Light-touch does not mean optional. A fix without a regression
test leaves the door open for the bug to recur the next time
someone refactors the surrounding code.

## The bug-masking phenomenon

When silent failures stack, fixing the outermost layer surfaces
the next. The project recently encountered this in concentrated
form: three bugs in the USB write path masking each other across
several test runs.

The cycle:

1. **The sidecar absolute path** caused verification to check the
   source rather than the USB. A failed write would still verify
   as `OK`.
2. **The orchestrator's `|| true` on `umount`** caused destructive
   operations to run against busy devices, producing writes that
   landed in stale page cache rather than on the device. Verify
   then reported `OK` against the source (bug 1 masking).
3. **The inner-script confirmation prompt** read from a stdin
   captured by the orchestrator, timed out to a default `no`, and
   exited zero. Sub-script reported success, USB was untouched.
   Orchestrator reported `OK` (bug 2 masking).
4. **The passphrase capture's `sed` range** matched the wrong
   end-of-range pattern, captured an empty string, and silently
   produced a summary box with no passphrase. Operator received
   no signal that anything was wrong (would only have surfaced if
   the operator tried to log in with a passphrase they did not
   have).

Each fix surfaced the next layer. Each layer had been present for
some time; only the previous fix made it visible.

The lesson: after fixing a bug in this class, ask "what is the
next layer underneath this fix?" The fix made one thing visible;
something else may now be the gating failure. Run the full
workflow again. Do not assume the bug just fixed was the last.

This is why principles 1 and 2 are written as principles, not as
post-hoc checks. The structural prevention is at the design stage;
post-hoc detection catches only what someone thought to test for.

## What this document is not

QUALITY.md is the rationale source: it explains why the standards
exist and gives worked examples of what happens when they are not
followed. It is not a coding standard in the narrow sense (it does
not specify line lengths, naming conventions, or other surface-
level rules; those live elsewhere or implicitly in the existing
code) and it is not a test specification. QUALITY.md is about the
shape of safe code in this project, not its appearance.

The operative rules derived from this document, in a form suitable
for automated enforcement and routine application, live in the
project's contributor instructions.

## Updates

This document gets updated when the project encounters a new
class of failure not already captured. Add a new principle, or a
worked example to an existing principle, or both. The recent
bug-masking phenomenon section is the most recent addition; it
came from the three-bug cycle in the pre-1.0.0 release work and
generalises a pattern that was not previously articulated.

If you are about to write a change that does not fit the existing
principles cleanly, that may be a signal the document needs
expansion rather than the change being wrong. Raise it.