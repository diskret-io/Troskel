# Testing

Tests run inside a container using the `troskel-build` image, which provides all required tooling (Firecracker, Butane, LOKI-RS, debootstrap, etc.) regardless of what the host OS is. The container works with Podman or Docker interchangeably; Podman is preferred and is the default on Fedora and openSUSE.

The `Makefile` at the project root wraps all container invocations so you do not need to remember flags.

## Prerequisites

Docker is required. Install it for your distribution:

| Distribution    | Command                                                       |
|-----------------|---------------------------------------------------------------|
| Fedora          | see https://docs.docker.com/engine/install/fedora/            |
| openSUSE        | see https://docs.docker.com/engine/install/                   |
| Debian / Ubuntu | `sudo apt-get install docker.io`                              |
| NixOS           | `virtualisation.docker.enable = true;` in `configuration.nix` |

Verify with: `docker run --rm hello-world`

## Test tiers

Tests are split into three tiers by their resource requirements.

| Tier | Make target     | Privileges     | KVM | Time    | What it covers                                 |
|------|-----------------|----------------|-----|---------|------------------------------------------------|
| 1    | `make validate` | none           | no  | < 1 min | Butane config, shellcheck, POSIX sh compliance |
| 2    | `make build`    | `--privileged` | no  | ~15 min | Signature download, debootstrap, image build   |
| 3    | `make scan`     | `--privileged` | yes | ~5 min  | Firecracker boot, EICAR red path, green path   |

Run all three in sequence with `make all`.

## Tier 1 — validate

```bash
make image      # first time only; rebuilds if Dockerfile or versions.env changed
make validate
```

No internet access or special privileges required. Covers:
- `config/scanner-host.bu` compiles with Butane without error
- All shell scripts in the project pass `shellcheck --severity=warning`
- `guest/run-scan.sh` contains no bashisms (requires `checkbashisms` inside the image; falls back to a heuristic if absent)

## Tier 2 — build

```bash
make build
```

Needs `--privileged` for `debootstrap` and `mkfs.ext4` inside the container. Needs internet access to download ClamAV signatures, YARA Forge Core rules, and the guest kernel. Covers:
- `scripts/download-clamav-signatures.sh`
- `scripts/download-loki-yara-rules.sh`
- `scripts/download-kernel.sh`
- `scripts/build-scanner-image.sh` (full debootstrap, ClamAV + LOKI-RS install, image creation and verification)

On some distributions `--privileged` requires `sudo`:

```bash
sudo make build
```

## Tier 3 — scan

KVM must be available on the host (`ls -la /dev/kvm`). If `/dev/kvm` does not exist, enable VT-x (Intel) or AMD-V (AMD) in BIOS and reboot.

```bash
make scan
```

Boots a real Firecracker microVM, runs both ClamAV and LOKI-RS against the EICAR test file and a clean directory, and asserts the correct verdict and per-engine status lines in both cases. The EICAR file lives at `tests/files/EICAR.txt`.

## Interactive debugging

Drop into the container with a shell to investigate failures:

```bash
docker run --rm -it --privileged --device /dev/kvm \
    --volume "$(pwd):/troskel" --workdir /troskel \
    troskel-build bash
```

From inside, run individual test scripts directly:

```bash
bash tests/test-validate.sh
bash tests/test-build.sh --clean
bash tests/test-scan.sh
```

## Manual tests

Yellow-path, cleanup trap, read-only enforcement, and resource exhaustion tests are not automated. See `tests/manual-tests-scan.md` for procedure. Run these by hand after any change to `config/host-scripts/scan-wrap`, `guest/run-scan.sh`, or the Firecracker JSON template.

## CI

All three tiers run automatically on GitHub Actions. Tier 1 and 2 run on every push and pull request. Tier 3 runs on pushes to `main` only (KVM availability on PR runners is not guaranteed). See `.github/workflows/ci.yml`.