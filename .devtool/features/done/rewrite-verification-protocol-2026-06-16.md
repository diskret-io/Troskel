---
id: "rewrite-verification-protocol-2026-06-16"
status: "done"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-16T18:25:11.791Z"
modified: "2026-06-20T12:58:48.029Z"
completedAt: "2026-06-20T12:58:48.029Z"
labels: ["refactor", "quality", "security"]
order: "Zv"
---
# Rewrite verification protocol as isolated module

The sidecar produce/verify/re-verify protocol currently lives across
three bash scripts (`build-scanner-image.sh`,
`prepare-data-usb.sh`, `troskel-build.sh`). Each implementation is
hand-rolled, each can drift independently, and the contract between
them is implicit. Bug 2 (sidecar absolute path) is exactly the
failure mode this layout permits.

Rewrite the protocol as one small module (Python or Rust) with:

- An explicit type for "verified artefact" (file path, expected
  hash, status enum).
- A producer function that emits the sidecar in a canonical format,
  by construction never absolute-path.
- A consumer function that takes a mount point and a sidecar and
  returns a typed result (`Verified`, `MismatchOnDisk`, `MissingFile`,
  `MalformedSidecar`).
- Unit tests covering each variant of the consumer result.

The three bash scripts become thin wrappers that shell out to this
module. The protocol contract becomes type-enforced rather than
documentation-enforced.

## Acceptance criteria

- New module exists, with unit tests covering each result variant.
- `build-scanner-image.sh` calls the module to emit the sidecar
  (replacing the current `sha256sum` line).
- `prepare-data-usb.sh` calls the module to verify (replacing the
  current `sha256sum --check`).
- `troskel-build.sh` phase 5 calls the module to verify (same).
- The negative-case test from `negative-case-test-sidecar` passes
  unchanged against the new module.

## Sequencing

Lands after the quality foundations (system prompt, QUALITY.md,
both negative-case tests, CI surfacing). The foundations make this
rewrite tractable; without them, the rewrite is just shuffling
silent failures into a different syntax.

## Language

Python is the cheap option. The build station already has Python.
Rust is more rigorous but a higher dependency burden. Lean: Python
unless k prefers Rust. Decision deferred to implementation time.

## Notes

This is the first targeted rewrite under the "don't rewrite the
whole project, rewrite the dangerous bits" approach discussed in
the post-incident review. The orchestrator stage runner is the
next candidate after this one.