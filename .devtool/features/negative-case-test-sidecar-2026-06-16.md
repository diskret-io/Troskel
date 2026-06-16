---
id: "negative-case-test-sidecar-2026-06-16"
status: "todo"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.782Z"
modified: "2026-06-16T18:25:11.782Z"
completedAt: null
labels: ["tests", "quality", "security"]
order: "a4"
---
# Negative-case test: sidecar verify catches USB corruption

The sidecar bug just fixed went undetected because the test suite
exercised only the happy path. A test that proves the verifier
actually catches a corrupt USB would have caught the bug at
introduction.

## Acceptance criteria

A test (in `tests/`, run as part of `make test`) that:

1. Writes a USB image to a loop device (no physical USB required).
2. Deliberately corrupts the image after the write (flip a byte
   somewhere in the middle of the file).
3. Runs the verification logic.
4. Asserts that verification fails.

The test must fail under the pre-fix code (absolute-path sidecar)
and pass under the post-fix code (relative-path sidecar). This is
the proof the fix is correct and the alarm if it regresses.

## Notes

Use a loop device, not a real USB, so the test is hermetic and
CI-runnable. The test should not depend on hardware.

This card is part of the broader quality-foundations work
(`quality-foundations-2026-06-16`). It is the first concrete test
that exercises a failure mode rather than a success path.