# Contributing

## Git workflow

### Branches

`main` is the only long-lived branch. Work on anything non-trivial in a short-lived feature branch, then merge back via a pull request, even if you are the sole reviewer. This keeps the history readable and gives you a natural review checkpoint before code lands.

```bash
git checkout -b feat/parallel-engines
# do the work
git checkout main
git merge --no-ff feat/parallel-engines -m "feat: add parallel engine VM architecture"
git branch -d feat/parallel-engines
```

The `--no-ff` flag preserves a merge commit so the history shows that a body of related work landed together, rather than a flat stream of individual commits.

### Commit messages

Use a short type prefix. The full conventional commits spec is not enforced, but keeping the type consistent makes the log scannable.

```
feat: add capa as a third scan engine
fix: pass ext4 image directly to Firecracker, remove losetup
docs: update README admin workflow for troskel-build.sh
chore: rename SCANNER-DATA label to TROSKEL-DATA
refactor: extract guest scripts from build-scanner-image.sh heredocs
test: add POSIX sh compliance check to test-validate.sh
```

Useful types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`. Nothing else needed.

The subject line should complete the sentence "this commit will...". Keep it under 72 characters. If more context is needed, leave a blank line after the subject and write a body.

### Tags

Tag meaningful milestones — not every merge, but points worth being able to return to.

```bash
git tag -a v0.2.0 -m "feat: parallel engine VM architecture"
git push origin v0.2.0
```

Use `v0.x.y` until the project is stable enough to call `v1.0.0`. A tag is a checkpoint, not a formal release — it does not need release notes at this stage.

### Before committing

Run `make validate` first. It catches Butane config errors, shellcheck failures, and guest script bashisms in under 30 seconds. If it passes, the commit is unlikely to break CI.

```bash
make validate
git add .
git diff --staged --stat   # review what is actually staged
git commit
```

The `git diff --staged --stat` step is worth making a habit, it is the last chance to catch an accidentally staged file before it enters the history.

### What not to commit

The `.gitignore` covers the main cases. As an extra reminder:

- `config/eff-large-wordlist.txt` — downloaded at setup time, not stored in the repo
- Any real `ignition.json` — compiled output, regenerated from source
- Build artefacts under `/var/lib/troskel/`
- Scan logs under `/var/log/troskel/`
- Any file containing a real password hash, key, or credential

## Running the tests and refreshing artefacts

**Linux required.** The build pipeline needs `/dev/kvm` for the scan tests, which is a Linux kernel facility and is not available on macOS or Windows even via Docker Desktop. See the [Requirements section in the README](README.md#requirements) for the full explanation.

All `make` targets run inside the `troskel-build` container. The host needs only Docker installed; the container provides Debian-the-build-station with every tool already in place. See [`docs/roadmap/build-system-rationalisation.md`](docs/roadmap/build-system-rationalisation.md) for the rationale.

```bash
make image       # build (or refresh) the container image
make validate    # static validation: butane + shellcheck. Fast (~30s).
make test-build  # full build pipeline. Slower (~15 min); needs --privileged.
make test-scan   # Firecracker scan tests. Needs /dev/kvm + --privileged.
make test        # validate + test-build + test-scan in sequence.
make update      # refresh signatures, rebuild image, regenerate SBOM
                 # and per-build manifest. Operational counterpart to
                 # test-build.
make clean       # remove the image and the artefact volume.
```

`make image` rebuilds the container whenever `Dockerfile` or `config/versions.env` change, so a version bump in `versions.env` picks up automatically the next time you run any target.

The Tier 2 and Tier 3 targets, and `make update`, persist build artefacts (scanner rootfs, signatures, kernel) in a named Docker volume (`troskel-artefacts`) so the artefacts produced by one invocation are visible to subsequent invocations. `make clean` removes both the image and the volume.

### `make update` vs `make test-build`

The two targets share most of their underlying scripts but are invoked for different reasons:

- **`make test-build`** is the test-target version. It runs the negative-path verification tests (deliberate SHA-256 mismatches to confirm the verification path fails closed) before running the real pipeline. CI invokes it on every push to `main`. A developer verifying a change to a download script invokes it too.

- **`make update`** is the operational version. It runs `scripts/run-update.sh` directly: download the latest signatures, refresh the YARA rules, rebuild the scanner image, regenerate the SBOM and per-build manifest. No negative-path tests. An admin preparing a real scanning session invokes this rather than `make test-build` because the test framing is irrelevant to the refresh — they want fresh artefacts, not a verification that the pipeline still works.

In CI, `make test-build` is the right target. For an admin running the refresh outside of `scripts/troskel-build.sh`, `make update` is the right one. The two coexist; neither replaces the other. `scripts/troskel-build.sh` (the admin's interactive entry point) currently invokes `scripts/run-update.sh` directly; switching it to `make update` is a small follow-up.

### Deprecated aliases

`make build`, `make scan`, and `make all` continue to work as aliases for `make test-build`, `make test-scan`, and `make test`, with a deprecation warning printed before they run. They will be removed in a future release.

### Fast-iteration loop on a single script

The standard `make` targets run the full pipeline. For iterating on a single script (e.g. debugging `download-loki-yara-rules.sh`), invoke the container directly:

```bash
docker run --rm --privileged \
    --volume "$PWD:/troskel" --workdir /troskel \
    troskel-build bash scripts/download-loki-yara-rules.sh
```

Container start is a few seconds. The bind-mount means your edits in the host repo are immediately visible to the script inside the container — no rebuild needed.

Direct host invocation of `tests/test-build.sh` or `tests/test-scan.sh` is not supported: the scripts gate on a container sentinel and refuse to run on the host. The historical host-direct path accumulated environment-dependent bugs that the containerised pipeline avoids by construction.