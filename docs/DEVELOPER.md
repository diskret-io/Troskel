# Developer guide

How the build pipeline works, how to run the tests, and how to iterate on individual scripts.

For project-contribution conventions (git workflow, commit message format), see [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

## Prerequisites

Linux with Docker installed. See the [Requirements section in the README](../README.md#requirements) for the constraint and its reasoning.

On a fresh clone, run:

```bash
sudo bash scripts/prepare-build-machine.sh
```

This installs the host-side Docker dependencies and the EFF wordlist needed for passphrase generation. After that, all build and test work happens through `make`.

## The three commands

```bash
make validate    # Static checks: butane + shellcheck. ~30 seconds.
make test        # Full test suite: validate, then build, then scan. ~20 minutes.
make update      # Refresh signatures and rebuild image. Operational refresh path.
```

These three cover day-to-day work.

`make validate` is the pre-commit check. It catches Butane config errors, shellcheck warnings, and POSIX sh bashisms in the guest scripts. No privileges, no network, no KVM.

`make test` is what CI runs on every PR. It exercises the full pipeline end-to-end. Needs `--privileged` (for debootstrap and mkfs.ext4) and `/dev/kvm` (for Firecracker). About 20 minutes from a clean state.

`make update` is the operational refresh path. Same underlying pipeline as the build half of `make test`, without the negative-path verification tests. The admin's `troskel-build.sh` delegates to this; running it directly outside that script is the equivalent of running an admin-style refresh from a developer machine.

## The containerised pipeline

All `make` targets run inside the `troskel-build` container. The host needs only Docker; the container provides Debian with debootstrap, butane, firecracker, shellcheck, ClamAV (including `sigtool` and `freshclam`), unzip, and the LOKI-RS binary pre-installed.

The container is rebuilt automatically whenever `Dockerfile` or `config/versions.env` change. Bumping a pinned version in `versions.env` picks up the next time any `make` target runs; no need to invoke `make image` explicitly.

Build artefacts (scanner rootfs, signatures, kernel) persist in a named Docker volume called `troskel-artefacts`, mounted at `/var/lib/troskel` inside the container. This means `make test-scan` can consume what `make test-build` produced without rebuilding, and running `make test` twice does not redo the debootstrap step the second time unless something invalidated the artefacts.

Host-direct invocation of test scripts (running `bash tests/test-build.sh` outside the container) is gated off. The scripts check for a `/.troskel-container` sentinel file that only exists inside the image and refuse to run on the host. The historical host-direct path accumulated environment-dependent bugs (the `clamav` user being absent on NixOS, chown semantics under sudo, sigtool version drift) that the containerised pipeline avoids by construction.

## Running individual tiers

`make test` runs three tiers in sequence. When iterating on a single tier, skip the others.

```bash
make test-build  # Tier 2 only: full build pipeline (~15 min). Needs --privileged.
make test-scan   # Tier 3 only: Firecracker scan tests (~5 min). Needs /dev/kvm.
```

`make test-scan` consumes what `make test-build` produced, so rerun the scan against an existing build without rebuilding.

CI uses these individually rather than `make test` so the cheap Tier 1 fails fast on PRs without paying for a Tier 2 run that would also fail. CI configuration is in `.github/workflows/`.

### What each tier covers

**Tier 1, `make validate`:**

1. Butane config compiles cleanly (with a dummy `@@SCANNER_PASSWORD_HASH@@` substitution so `butane --strict` does not reject the sentinel).
2. shellcheck passes on every shell script in the project at warning severity.
3. The guest entrypoint (`guest/run-scan.sh`) is POSIX sh compatible. `checkbashisms` is used if available, with a lighter heuristic as fallback.

**Tier 2, `make test-build`:**

1. Negative-path tests for SHA-256 verification. Deliberately corrupts `LOKI_SHA256` and `KERNEL_SHA256` in `versions.env`, confirms the affected download script exits non-zero with the expected mismatch text, restores the recorded values via an EXIT trap.
2. Butane config validation against the real `config/scanner-host.bu`.
3. ClamAV signature download via `freshclam`.
4. YARA Forge Core rules refresh.
5. Guest kernel download (with the record-at-first-download verification path).
6. Scanner image build: debootstrap, ClamAV install, LOKI-RS install, signature injection, ext4 image.

The `tests/test-build.sh` script accepts a `--clean` flag to clear prior artefacts first. The Makefile does not currently forward arguments through, so passing `--clean` from `make test-build` requires invoking the container directly via the fast-iteration pattern below.

**Tier 3, `make test-scan`:**

Two end-to-end scans against the rootfs produced by Tier 2:

- **Red.** Scans `tests/files/EICAR.txt` plus a known encrypted ZIP. Expects a `THREAT DETECTED` verdict with both ClamAV and LOKI-RS reporting `status=threat`, and confirms the ClamAV `--alert-encrypted-archive` flag fired against the encrypted ZIP.
- **Green.** Scans a directory containing one benign text file. Expects a `CLEAN` verdict.

The test fixtures are committed base64-encoded so developer AV scanners do not flag the repo. See [tests README](../tests/files/README.md) for the fixtures and regeneration recipes.

## About KVM

KVM is the Linux kernel's virtualisation interface needed by Firecracker to run a real guest VM. Check it's available:

```bash
ls -l /dev/kvm
```

Exists and root has read/write? Then `make test-scan` will work. If it is missing, enable VT-x (Intel) or AMD-V (AMD) in the BIOS. Linux VMs on macOS or Windows hosts do not have it unless nested virtualisation is configured; Troskel is Linux-only by design.

## `make update` vs `make test-build`

The two share most of their underlying scripts but are invoked for different reasons:

- **`make test-build`** runs the negative-path verification tests (deliberate SHA-256 mismatches to confirm the verification path fails closed) before running the real pipeline. CI invokes it on every PR.
- **`make update`** runs `scripts/run-update.sh` directly: download, rebuild, regenerate SBOM and manifest. No negative-path tests. The admin's interactive entry point (`scripts/troskel-build.sh`) delegates to this; one canonical refresh path.

In CI, `make test-build` is the right target. Outside CI, anywhere fresh artefacts are wanted (admin preparing a session, developer reproducing an issue), `make update` is the right one.

## Fast-iteration loop on a single script

For iterating on a single script (e.g. debugging `download-loki-yara-rules.sh`), invoke the container directly rather than running `make`:

```bash
docker run --rm --privileged \
    --volume "$PWD:/troskel" --workdir /troskel \
    troskel-build bash scripts/download-loki-yara-rules.sh
```

Container start is a few seconds. The bind-mount means edits in the host repo are immediately visible to the script, no rebuild needed.

This pattern also works for invoking the test scripts with arguments the Makefile does not forward, for example `bash tests/test-build.sh --clean`.

`tests/test-validate.sh` is not gated on the container sentinel and can be run directly on the host if `butane` and `shellcheck` are available locally. Useful for editor integration where a few-second container start would be noticeable.

## What cannot be tested in CI

Some flows cannot be exercised by an automated test:

- CoreOS booting from the boot USB (requires real hardware).
- Ignition applying (`scanner` user creation, `load-scanner.service`, `zincati` masked).
- The hardware write blocker on the file USB.
- `prepare-data-usb.sh` and the `dd` step in `prepare-boot-usb.sh` (require real USB devices).

Manual procedures for these and other edge cases (yellow verdicts, resource exhaustion, read-only enforcement) are documented in [`../tests/manual-tests-scan.md`](../tests/manual-tests-scan.md).

## Reading scan logs

The guest entrypoint emits one `ENGINE:` line per engine alongside the final `VERDICT:` line, for example:

```
[14:30:22] ENGINE: clamav status=threat exit=1 count=1
[14:30:48] ENGINE: loki status=clean exit=0 count=0
[14:30:48] VERDICT: THREAT DETECTED
```

The host wrapper parses these into the per-engine breakdown shown under the verdict block. When debugging a yellow verdict, the `ENGINE:` lines are the first thing to look at; they distinguish "engine errored" from "engine ran clean but the other one did not emit a result". For details on what was flagged, grep the log directly:

```bash
grep -E 'FOUND$|"level":"ALERT"' /var/log/troskel/scan-*.log
```

ClamAV's `FOUND` lines and LOKI-RS's JSONL `ALERT` records are the authoritative finding details; the `ENGINE:` lines only carry counts.

## Housekeeping

```bash
make image       # Rebuild the container image (auto-runs as a dependency).
make clean       # Remove the image and the artefact volume.
```

`make image` runs automatically as a dependency of every other target; invoke explicitly only when something seems stale. It rebuilds when `Dockerfile` or `config/versions.env` change.

`make clean` is for starting over: removes both the container image and the named volume holding build artefacts. Useful for diagnosing volume-corruption issues; rarely needed otherwise.

## Deprecated aliases

`make build`, `make scan`, and `make all` continue to work as aliases for `make test-build`, `make test-scan`, and `make test`, with a deprecation warning printed before they run. They will be removed in a future release.

## Project layout

```
config/                  Scanning-host configuration and version pins
guest/                   Inside-the-microVM scripts (run-scan.sh, inittab)
scripts/                 Build station scripts
tests/                   Test pipeline (this guide is the canonical reference)
docs/                    Documentation: this file, ADMIN.md, OPERATOR-GUIDE.md,
                         architecture.md, roadmap/
Dockerfile               Defines the troskel-build container
Makefile                 Wraps container invocations
```

See [`architecture.md`](architecture.md) for the design rationale and [`../SECURITY.md`](../SECURITY.md) for the threat model.