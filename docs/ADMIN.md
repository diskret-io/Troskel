# Admin guide

The admin prepares the two USBs that the operator uses on the scanning host. One command on the build station handles the full session-preparation cycle.

## Quick start

On the build station, insert both USB sticks and run:

```bash
sudo bash scripts/troskel-build.sh
```

`troskel-build.sh` guides through the full process interactively:

- Detects connected USB devices and asks for role assignment.
- Downloads fresh ClamAV signatures and YARA rules.
- Builds the scanner image.
- Writes both USB sticks and verifies checksums.
- Displays the scanning host passphrase prominently at the end.

The passphrase is not stored anywhere. Record it on the boot USB label or in a password manager before continuing.

## Command reference

```bash
sudo bash scripts/troskel-build.sh [OPTIONS]
```

| Flag         | Effect                                                          |
|--------------|-----------------------------------------------------------------|
| `--usb-all`  | Write both boot and data USBs (default).                        |
| `--usb-data` | Write TROSKEL-DATA only. Expects one USB device.                |
| `--usb-boot` | Write TROSKEL-BOOT only. Expects one USB device.                |
| `--update`   | Refresh signatures and rebuild scanner image; skip USB writing. |
| `--debug`    | Stream full output from all sub-steps.                          |

`--update` is the right flag between sessions when the boot USB is still good but signatures have aged. The boot USB only needs rewriting if the underlying CoreOS or the scanner's host-side configuration changes.

## First-time setup

On a fresh build station, install Docker first:

```bash
# See https://docs.docker.com/engine/install/ for your distribution
sudo bash scripts/prepare-build-machine.sh
```

`prepare-build-machine.sh` installs everything else the build pipeline needs. The host needs Docker; the container provides every other tool.

After first-time setup, the regular workflow is `sudo bash scripts/troskel-build.sh`.

## What troskel-build.sh actually does

Six phases, visible in the script output:

1. **Runtime detection** verifies Docker is available.
2. **USB detection** enumerates connected USB block devices and assigns them to roles.
3. **Preflight checks** verify internet connectivity, EFF wordlist presence, and disk space under `/var/lib/troskel`.
4. **Artefact update** delegates to `make update`, which runs the full refresh pipeline inside the troskel-build container.
5. **USB writes** call `prepare-data-usb.sh` and `prepare-boot-usb.sh` on the assigned devices.
6. **Verification** re-mounts the data USB read-only and verifies the SHA-256 checksums on the materialised rootfs.

Each phase prints progress as it runs. With `--debug`, the full output of each sub-step is streamed; otherwise output is suppressed unless a step fails.

## When things fail

The script halts at the first failed phase and prints the failing sub-step's full output. Common failures and what to do about them:

- **Docker not found.** Install Docker and rerun. See [docker.com/engine/install](https://docs.docker.com/engine/install/).
- **No internet access.** The build station needs network connectivity to download signatures, YARA rules, and the guest kernel. Resolve connectivity and rerun.
- **Disk space warning.** The `/var/lib/troskel` directory is where the build container persists artefacts. About 5GB free is sufficient. Free space and rerun.
- **USB detection finds wrong number of devices.** Insert exactly the USBs you intend to write to. Other USB devices, including ones in use as system storage, are excluded from the list, but it is safer to unplug them anyway.
- **`make update` fails inside the container.** Run `make update` directly outside `troskel-build.sh` for a clean view of the container's output. The script wraps `make update` for convenience but does not transform its output; running it directly gives the same information without the wrapper.
- **TROSKEL-DATA checksum verification fails.** Do not use the USB. The data was written incorrectly. Rewrite via `--usb-data`.

For deeper diagnostics or to investigate a recurring failure, run with `--debug` and capture the full output.

## Routine maintenance

Between sessions, refresh the data USB to keep signatures current:

```bash
sudo bash scripts/troskel-build.sh --usb-data
```

The boot USB rarely needs rewriting. Rewrite it only when:

- The scanner's host-side configuration changes (`config/scanner-host.bu` or anything under `config/host-scripts/`).
- The pinned CoreOS version in `config/versions.env` is bumped.
- The scanning host passphrase needs to change. A new boot USB will print a fresh passphrase.

The signature freshness gate is configured in `config/scanner.env` (`SIG_AGE_DAYS`, `YARA_AGE_DAYS`). When a data USB ages past the gate, `check-system-ready` on the scanning host will reject it; that is the operator's signal that a fresh data USB is needed.