# Audience-focused documentation

The project's documentation cross-cuts its audiences. The README opens with the operator's mental model, pivots to the admin's, then ends with the developer's. CONTRIBUTING.md mixes git workflow (relevant to anyone touching the repo) with build and test mechanics (only relevant to developers). `tests/README.md` partially duplicates the developer-facing content of the README. A new contributor of any single role currently has to read across multiple files to find what is relevant to them, while reading past content that does not concern them.

This task reorganises the documentation so each audience has one primary entry point, named after the audience.

## Motivation

The project has three audiences with genuinely different needs:

- **Operators** scan files. They have no interest in how the scanner was built. They want to know what to do, what the verdict colours mean, and what to do when something goes wrong.
- **Admins** prepare USBs before each scan session. They want to know which command to type, in which order, and what to do when it fails.
- **Developers** change the project's code. They want to understand the build pipeline, the test tiers, the contribution workflow, and the design rationale.

Each role has a different mental model of what the project is:

- The operator sees "a thing on a USB that scans my files."
- The admin sees "a build station that produces USBs."
- The developer sees "a repository of scripts I edit and test."

Good documentation serves each mental model in one place. Today's documentation does not: every primary document mixes content from at least two of the three.

The cost of the current arrangement compounds at `1.0.0`. The version is the version where someone other than the current developer might first try to understand the project. A new operator reading the README to learn how to scan a file ends up reading about make targets they will never type. A new admin reading the same README has to skip the operator workflow to find the admin section. A new developer trying to understand the build pipeline has to read CONTRIBUTING for the git conventions, then jump to `tests/README.md` for the test layering, then back to the README for the developer-workflow listing — three documents, none of which is complete on its own.

The reshape is a one-time cost. The benefit is that each audience has one document to read, and the documentation matches the project's natural role boundaries (which the README already names explicitly under "Roles").

## What is currently the case

```
README.md                  Project intro, operator workflow, admin workflow,
                           developer workflow, project structure, security model.
                           Tries to serve every audience at once.
CONTRIBUTING.md            Git workflow + running the tests + refreshing artefacts.
                           Two distinct concerns in one document.
tests/README.md            Test pipeline detail. Partially duplicates the developer
                           workflow section of the README.
docs/ARCHITECTURE.md       Design rationale.
docs/SECURITY.md           Threat model and residual risks.
docs/OPERATOR-GUIDE.md     Operator troubleshooting (verdict outcomes, system-ready
                           failures, what to tell the admin).
docs/roadmap/              Planned work.
```

The audience overlap shows up most acutely in three places:

- The README's "Developer workflow" section gives a 5-target listing of make commands, which only a developer will type. The operator and admin scroll past it.
- CONTRIBUTING's "Running the tests and refreshing artefacts" section covers make targets, Docker volumes, and the test-vs-operational distinction. None of that concerns someone who only wants to know how to commit a change.
- `tests/README.md` exists because the test pipeline needs more explanation than fits in the README, but its content overlaps significantly with the README's developer-workflow section.

## What should change

Reorganise the docs around audiences. The structure becomes:

```
README.md                  Landing page + operator entry. Project intro, what
                           troskel is, the operator workflow, links to per-role
                           docs for everyone else.
CONTRIBUTING.md            Git workflow only. Branches, commits, tags, what not
                           to commit. One-line pointer to docs/DEVELOPER.md for
                           build/test mechanics.
docs/ADMIN.md              NEW. Admin workflow, troskel-build.sh reference,
                           first-time setup, what to do when things fail at the
                           build-station level.
docs/DEVELOPER.md          NEW. Developer workflow, make targets, the
                           containerised pipeline, test tiers, the
                           validate/test/update vocabulary. Absorbs the
                           developer-workflow content from README + tests sections
                           from CONTRIBUTING + tests/README.md.
docs/OPERATOR-GUIDE.md     Unchanged. Operator troubleshooting reference, linked
                           from the README's operator workflow.
docs/ARCHITECTURE.md       Unchanged.
docs/SECURITY.md           Unchanged.
tests/README.md            DELETED. Content absorbed into docs/DEVELOPER.md.
```

### Why this shape

**The README is the operator's primary doc and the landing page simultaneously.** Both jobs are served by similar content: the operator wants "what is this and how do I use it"; the GitHub visitor wants "what is this and why does it exist". The two overlap heavily. Today's README intro already does both well; the change is removing the developer- and admin-specific sections and letting the operator workflow occupy more of the document.

**Per-role docs live under `docs/`, not at the root.** GitHub gives special treatment to a small set of root-level filenames (`README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`); putting unrelated files at the root dilutes the convention. `docs/` already contains `ARCHITECTURE.md`, `SECURITY.md`, `OPERATOR-GUIDE.md`; `ADMIN.md` and `DEVELOPER.md` fit naturally alongside them.

**CONTRIBUTING.md stays at the root, slimmed.** GitHub auto-links it from issue and PR templates and from the "Contribute" tab. Keeping the file at the root preserves that integration. Removing the build/test content lets it become what its name promises: a document about how to contribute to this project's process, not about how to operate the build pipeline.

**`tests/README.md` is deleted, not retained as a deeper reference.** Keeping it would create two docs covering the same ground for the same audience; readers would have to decide which is canonical. One developer-facing doc is cleaner. The full test-pipeline detail moves into `docs/DEVELOPER.md`, where it belongs alongside the make targets it describes.

**OPERATOR-GUIDE.md is kept separate from the README rather than merged in.** The troubleshooting content is detailed enough that merging it into the README would bloat the operator's primary entry point. A separate troubleshooting reference, linked from the README, is the right shape — analogous to how application help systems separate "how to do the thing" from "what to do when the thing breaks".

### Naming

The new docs are named after their audiences (`ADMIN.md`, `DEVELOPER.md`), not their activities (`BUILDING.md`, `DEVELOPING.md`). The audience-based names match the existing vocabulary of the project — the README already establishes "Admin" and "Operator" as roles, with the developer as a third role that has been implicit until now. A reader who knows their own role can find their doc instantly. Activity-based names would force the reader to translate from "what am I" to "what am I doing", which the audience-based names skip.

The `OPERATOR-GUIDE.md` name is grandfathered. Renaming it to `OPERATOR.md` would conflict with the README's role as the operator's primary doc; keeping it as `OPERATOR-GUIDE` preserves the existing convention of "GUIDE" meaning "deeper reference for one role" without creating a name collision.

## Implementation outline

Substantial documentation work, best done as a single PR rather than landed in pieces. Splitting the rearrangement across multiple commits would leave the project in inconsistent intermediate states — for example, CONTRIBUTING.md still containing build/test content while docs/DEVELOPER.md also exists, leaving the reader to wonder which is canonical.

The PR contains:

1. **Create `docs/ADMIN.md`.** Absorbs:
   - The "Admin workflow" section of today's README, including the `troskel-build.sh` flags table and first-time setup.
   - Material currently scattered across the README about `prepare-build-machine.sh`.
   - A new section on what to do when `troskel-build.sh` fails, parallel to OPERATOR-GUIDE's troubleshooting role.

2. **Create `docs/DEVELOPER.md`.** Absorbs:
   - The "Developer workflow" section of today's README.
   - The "Running the tests and refreshing artefacts" section of today's CONTRIBUTING.md.
   - Every section of today's `tests/README.md`.
   - The validate/test/update vocabulary established by the build-system-rationalisation work, with the sub-targets (`test-build`, `test-scan`) presented in a "running individual tiers" subsection per the surface-trim decisions.

3. **Slim `README.md`.** Removes:
   - The "Admin workflow" section (moved to docs/ADMIN.md).
   - The "Developer workflow" section (moved to docs/DEVELOPER.md).
   - The "Project structure" listing of `tests/` (since `tests/README.md` is deleted).
   Adds:
   - A "Per-role documentation" section near the top, immediately after "Roles", linking each role to its doc.
   - A pointer in the operator workflow to OPERATOR-GUIDE for troubleshooting (this is already there; preserve it).

4. **Slim `CONTRIBUTING.md`.** Removes:
   - The "Running the tests and refreshing artefacts" section and all its subsections.
   Adds:
   - A short pointer near the top: "Working on the build pipeline or tests? See docs/DEVELOPER.md."

5. **Delete `tests/README.md`.** Content has moved to docs/DEVELOPER.md.

6. **Update cross-references.** Anything in the repo that links to `tests/README.md` is updated to point at `docs/DEVELOPER.md`. The README's roadmap-pointing language stays unchanged. Roadmap docs that reference the developer workflow (none today, but check) are updated.

## Side effects on existing scripts

None. This is purely a documentation reshape; no scripts, no Makefile targets, no CI workflow changes. The content moves between documents but the underlying mechanisms it describes are unchanged.

One indirect effect: scripts that print "see CONTRIBUTING.md" or "see tests/README.md" should be checked for stale pointers and updated. A grep at PR time catches this.

## Estimated effort

One full developer-day if done end-to-end. The content largely exists already; the work is rearrangement, transitions, and verifying that each new doc reads coherently on its own without assuming the reader has seen the others.

The single largest piece is `docs/DEVELOPER.md`, which absorbs material from three sources (README, CONTRIBUTING, tests/README.md) and needs internal structure that does not exist in any of the three. Probably half a day on its own.

The README slimming is the smallest piece — mostly deletions and a new short "Per-role documentation" section.

## Sequencing

Independent of every other roadmap item. Does not block `1.0.0` semantically — the documentation works as-is — but it is the right kind of clarity improvement to do *before* `1.0.0` rather than after, for the same reason the build-system-rationalisation work targeted `1.0.0`: a new contributor's first impression of the project is set by what these documents say. Better to have the per-audience shape in place before the version that invites new contributors.

Target `1.0.0`. The work that should land before this:

- The surface-trim PR (the developer-workflow content needs to settle on the validate/test/update vocabulary before being moved into docs/DEVELOPER.md). If the surface-trim PR is rolled into this reshape — by baking the validate/test/update decisions directly into docs/DEVELOPER.md from the start — the two PRs become one. This is the recommended order; see Open questions below.

The work this enables:

- Deleting `docs/roadmap/build-system-rationalisation.md` (the surface-trim PR was its last open item). Same cleanup pattern as the previously-deleted roadmap docs.

## Open questions

- **Roll the surface-trim PR into this reshape, or land surface-trim first?** Rolling them together avoids touching the same documentation twice and avoids an interim state where `tests/README.md` and `CONTRIBUTING.md` have been reshaped but are about to be deleted or slimmed anyway. The argument for landing surface-trim first is "smaller, more focused PRs"; the argument against is that this reshape moves the surface-trimmed content into entirely different documents, so the surface-trim becomes wasted intermediate work. Recommendation: roll them together. The `troskel-build.sh` orchestration cleanup (the `_run_update` removal and delegation to `make update`) is independent of doc structure and lands as its own small PR before this reshape.

- **Should `docs/ADMIN.md` include a troubleshooting section, or remain just the workflow?** The admin runs into more failure modes than the operator (USB detection failing, network unavailable, signatures stale, container build broken), but most of them are diagnosed by reading the script output of `troskel-build.sh` directly. The recommendation is a short "When things fail" section pointing at the obvious diagnostic commands (`make update --debug`, `docker logs`, the relevant log paths under `/var/lib/troskel/`), without enumerating every possible failure. If admins repeatedly hit the same class of failure, expand the section.

- **Where does the "First-time setup" content live?** Currently it sits inside the README's Admin workflow section. The natural home is `docs/ADMIN.md`, since the admin is the one running first-time setup. But a developer doing first-time clone-and-test also runs `prepare-build-machine.sh` indirectly via `make image`, so there is a case for documenting setup once in `docs/DEVELOPER.md` and pointing the admin at it. Recommendation: keep the first-time-setup content in `docs/ADMIN.md` (since that is what the user-facing audience expects), and have `docs/DEVELOPER.md` note "the build station has the same prerequisites as a development machine" with a cross-link.

- **Single PR or split across two or three?** A single PR is heavier to review but easier to verify (all the docs are coherent at the end of the PR; no intermediate state). Splitting would mean creating the new docs in one PR, slimming the old docs in a second, deleting tests/README.md in a third — each individually reviewable but with an intermediate state where content is duplicated. Recommendation: single PR. The review surface is bounded (five files: README, CONTRIBUTING, two new docs, one deletion), and the work is mostly content rearrangement that benefits from being seen as a whole.

- **`docs/DEVELOPER.md` table of contents — yes or no?** A six-section document is borderline; adding a TOC adds value if the reader is navigating, adds noise if they are reading straight through. Recommendation: no TOC unless the doc grows past 200 lines, at which point the section headings are sparse enough that a TOC starts to earn its keep.

- **Should we keep a `tests/` directory README at all?** A repo browser opening `tests/` on GitHub gets no orientation if there is no README in that directory. A one-line `tests/README.md` saying "test scripts run by `make test`; see docs/DEVELOPER.md for the test pipeline" preserves the orientation cheaply. Recommendation: keep a minimal `tests/README.md` of that shape rather than deleting outright. Update the implementation outline accordingly if this is accepted.