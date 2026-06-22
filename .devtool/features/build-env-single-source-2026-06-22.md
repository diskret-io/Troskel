---
id: "build-env-single-source-2026-06-22"
status: "backlog"
priority: "medium"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-22T00:00:00.000Z"
modified: "2026-06-22T00:00:00.000Z"
completedAt: null
labels: ["infra", "quality", "build"]
order: "a1"
---
# Resolve build-environment duplication (container vs bare metal)

Decide whether to keep the bare-metal build path (scripts/prepare-build-machine.sh)
alongside the containerised one (Dockerfile), and if kept, enforce that their tool
lists cannot drift. The two currently duplicate the build station's dependency set
by hand, with nothing asserting they agree.

## Motivation

The build station exists in two forms: the troskel-build container (Dockerfile)
and a bare-metal host provisioned by scripts/prepare-build-machine.sh. The
Dockerfile comment states it mirrors that script, but the mirroring is manual:
each lists the build tools separately, and nothing checks they match. They have
already drifted. The data-USB authenticity gate needed jq on the build station;
it was absent from both lists, and the omission surfaced only as a test failure
inside the container (jq missing) after the feature was otherwise complete. Every
future build dependency carries the same hazard: add it in one place, forget the
other, discover it late.

This is the same silent-drift class the project guards elsewhere (the
Makefile-vs-versions.env pinning check, the manifest-parse vendored-region drift
test). The build-environment lists have no such guard.

## Current state

- Dockerfile: an apt-get install list of build tools (debootstrap, openssl, jq,
  shellcheck, xorriso, etc.).
- scripts/prepare-build-machine.sh: a separate tool-check loop (and apt install
  for missing packages) covering the same set, for a bare-metal Debian/Ubuntu
  build host.
- The two are kept in step by hand. Nothing fails if they diverge.

The bare-metal path's purpose: building Troskel without Docker (some hosts lack
it or do not want a root privileged daemon), and operations that resist
containerisation cleanly (losetup, mkfs.ext4, debootstrap, raw USB writes, which
the container runs under --privileged, a privilege some environments will not
grant). For an air-gapped, security-conscious audience, a no-Docker build path on
a minimal trusted host is a defensible posture.

## Target state

One of two coherent end states, to be chosen:

Option A, keep both, enforce agreement. Retain the bare-metal path. Add a
validate-tier check that fails if the Dockerfile apt list and
prepare-build-machine.sh's tool list disagree (parse both, diff the sets). Drift
then cannot ship. Best if the no-Docker path is genuinely used or expected by
cloners.

Option B, drop the bare-metal path. Delete scripts/prepare-build-machine.sh (and
its references), making the container the single source of truth for the build
environment. No drift is possible because there is one list. Best if, in
practice, everyone uses the container and the bare-metal path is untested or
bit-rotting. Costs the no-Docker build option.

## Implementation outline

Option A:
1. Define a single canonical tool list (e.g. a newline-delimited file or a shell
   array sourced by both), or, if a shared source is too invasive, a validate
   check that extracts both lists and asserts set-equality.
2. Wire the check into Tier 1 (test-validate.sh), failing on any difference, with
   a message naming the tools present in one list but not the other.
3. Backfill: confirm the current lists already agree (after the jq fix) so the
   new check passes on landing.

Option B:
1. Remove scripts/prepare-build-machine.sh.
2. Remove references (README, docs, the Dockerfile "mirrors" comment, any make
   target or CI step that invokes it).
3. Confirm the container path documents the privileged-operation requirements the
   bare-metal path implicitly covered, so a user on a privilege-restricted host
   is not left without guidance.

## Side effects

Option A adds a small build-environment coupling (a shared list or a parser) and
one more validate check. No behavioural change to either build path.

Option B removes a supported workflow. Anyone relying on a no-Docker build loses
it; this must be a deliberate, documented decision, not a silent deletion. If the
repo is public and cloners may want it, dropping it is a user-facing change.

## Estimated effort

Option A: half a day (the check plus confirming current agreement). Option B: a
couple of hours (deletion plus reference cleanup plus a doc note), but the
decision to drop a supported path deserves more deliberation than the work.

## Sequencing

Independent of the authenticity gate (which only needed jq present in both lists,
already fixed). No dependency on other cards. A natural 1.1.x infra item,
alongside the bundle-vendored-regions migration, both are "stop hand-maintaining
duplicated things" cleanups.

## Open questions

- Is the bare-metal path actually used or tested anywhere? If it is never
  exercised (no CI job runs it, no one builds that way), that is strong evidence
  for Option B. If it is used, Option A. This is the fact that decides the card.
- If Option A, shared-source-of-truth (both read one list) or independent-lists-
  plus-equality-check? Shared source is stronger (cannot drift by construction)
  but more invasive to the Dockerfile, which cannot easily source a shell array
  at build time; a parser-and-diff check is looser but trivially compatible with
  the Dockerfile's static apt list.
- Does the container path fully cover what the bare-metal path is for (the
  no-Docker and privilege-restricted cases)? If not, Option B leaves a gap that
  must be documented or otherwise addressed.