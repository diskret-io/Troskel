# Troskel

[![CI](https://github.com/diskret-io/Troskel/actions/workflows/ci.yml/badge.svg)](https://github.com/diskret-io/Troskel/actions/workflows/ci.yml)
[![Upstream canary](https://github.com/diskret-io/Troskel/actions/workflows/upstream-canary.yml/badge.svg)](https://github.com/diskret-io/Troskel/actions/workflows/upstream-canary.yml)

## Air-gapped file transfer scanner

Static scan of files for known malware before they cross into an air-gapped environment.

Troskel uses multiple engines — currently [ClamAV](https://www.clamav.net/) and [LOKI-RS](https://github.com/Neo23x0/Loki-RS) — with independent detection logic. Both engines run inside an isolated [Firecracker](https://firecracker-microvm.github.io) microVM on a live OS built on [CoreOS](https://fedoraproject.org/coreos). The guest runs in RAM only and leaves no persistent state between sessions.

## How it works

Two machines, two USBs, three steps.

```
Build station (networked)                 Scanning host (air-gapped)
  │                                       │
  ├─ download signatures + rules          ├─ boot CoreOS into RAM from TROSKEL-BOOT
  ├─ build scanner image                  ├─ load scanner from TROSKEL-DATA into RAM
  └─ write TROSKEL-BOOT + TROSKEL-DATA ──►└─ troskel → GREEN / RED / YELLOW
                                               power off → RAM cleared
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design rationale.

## Roles

- **Admin** — prepares the two USBs on the build station before each scan session.
- **Operator** — transfers files to the scanning host and runs the scan.

---

## Admin workflow

On the build station, insert both USB sticks and run:

```bash
sudo bash scripts/troskel-build.sh
```

`troskel-build.sh` guides you through the full process interactively:
- Detects connected USB devices and asks you to assign roles
- Downloads fresh ClamAV signatures and YARA rules
- Builds the scanner image
- Writes both USB sticks and verifies checksums
- Displays the scanning host passphrase prominently at the end

### Flags

| Flag         | Effect                                                                                                                                                                   |
|--------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--usb-data` | Write TROSKEL-DATA only (one USB needed)                                                                                                                                 |
| `--usb-boot` | Write TROSKEL-BOOT only (one USB needed)                                                                                                                                 |
| `--update`   | Refresh artefacts only, skip USB writing                                                                                                                                 |
| `--debug`    | Show full output from all sub-steps                                                                                                                                      |
| `--host`     | Advanced: bypass Docker and run directly on the host. Requires all build tools installed manually via `prepare-build-machine.sh`. Not the expected path for most admins. |

### First-time setup

On a fresh build station, install Docker first:
```bash
# See https://docs.docker.com/engine/install/ for your distribution
sudo bash scripts/prepare-build-machine.sh
```

`troskel-build.sh` uses Docker automatically. All build tooling runs inside a container — the host needs only Docker installed.

---

## Operator workflow

1. Insert both USB sticks into the scanning host and power on.
2. Log in as the `scanner` user with the passphrase from the admin.
3. Check the system is ready:
   ```
   show-status
   ```
4. Run the scan:
   ```
   troskel
   ```
   The verdict will be **GREEN**, **RED**, or **YELLOW** with a per-engine breakdown.

   If the verdict is not GREEN, or `show-status` reports a problem, see [`docs/OPERATOR-GUIDE.md`](docs/OPERATOR-GUIDE.md).

5. Power off:
   ```
   sudo poweroff
   ```

---

## Developer workflow

The `make` targets run everything inside Docker — the same container image used by the admin workflow. Docker is the only host dependency.

```bash
make image      # build the troskel-build container image (~5 min first time)
make validate   # Tier 1: Butane config + shellcheck (~30 sec, no privileges)
make build      # Tier 2: full image build — debootstrap, signatures (~15 min)
make scan       # Tier 3: Firecracker scan test — needs /dev/kvm (~5 min)
make all        # run all three tiers in sequence
```

Individual scripts under `scripts/` can also be run directly on a Debian host if you have the tools installed — useful when debugging a specific step. See [`tests/README.md`](tests/README.md) for more detail.

---

## Project structure

```
config/
  scanner-host.bu        Butane config for the scanning host (CoreOS Ignition)
  host-scripts/          Scripts deployed to the scanning host via Ignition
    troskel              Operator entry point
    scan-wrap            Firecracker wrapper (internal)
    load-scanner         Loads scanner image from data USB at boot
    show-status          Displays current scanner status
    check-system-ready   Pre-scan readiness checks
  versions.env           Pinned upstream component versions
  scanner.env            Operational tunables (freshness thresholds, VM sizing)

guest/
  run-scan.sh            In-VM scan entrypoint (runs inside Firecracker guest)
  inittab                Busybox init configuration

scripts/                 Build station scripts
  troskel-build.sh       Guided admin workflow entry point
  prepare-build-machine.sh  One-time build station setup
  run-update.sh          Update signatures and rebuild scanner image
  prepare-data-usb.sh    Write TROSKEL-DATA USB
  prepare-boot-usb.sh    Write TROSKEL-BOOT USB
  build-scanner-image.sh Build Debian guest rootfs with ClamAV + LOKI-RS
  download-*.sh          Individual download scripts

tests/
  test-validate.sh       Tier 1: static validation (no privileges)
  test-build.sh          Tier 2: build pipeline
  test-scan.sh           Tier 3: Firecracker scan
  manual-tests-scan.md   Manual test procedures (yellow path, cleanup, etc.)

docs/
  ARCHITECTURE.md        Design rationale with diagrams
  SECURITY.md            Security model and residual risks
  OPERATOR-GUIDE.md      Full operator reference
  roadmap/               Planned work
```

---

## Roadmap

| Item                                                | Status     |
|-----------------------------------------------------|------------|
| Two-engine scan pipeline (ClamAV + LOKI-RS)         | ✅ done     |
| Firecracker microVM isolation                       | ✅ done     |
| CoreOS live-USB scanning host                       | ✅ done     |
| Docker-based build and test workflow                | ✅ done     |
| Guided admin workflow (`troskel-build.sh`)          | ✅ done     |
| Configurable tunables (`config/scanner.env`)        | ✅ done     |
| Upstream canary (daily reachability + weekly build) | ✅ done     |
| YARA rule freshness gate in `check-system-ready`    | 🔜 next    |
| SHA-256 verification of downloaded artefacts        | 🔜 next    |
| ClamAV heuristic and PUA detection tightening       | 🔜 next    |
| capa as a third engine (capability-based detection) | 📋 planned |
| Per-engine Firecracker VMs + parallel execution     | 📋 planned |

---

## Security model

The security guarantee is: files that reach the air-gapped environment have been scanned by two independent engines running in a hardware-virtualised microVM with no network access, against signatures updated before each session.

**Green** means no engine matched any known signature. It does not mean guaranteed clean — novel malware with no signature will not be detected. This is the inherent limitation of signature-based scanning.

See [`docs/SECURITY.md`](docs/SECURITY.md) for the full threat model, residual risks, and design rationale.
