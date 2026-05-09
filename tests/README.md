# Testing

Tests run against a Debian or Ubuntu dev host directly. There is no test container, the build machine and the dev host are the same OS family, so running the project scripts in place gives the closest possible parity to production behaviour on the build station.

If you don't have Debian or Ubuntu, use a VM. macOS and Windows hosts cannot run these tests directly because the underlying tooling (`debootstrap`, `mkfs.ext4`, KVM) is Linux-only.

## What you can test

| Script                          | Works without KVM? | Notes                                                                                              |
|---------------------------------|--------------------|----------------------------------------------------------------------------------------------------|
| `download-latest-signatures.sh` | yes                | Full run.                                                                                          |
| `download-yara-rules.sh`        | yes                | Full run. Invokes `loki-util update`.                                                              |
| `download-kernel.sh`            | yes                | Full run.                                                                                          |
| `build-scanner-image.sh`        | yes                | Builds the rootfs (includes LOKI-RS and YARA Forge rules); doesn't boot it without KVM.            |
| `prepare-liveos-usb.sh`         | partial            | Validates Butane, builds the ISO. The `dd` to USB needs a real device.                             |
| `prepare-data-usb.sh`           | no                 | Needs a real USB. Safety checks can be poked at by passing bad args.                               |
| `check-system-ready.sh`         | partial            | KVM and `zincati` checks may fail on a dev host that isn't a real scanning host — that's expected. |
| `run-scan` (end-to-end)         | KVM only           | Extracted from the Butane config and run against `tests/files/EICAR.txt`; expect the red verdict.  |

## About KVM

KVM is the Linux kernel's virtualisation interface needed by Firecracker to run a real guest VM.

```bash
ls -l /dev/kvm
```

Exists and root has rw? Then you're set. If it's missing, enable VT-x / AMD-V in the BIOS. Linux VMs on macOS or Windows hosts won't have it unless nested virtualisation is on.

## What needs real hardware

These cannot be exercised on a dev host at all:

- CoreOS booting from the boot USB
- Ignition applying (`scanner` user, `load-scanner.service`, `zincati` masked)
- The hardware write blocker on the file USB
- `prepare-data-usb.sh` and the `dd` step in `prepare-boot-usb.sh`

## Requirements

Debian or Ubuntu host with `prepare-build-machine.sh` already run:

```bash
sudo bash scripts/prepare-build-machine.sh
```

That installs everything the tests need: debootstrap, butane, firecracker, LOKI-RS, a container runtime, and the rest. The tests will refuse to run if any of these are missing.

The build artefacts live under `/var/lib/troskel/`. Repeated runs accumulate state; pass `--clean` to `test-build.sh` to discard prior artefacts before rebuilding.

## Test usage

End-to-end build pipeline:

```bash
sudo bash tests/test-build.sh
sudo bash tests/test-build.sh --clean    # rebuild from scratch
```

End-to-end scan pipeline (needs `/dev/kvm`):

```bash
sudo bash tests/test-scan.sh
```

Three scans, each isolating one path of the verdict pipeline: red via ClamAV (using EICAR), red via LOKI-RS, and green (using a clean directory). Separating the red paths means a failure tells you which engine is broken without log archaeology.

Manual checks for cases the automated tests don't cover (yellow path, cleanup trap, resource exhaustion, read-only enforcement):

`tests/manual-tests-scan.md`

## Reading scan logs

The guest entrypoint emits one `ENGINE:` line per engine alongside the final `VERDICT:` line, e.g.:

```
[14:30:22] ENGINE: clamav status=threat exit=1 count=1
[14:30:48] ENGINE: loki status=clean exit=0 count=0
[14:30:48] VERDICT: THREAT DETECTED
```

The host wrapper parses these into the per-engine breakdown shown under the verdict block. When debugging a yellow verdict, the `ENGINE:` lines are the first thing to look at — they distinguish "engine errored" from "engine ran clean but the other one didn't emit a result". For details on what was flagged, grep the log directly:

```bash
grep -E 'FOUND$|"level":"ALERT"' /var/log/troskel/scan-*.log
```

ClamAV's `FOUND` lines and LOKI-RS's JSONL ALERT records are the authoritative finding details; the ENGINE lines only carry counts.