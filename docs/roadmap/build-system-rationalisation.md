# Build-system rationalisation

The build and test machinery grew organically. Each addition was the simplest next step at the time, and what we have today works but does not present a coherent picture to a new developer: validation, build testing, scan testing, and real-build artefact production live at different levels of the system, with overlapping names and inconsistent invocation paths. The host-direct execution path that several test scripts assume is a particular source of friction on non-Debian Linux hosts (NixOS, minimal containers) and accumulates patches that would not be needed in a containerised pipeline. This task rationalises the layering, settles on a `make`-based vocabulary, and documents the Linux-only support contract explicitly.

## Motivation

A new contributor lands on the repo and asks: "how do I run the tests?" The current answer is "read the README and the Makefile and the tests/ directory and the .github/workflows/ files, and then know that `make build` is actually a test-the-build-pipeline target rather than a produce-real-deliverables target." That is too much ambient knowledge to expect from someone wanting to make their first change.

The current shape carries three concrete pieces of accumulated debt:

- **`tests/test-build.sh` runs host-directly in some invocations and inside the container in others.** When a developer types `sudo bash tests/test-build.sh` from the project root, it runs on the host. When CI or `make build` invokes it, it runs inside the `troskel-build` container. The script's behaviour is identical, but the *environment it runs against* is not — and several of the patches recently landed (kernel chown UID fix, the freshclam DatabaseOwner-root fix, the chown-versions.env preservation in download-kernel.sh) exist to paper over differences between Debian-the-container and the developer's NixOS-or-other-distro host. With host-direct execution removed, these patches become unnecessary because the container is always Debian.

- **`make validate` and the test pipeline are not parallel concepts.** Validation is "did you break the syntax of any committed file" and runs in seconds. The test pipeline is "does the system behave correctly end-to-end" and runs in minutes. Both go through `make`, but only validation has a single clean name — the tests are split across `make build` and `make scan` with no `make test` aggregator. A developer wanting "run all the tests" has to remember the two targets.

- **`make build` is named for what it appears to do, not what it does.** A developer reading "make build" reasonably expects a production-build artefact-producing target. What it actually does is run the build-pipeline test (`tests/test-build.sh`) in a containerised environment, producing artefacts in a named volume the container shares with `make scan`. The deliverable-producing flow is `prepare-data-usb.sh` plus `prepare-boot-usb.sh`, which sit outside the `make` vocabulary entirely. The naming inversion isn't visible until someone needs the difference; once it is, it's confusing.

These three things accumulate without being individually bad. The rationalisation treats them as one piece of work because they share one root cause: the layering grew before the vocabulary did.

## What is currently the case

```
make image      Build the troskel-build container image.
make validate   Tier 1: shellcheck + butane. No privileges. Containerised.
make build      Tier 2: full build-pipeline test. --privileged. Containerised.
make scan       Tier 3: Firecracker scan test. --privileged + /dev/kvm. Containerised.
make all        Tiers 1, 2, 3 in sequence.
make clean      Remove image and artefact volume.
```

Backing scripts:

- `tests/test-validate.sh` — invoked by `make validate`.
- `tests/test-build.sh` — invoked by `make build` (containerised) and by direct host invocation (host-side).
- `tests/test-scan.sh` — invoked by `make scan` (containerised, with /dev/kvm passed through) and by direct host invocation.
- `scripts/run-update.sh` — the operational signature-refresh path. Calls the download scripts and the image-build script. Not invoked through `make` today.
- `scripts/prepare-data-usb.sh`, `scripts/prepare-boot-usb.sh` — the operational USB-writing paths. Not invoked through `make` today.
- `scripts/prepare-build-machine.sh` — host-side tool installation. The hostside fallback for when the developer wants to run scripts directly.

`Dockerfile` already exists and bakes in build tooling (Firecracker, Butane, LOKI-RS via `--build-arg` from `versions.env`). Signatures, YARA rules, and the kernel are downloaded at runtime by the test scripts.

CI runs all three tiers but the exact invocation path is in `.github/workflows/` and is not part of this analysis — the rationalisation should leave CI invoking `make`-targets only, so the workflow files become small and the test logic stays in the Makefile.

## What should change

Five concrete changes. None individually large; the value is in shipping them together so the resulting vocabulary is uniform.

### 1. Remove the host-direct execution path for test scripts

`tests/test-build.sh` and `tests/test-scan.sh` are documented and supported only as targets of `make test` (or its sub-aggregators). The "run the script directly on your host" path is removed from documentation and gated in the scripts themselves: each script begins with a check that it is running inside the troskel-build container (e.g. `[ -f /.troskel-container ] || { echo "Run via 'make test'."; exit 1; }`), where `.troskel-container` is a sentinel created by the Dockerfile.

The scripts continue to exist as the test logic — they are not deleted, just no longer invoked from the host. The patches that exist to make them work on the host (kernel UID-vs-name chown fix, freshclam DatabaseOwner-root fix) remain in the code; they are correct fixes that also work inside the container, and removing them would couple this rationalisation work to those scripts in ways that complicate review.

A developer who genuinely needs to iterate on a single script (the (F) inner-loop case) can still run it directly via `docker run --rm --privileged --volume "$PWD:/troskel" troskel-build bash scripts/download-loki-yara-rules.sh` — same invocation pattern as `make build` but targeting a single script. This is documented in CONTRIBUTING.md as the explicit fast-iteration path; the cost is one container start (a few seconds) per iteration. The previous host-direct path imposed the cost of "your distro must be Debian-like enough"; the new path imposes the cost of "one Docker invocation per run". For a Linux developer this is a smaller burden in practice.

### 2. Add `make test` as the canonical test aggregator

```
make test       Run the full test pipeline: validate, then build,
                then scan. Equivalent to today's `make all`. Same
                tiering, same privilege requirements, same container.
                CI invokes this target; developers invoke this target.
```

`make all` is retained as an alias for backwards compatibility, but `make test` is the documented target. The name parallels `make validate`: both ask "is the project in a good state?", at two different scopes.

### 3. Decide whether to rename `make build` and `make scan`

These two targets are *tests of* the build and scan pipelines, not artefact-producing flows. The current names suggest the opposite. Options:

a. **Keep the names.** Cheapest. The CONTRIBUTING / README references stay valid. The naming inversion remains but is now documented explicitly in CONTRIBUTING ("these are test targets; see the operational paths section for real deliverables").

b. **Rename to `make test-build` and `make test-scan`.** Most honest. Imposes a one-time cost of updating CONTRIBUTING.md, README.md, .github/workflows/, and the developer's muscle memory. Opens up `make build` as a future target name for an actual artefact-producing flow.

c. **Subsume them as sub-targets of `make test`** (`make test build`, `make test scan`). More elegant in principle but introduces argument-handling complexity in the Makefile that does not pay back.

The recommendation in the implementation outline below is (b), the rename. Rationale: this work is a vocabulary cleanup; tolerating one obviously-wrong name as a cost-saving measure undermines the cleanup. The cost of the rename is hours, not days, and it is paid once.

### 4. Introduce `make update` and `make usb` for the operational paths

The operational refresh and USB-writing flows live entirely in `scripts/`, with `make` having nothing to say about them. This is consistent ("`make` is for testing and image management") but unhelpful for a developer who needs to do the operational work and is reaching for `make` first by habit.

```
make update     Run scripts/run-update.sh inside the troskel-build
                container. Refreshes ClamAV signatures and YARA rules,
                rebuilds the scanner image, regenerates the SBOM and
                the per-build manifest. Equivalent to today's
                operational refresh path, now reachable from make.

make usb        Host-side wrapper for prepare-data-usb.sh and
                prepare-boot-usb.sh. NOT containerised — writes to
                physical /dev/sdN devices that the container does
                not have native access to. The script does the
                device-selection prompt; make usb only wraps the
                privileges-and-path setup.
```

`make usb` is the one target that genuinely cannot be containerised. The Makefile documents this. A developer reading the target list sees the contrast: every other target runs in the container, this one runs on the host.

### 5. Document the Linux-only constraint

The README's "Requirements" section gains an explicit line: "Linux required. Docker Desktop on macOS and Windows is not a supported environment; specifically, /dev/kvm passthrough required for `make scan` is not available outside Linux." CONTRIBUTING.md mirrors this. The constraint is not invented here — it is a property of the existing pipeline — but it has never been stated.

The choice to be Linux-only is not arbitrary: the scanning host is itself Linux-only (CoreOS), the build station produces Linux binaries and Linux filesystems, and KVM passthrough is a Linux kernel facility. Supporting macOS/Windows builds would require either a remote-Linux-VM workflow (substantial complexity) or accepting that some `make` targets simply do not work on those platforms (worse than honestly declaring Linux-only). The honest declaration is the right answer.

## Implementation outline

Five ordered steps, each landable as a separate PR if desired:

1. **Add the container sentinel.** Dockerfile creates `/.troskel-container` (an empty file). `tests/test-build.sh` and `tests/test-scan.sh` gain an early check that this file exists, with a clear error message pointing the developer at `make test-build` / `make test-scan`. This is the first change because subsequent changes assume the gate is in place. One small PR.

2. **Rename `make build` → `make test-build`, `make scan` → `make test-scan`; add `make test`.** Touch the Makefile, update CONTRIBUTING.md and README.md, update .github/workflows/. Keep `make build` and `make scan` as aliases that print a deprecation notice and call the renamed target — one release of warnings before removal. One PR.

3. **Add `make update`.** Trivial Makefile target that runs `scripts/run-update.sh` inside the container with the same volume mounts as `make test-build`. Document it in CONTRIBUTING.md alongside the existing build/test targets. One PR.

4. **Add `make usb`.** Slightly more involved — needs to be a host-side wrapper that invokes `scripts/prepare-data-usb.sh` and offers the prepare-boot-usb.sh path. The Makefile target documents the host-direct execution and the device-selection prompt. One PR.

5. **Document Linux-only.** README "Requirements" section and CONTRIBUTING introduction both gain the explicit statement. The roadmap items (`output-usb.md`, `parallel-engines.md`, `capa-third-engine.md`) inherit the constraint without restating it. One PR (docs-only).

The five PRs together close the task. They could land in this order or be combined into fewer PRs if review bandwidth permits; the sequence is a constraint on dependencies (step 1 must precede step 2) rather than a hard schedule.

## Side effects on existing scripts

- **`scripts/prepare-build-machine.sh`** becomes documentation rather than required runtime. A developer setting up Troskel from scratch no longer needs to run it on the host — `make image` builds the container, which contains everything. The script remains in the repo as a reference for what the container installs, and as a fallback for developers who genuinely want a host-direct build (a small audience, but the script is small and there is no cost to keeping it).

- **The `--clean` flag on `tests/test-build.sh`** continues to work the same way inside the container, clearing `/var/lib/troskel/` (which is the named volume). `make test-build --` does not pass arguments through; the Makefile target accepts a `CLEAN=1` environment variable instead: `make test-build CLEAN=1`.

- **The host-direct freshclam patch (`DatabaseOwner root`)** remains correct and is not reverted. Inside the container, the `clamav` user exists from the Debian postinst, so the patch is a no-op there. Outside the container, the patch is what makes `scripts/download-clamav-signatures.sh` portable to non-Debian hosts — even though the new policy is "don't invoke this script outside the container", the script's own portability is a property worth preserving for the developer who genuinely needs the fast-iteration path with a direct script invocation.

## Estimated effort

Two and a half developer-days total, distributed roughly:

- Step 1 (container sentinel + gate): half a day.
- Step 2 (rename + Makefile + docs): a full day, mostly in updating documentation and CI workflow files.
- Step 3 (`make update`): one to two hours.
- Step 4 (`make usb`): half a day.
- Step 5 (Linux-only documentation): one to two hours.

The largest single piece is the rename, not because the rename itself is hard but because every place that currently says `make build` or `make scan` needs to be updated and the updated references then need to be checked. Grep-then-review work.

## Sequencing

Independent of every other roadmap item. Does not block `1.0.0` semantically — the build pipeline works as-is — but it is the right kind of cleanup to do *before* a `1.0.0` release rather than after, because `1.0.0` is the version where someone other than the current developer might try to build the project for the first time. A new contributor's first impression of the build system is set by what the README and CONTRIBUTING.md say to do; rationalising the vocabulary before the version that invites new contributors is better timing than rationalising it after.

Target `1.0.0`. Land before tagging.

## Open questions

- **Should `make build` and `make scan` truly be renamed, or kept as aliases indefinitely?** The implementation outline recommends rename-with-deprecated-aliases, removed in a subsequent release. A simpler alternative is to keep the aliases forever — `make build` runs `make test-build`, end of story. The deprecation path imposes a transition cost for very small clarity gain after the first release; possibly not worth it.

- **What should `make image` rebuild trigger on?** Currently `make image` rebuilds the Docker image when `Dockerfile` or `versions.env` change. After rationalisation, should bumping a version in `versions.env` automatically rebuild the image when `make test` runs, or should the developer have to run `make image` explicitly? Auto-rebuild matches developer expectations ("I bumped a version and ran the tests, of course the image picks it up"); manual matches Docker's usual idiom ("you rebuild images deliberately, you do not let test runs surprise you with a five-minute container rebuild"). Worth a real decision before implementing step 2.

- **Should `tests/test-validate.sh` also gate on the container sentinel?** Today validate runs in the container but does not technically *need* to — it is shellcheck plus butane, both of which are cheap host-side tools when available. The argument for gating is "consistency, all test paths go through the container". The argument against is "validate is the one path that genuinely benefits from being runnable host-side for editor-integration speed (`make validate` on file save)". Lean toward not gating, but worth thinking about.

- **Should the deprecation warnings on `make build` / `make scan` be removed at `1.0.0` or later?** Removing them at `1.0.0` matches the "clean slate for new contributors" framing but breaks any tooling pinned to the old names. Keeping them through `1.0.0` and removing at `1.1.0` is the conservative path. No external tooling is known to pin the names today, so the conservative path costs little.

- **Does `make usb` belong in this work at all, or is it a separate task?** It is the one target that genuinely cannot be containerised, and including it here means the rationalised vocabulary covers every operational flow. Excluding it means this task is purely about the test-side cleanup, and USB-writing remains script-direct. The implementation outline includes it; the alternative is to split it into its own follow-up roadmap item ("operational paths in make").