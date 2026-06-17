---
id: "release-1.0.0-2026-06-17"
status: "todo"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-17T19:30:00.000Z"
modified: "2026-06-17T19:30:00.000Z"
completedAt: null
labels: ["release", "docs"]
order: "a0"
---
# Final drift pass and v1.0.0 tag

The 1.0.0 priority work (troskel-build.sh delegation to `make update`,
audience-focused docs reshape, deletion of
`build-system-rationalisation.md`, manifest propagation through
prepare-data-usb.sh / load-scanner / show-status) has landed. What
remains before the tag is a single drift-cleanup pass and the tag
itself.

## Why it matters

A version tag is a checkpoint deployers return to. Tagging while the
working tree still contains stale cross-references, a version string
that disagrees with itself, or a roadmap doc whose subject has shipped
makes 1.0.0 a worse reference point than the commits around it. The
drift pass is cheap; doing it after the tag means the tag points at a
known-imperfect tree.

## Drift pass: what to check

A failure here is a stale or contradictory artefact surviving into the
tagged tree. Each check below names what it would catch.

- **Stale version strings.** Grep the tree for the previous version
  (`0.9.1`) and for any older survivor (`0.1.0`, the string the
  earlier bump audit found). Catches: a version reference that did not
  travel with the last bump. Note: `centralise-version-metadata` is
  the durable fix; this pass is the stopgap grep until that card lands.
- **Dangling doc cross-references.** Grep docs and roadmap files for
  links to `build-system-rationalisation.md` and any other deleted
  doc. Catches: a reference outliving its target.
- **Roadmap docs whose subject shipped.** Confirm
  `build-system-rationalisation.md` is deleted (priority item 3).
  Audit `docs/roadmap/` for any other doc describing work now in
  `main`; shipped roadmap docs get deleted, not retained.
- **Make-vocabulary drift.** Confirm README / ADMIN.md / DEVELOPER.md
  describe only the current vocabulary (validate, test, update;
  test-build, test-scan; image, clean) and that the deprecated aliases
  (build, scan, all) are described as deprecated, not as primary.
  Catches: docs teaching a vocabulary the Makefile no longer leads with.
- **Manifest absent-case wording.** Confirm the operator-facing
  "data USB predates manifest support" path in show-status still
  matches what prepare-data-usb.sh writes, now that propagation has
  landed. Catches: a guard message that has drifted from the producer.

The pass is a grep-and-read sweep, not a code change. If it surfaces
anything non-trivial, that becomes its own card rather than expanding
this one.

## Acceptance criteria

- `make validate` and `make test` green on a clean `main`.
- The grep sweeps above return nothing, or each hit is resolved in a
  `chore:`/`docs:` commit before the tag.
- `build-system-rationalisation.md` confirmed absent from the tree.
- Tag created on `main` after the drift commits land:
  `git tag -a v1.0.0 -m "release: v1.0.0"` then `git push origin v1.0.0`.
- CI Tier 2+3 green on the tagged commit (push-to-main triggers).

## Sequencing

Last card before the tag. No dependency on the post-1.0.0 backlog
cluster. `centralise-version-metadata` is the natural companion if it
is pulled into the same bump, but is not a blocker: the grep stopgap
covers 1.0.0 on its own.

## Open question

Does the v1.0.0 tag also carry release notes, or does the
"tag is a checkpoint, not a formal release" convention from
CONTRIBUTING still hold at 1.0.0? The convention as written says no
notes; 1.0.0 may be the point that changes. Decide before tagging.