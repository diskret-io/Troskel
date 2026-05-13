# Troskel

[![CI](https://github.com/diskret-io/Troskel/actions/workflows/ci.yml/badge.svg)](https://github.com/diskret-io/Troskel/actions/workflows/ci.yml)
[![Upstream canary](https://github.com/diskret-io/Troskel/actions/workflows/upstream-canary.yml/badge.svg)](https://github.com/diskret-io/Troskel/actions/workflows/upstream-canary.yml)
![license](https://img.shields.io/badge/license-MIT-blue?style=flat)

## Air-gapped file transfer scanner

Static scan of files for known malware before they cross into an air-gapped environment.

Troskel uses multiple engines, currently [ClamAV](https://www.clamav.net/) and [LOKI-RS](https://github.com/Neo23x0/Loki-RS), with independent detection logic. Both engines run inside an isolated [Firecracker](https://firecracker-microvm.github.io) microVM on a live OS built on [CoreOS](https://fedoraproject.org/coreos). The guest runs in RAM only and leaves no persistent state between sessions.

## Requirements

**Linux required.** Both the build station and the scanning host run Linux. macOS and Windows are not supported.

The build station needs Docker, and the scan tests need access to `/dev/kvm` for Firecracker. `/dev/kvm` is a Linux kernel facility; Docker Desktop on macOS and Windows runs containers inside its own Linux VM and does not expose host-level KVM, so `make test-scan` cannot work outside Linux even with Docker installed. The scanning host is itself Linux-only (CoreOS), and the artefacts the build station produces (Linux binaries, ext4 filesystems, Ignition configs) only make sense on a Linux target.

There is no plan to support cross-platform builds. Use a Linux VM if you need to develop on macOS or Windows.

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

Three roles, three docs:

- **Operator** scans files on the air-gapped scanning host. See the operator workflow below; for troubleshooting see [`docs/OPERATOR-GUIDE.md`](docs/OPERATOR-GUIDE.md).
- **Admin** prepares USBs on the build station before each scan session. See [`docs/ADMIN.md`](docs/ADMIN.md).
- **Developer** changes the project's code. See [`docs/DEVELOPER.md`](docs/DEVELOPER.md).

---

## Operator workflow

1. **Prepare the file USB** on any networked machine. Copy the files you want to transfer onto a standard USB drive (FAT32, ext4, or exFAT).
2. **Insert the TROSKEL-BOOT and TROSKEL-DATA USBs** into the scanning host and power on. Leave the file USB out for now.
3. **Log in** as the `scanner` user with the passphrase from the admin.
4. **Check the system is ready:**
   ```
   show-status
   check-system-ready
   ```
5. **Insert the file USB**, then run the scan:
   ```
   troskel
   ```
   The verdict will be **GREEN**, **RED**, or **YELLOW** with a per-engine breakdown. Do not remove any USB during the scan.

   If the verdict is not GREEN, or `check-system-ready` reports a problem, see [`docs/OPERATOR-GUIDE.md`](docs/OPERATOR-GUIDE.md).

6. **Power off** when finished:
   ```
   sudo poweroff
   ```

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

scripts/                 Build station scripts (see docs/ADMIN.md, docs/DEVELOPER.md)
  troskel-build.sh       Guided admin workflow entry point
  prepare-build-machine.sh  One-time build station setup
  run-update.sh          Refresh signatures and rebuild scanner image
  prepare-data-usb.sh    Write TROSKEL-DATA USB
  prepare-boot-usb.sh    Write TROSKEL-BOOT USB
  build-scanner-image.sh Build Debian guest rootfs with ClamAV + LOKI-RS
  generate-build-records.sh  Produce SBOM.json and per-build manifest
  download-*.sh          Individual download scripts

tests/                   Test pipeline (see docs/DEVELOPER.md)

docs/
  ADMIN.md               Admin guide
  DEVELOPER.md           Developer guide
  ARCHITECTURE.md        Design rationale with diagrams
  SECURITY.md            Security model and residual risks
  OPERATOR-GUIDE.md      Operator troubleshooting reference
  roadmap/               Planned work
```

---

## Roadmap

Planned work is tracked in [`docs/roadmap/`](docs/roadmap/). Each document carries its own scope, sequencing, and target-version note. Looser-form ideas live in [`docs/roadmap/IDEAS.md`](docs/roadmap/IDEAS.md).

---

## Security model

The security guarantee is: files that reach the air-gapped environment have been scanned by two independent engines running in a hardware-virtualised microVM with no network access, against signatures updated before each session.

**Green** means no engine matched any known signature. It does not mean guaranteed clean: novel malware with no signature will not be detected. This is the inherent limitation of signature-based scanning.

See [`docs/SECURITY.md`](docs/SECURITY.md) for the full threat model, residual risks, and design rationale.