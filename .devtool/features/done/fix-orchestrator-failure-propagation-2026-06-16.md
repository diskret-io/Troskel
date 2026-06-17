---
id: "fix-orchestrator-failure-propagation-2026-06-16"
status: "done"
priority: "critical"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.769Z"
modified: "2026-06-16T19:50:13.923Z"
completedAt: "2026-06-16T19:50:13.923Z"
labels: ["bug", "security", "infra"]
order: "a3"
---
# Orchestrator hides write failures from inner scripts

`troskel-build.sh` runs `prepare-data-usb.sh` and `prepare-boot-usb.sh`
with captured output and reports a green tick based on exit code.
Inner scripts that fail silently (via `|| true` swallowing `umount`,
`wipefs`, or other errors) cause the orchestrator to report success
against USBs that were never written. Confirmed during the pre-1.0.0
test session: data USB reported as written, on inspection still
contained the original Fedora ISO content.

This is a silent safety failure: an operator cannot tell a successful
write from a swallowed-error no-op. For a security workflow where the
operator carries the USB to an air-gapped environment, this is the
worst possible failure shape.

Bug 2 (sidecar relative path) compounded this: even when the
orchestrator's verify step ran, it verified the source on the host
rather than the copy on the USB, so a never-written USB could also
pass verification. Bug 2 is fixed; this card is the remaining half.

## Acceptance criteria

- Inner script `umount`, `wipefs`, and other destructive-prep failures
  cause the inner script to exit non-zero.
- The orchestrator surfaces that exit code as a failed stage with the
  underlying error message visible, not buried behind `--debug`.
- `|| true` patterns swallowing errors on destructive-prep operations
  are removed or replaced with explicit-fail-with-message.
- A negative-case test (see `negative-case-test-orchestrator`) proves
  the orchestrator no longer reports success against a forced
  inner-script failure.

## Related

- Bug 2 (already fixed): `fix-sidecar-relative-path-2026-06-16`
- Roadmap doc: `docs/roadmap/build-orchestrator-progress.md` (the
  broader UX rewrite; this card is the narrower failure-propagation
  bug that must land before 1.0.0)