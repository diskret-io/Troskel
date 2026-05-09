# Consolidate scanner tunables into `config/scanner.env`

Several operationally significant values are currently hardcoded across multiple scripts and the Butane config. Admins who need to adjust freshness tolerances, VM sizing, or scan-target capacity must hunt through script internals to do so, and there is no single place to audit what the current policy is. This task moves those values into a new `config/scanner.env`, modelled on the existing `config/versions.env`.

## What is currently hardcoded, and where

**Freshness thresholds** — the maximum age in days before `check-system-ready` fails:
- ClamAV signature age: hardcoded as `30` in the `check-system-ready` script (both the embedded copy in `config/scanner-host.bu` and the standalone copy in `scripts/`).
- YARA rule age: not yet enforced at all (see `yara-freshness-gate.md`), but the threshold will need a home when that task lands.

**Guest VM sizing** — hardcoded in the Firecracker config template inside `run-scan`:
- `vcpu_count: 2`
- `mem_size_mib: 2048`

**Scan-target image size** — hardcoded in two places:
- `SIZE="4G"` in `scripts/build-scanner-image.sh`
- `truncate -s 4G` in the `run-scan` host script

**LOKI-RS per-file size cap** — hardcoded in the guest entrypoint (`guest/run-scan.sh` after extraction, currently the heredoc in `build-scanner-image.sh`):
- `--max-file-size 4294967296` (4 GiB explicit cap, required because `0` means "skip everything" in LOKI-RS — an existing footgun already documented in the source comment)

## Naming convention

Variable names must include the engine or component they govern, so that adding a third engine does not produce ambiguous names like `SIG_MAX_AGE_DAYS` that could refer to any engine's signatures. The convention:

```
<ENGINE>_<RESOURCE>_<UNIT>
```

Examples:
- `CLAM_SIG_MAX_AGE_DAYS` — ClamAV signature freshness threshold
- `LOKI_YARA_MAX_AGE_DAYS` — LOKI-RS YARA rule freshness threshold
- `GUEST_VCPU_COUNT` — Firecracker vCPU allocation
- `GUEST_MEM_MIB` — Firecracker memory allocation
- `SCAN_IMG_SIZE` — scan-target ext4 image size (passed to `truncate` and `mkfs.ext4`)
- `LOKI_MAX_FILE_SIZE` — LOKI-RS per-file size cap (bytes, to match LOKI-RS's `--max-file-size` flag)

If capa lands as a third engine, it adds `CAPA_*` variables in the same file under the same convention, with no ambiguity.

## What `config/scanner.env` looks like

```sh
# config/scanner.env
#
# Operational tunables for the scanner. Sourced by build-station scripts
# and propagated to the scanning host via the data USB (see Implementation
# below). Admins may adjust these values; changes take effect on the next
# `run-update.sh` + data USB write cycle.
#
# Format: shell-sourceable KEY=VALUE. Same constraints as versions.env.

# --- Freshness gates ----------------------------------------------------------
# Maximum age in days before check-system-ready fails the readiness check.
# Both thresholds must be satisfied for the system to be considered ready.
#
# ClamAV signatures update several times daily; 30 days is conservative.
CLAM_SIG_MAX_AGE_DAYS=30

# YARA Forge Core rules update less continuously than ClamAV signatures.
# 60 days is a reasonable default; tighten for higher-threat environments.
LOKI_YARA_MAX_AGE_DAYS=60

# --- Guest VM sizing ----------------------------------------------------------
# Firecracker microVM resources. The guest runs ClamAV and LOKI-RS sequentially
# (or concurrently if parallel-engines lands); size accordingly.
# Note: if running engines in parallel (see parallel-engines.md), each VM
# gets GUEST_VCPU_COUNT vCPUs and GUEST_MEM_MIB RAM independently.
GUEST_VCPU_COUNT=2
GUEST_MEM_MIB=2048

# --- Scan target --------------------------------------------------------------
# Size of the ext4 image materialised from the file USB for presentation
# to the guest as a read-only block device. Must be large enough to hold
# the largest anticipated transfer batch.
SCAN_IMG_SIZE=4G

# --- Per-engine file size caps ------------------------------------------------
# LOKI-RS: maximum file size in bytes. The upstream default is 64 MiB, which
# silently skips larger files — a false-negative vector for a transfer scanner.
# 0 does NOT mean unlimited in LOKI-RS; it means "skip everything". Always
# set an explicit cap.
LOKI_MAX_FILE_SIZE=4294967296
```

## How values reach the scanning host

`config/versions.env` is consumed exclusively on the build station; the scanning host has no copy. `scanner.env` has the same constraint for most values, but the freshness thresholds are an exception — they are enforced by `check-system-ready` *on the scanning host*, so they must travel to the host via the data USB.

The mechanism:

1. `prepare-data-usb.sh` copies `config/scanner.env` to the data USB root alongside `scanner-rootfs.ext4`, `vmlinux`, and `signature-date`.
2. `load-scanner` (in `config/scanner-host.bu` / `config/host-scripts/` after extraction) copies `scanner.env` from the data USB to `/var/lib/troskel/scanner.env`.
3. `check-system-ready` sources `/var/lib/troskel/scanner.env` at the top of the script, then uses `$CLAM_SIG_MAX_AGE_DAYS` and `$LOKI_YARA_MAX_AGE_DAYS` instead of literals.

VM sizing and file-size caps live in build-station scripts and the guest entrypoint only; they do not need to reach the scanning host separately.

## Implementation outline

1. Create `config/scanner.env` with the values and comments above.
2. Add `source "${SCRIPT_DIR}/../config/scanner.env"` to: `build-scanner-image.sh`, `run-update.sh`, and `prepare-data-usb.sh`.
3. Replace the hardcoded `vcpu_count` and `mem_size_mib` values in the Firecracker config template inside `run-scan` with `${GUEST_VCPU_COUNT}` and `${GUEST_MEM_MIB}`.
4. Replace `SIZE="4G"` in `build-scanner-image.sh` with `SIZE="${SCAN_IMG_SIZE}"`.
5. Replace `truncate -s 4G` in `run-scan` with `truncate -s "${SCAN_IMG_SIZE}"`.
6. Replace the hardcoded `--max-file-size 4294967296` in the guest entrypoint with a value injected at image-build time. The cleanest mechanism is to write a small config file into the guest rootfs during `build-scanner-image.sh` (e.g. `/etc/troskel-engine.env`) that the guest entrypoint sources. This preserves the guest's `set -eu` + busybox-portable constraint and avoids passing values through kernel boot args.
7. Update `prepare-data-usb.sh` to copy `config/scanner.env` to the USB.
8. Update `load-scanner` to copy `scanner.env` from the USB to `/var/lib/troskel/`.
9. Update `check-system-ready` (both copies, until the duplication is resolved) to source `/var/lib/troskel/scanner.env` and use the named variables.
10. Update `ARCHITECTURE.md`: add a short section "Configuration" explaining the two-file split (`versions.env` for upstream component versions, `scanner.env` for operational policy) and the propagation mechanism.
11. Update `SECURITY.md`: note that freshness thresholds are now admin-configurable and travel on the data USB; an admin who sets thresholds to `0` or very large values weakens the freshness guarantee deliberately.

## Side effects

- The YARA freshness gate task (`yara-freshness-gate.md`) gains a natural home for its threshold variable; the two tasks should be landed together or in immediate sequence. The config task should land first so the freshness gate task can reference `LOKI_YARA_MAX_AGE_DAYS` directly.
- The parallel-engines task (`parallel-engines.md`) benefits immediately: VM sizing is now a single-line change in `scanner.env` rather than a script edit, which makes the "each VM gets N vCPUs" tuning during that implementation straightforward.
- `tests/test-build.sh` may need a minor update to source `scanner.env` if it exercises any path that previously relied on the hardcoded values.

## What stays the same

The default values in `scanner.env` reproduce the current hardcoded behaviour exactly. A deployment that does not touch `scanner.env` is functionally identical to the pre-task state. This is a refactor, not a policy change.

## Estimated effort

Half a day. The changes are mechanical across a known, bounded set of files. The guest-entrypoint injection step (item 6) is the only non-trivial part: writing and sourcing `/etc/troskel-engine.env` inside the rootfs build needs a small test to confirm the value survives the debootstrap-and-copy pipeline correctly.

## Sequencing

Should land **before** `yara-freshness-gate.md` (so the freshness gate can use `LOKI_YARA_MAX_AGE_DAYS` from the outset) and **before** `parallel-engines.md` (so VM sizing is already tunable when that task needs to halve the per-VM resources).

Independent of the script extraction tasks (`extract-butane-scripts.md`, `extract-guest-scripts.md`), but the config propagation to the guest entrypoint is slightly cleaner to implement after the guest-script extraction, since the target file is then a standalone `guest/run-scan.sh` rather than a heredoc.

## Open questions

- **Should `scanner.env` be versioned alongside `versions.env` under a single `config/` README?** A brief `config/README.md` explaining the two files and their respective scopes would help new contributors orient quickly. Low-cost addition worth considering.
- **Should `SCAN_IMG_SIZE` be validated before use?** `truncate` and `mkfs.ext4` accept human-readable sizes (`4G`) but behaviour on malformed values is silent failure in some cases. A brief validation step (e.g. `[[ "$SCAN_IMG_SIZE" =~ ^[0-9]+[GMK]$ ]]`) would catch typos before the slow debootstrap begins.
- **Should `GUEST_MEM_MIB` carry a minimum enforced at runtime?** ClamAV with a full signature database requires roughly 512 MiB; LOKI-RS adds more. Setting `GUEST_MEM_MIB` below ~1024 would produce an OOM kill mid-scan, yielding yellow. A documented minimum in a comment is probably sufficient; a hard check is low priority.