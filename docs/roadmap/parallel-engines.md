# Per-engine Firecracker isolation and parallel execution

Currently ClamAV and LOKI-RS run sequentially inside a single Firecracker guest, sharing the same Debian rootfs, process namespace, and serial output channel. This task splits each engine into its own independent microVM and runs all VMs concurrently, reducing wall-clock scan time and strengthening the isolation boundary between engines.

This document is written for three engines: ClamAV, LOKI-RS, and Capa, as a first-class design target. Capa's resource profile and execution model differ enough from the other two that designing for two engines and retrofitting a third would require revisiting most of the decisions made here anyway. See `capa-third-engine.md` for capa-specific implementation detail.

## Why not parallelism within a single VM

The straightforward alternative, launch all three engines as background processes inside the current single guest and `wait` for all, was considered and rejected for three reasons.

**Resource contention is unmanageable at three engines.** ClamAV is I/O-heavy; LOKI-RS with `--threads 0` is CPU-heavy; capa's static disassembly is both CPU- and memory-hungry. `capa-third-engine.md` already notes that 2048 MiB may be tight for capa alone. Three engines sharing one VM's resource pool would require 6+ GiB to avoid contention-induced OOM kills, making the memory budget unpredictable and the sizing conversation intractable. Separate VMs allow each engine's footprint to be measured and sized independently.

**The serial channel interleaving problem grows with each engine added.** With two or more concurrent processes writing to `/dev/ttyS0`, their output interleaves. The `ENGINE:` and `VERDICT:` lines the host parses could be corrupted mid-write. The mitigation — buffer all output to tmpfs, emit structured lines only after all engines finish — loses live scan progress and adds coordination logic that is difficult to audit. With separate VMs the serial channel is never shared.

**Capa's "third pass" model fits the per-VM architecture naturally.** The Capa roadmap doc suggests running Capa only against files that the first two engines cleared, to manage scan time on the common case where ClamAV or LOKI-RS catches something early. This is straightforward with separate VMs: the host simply does not start the capa VM if either of the first two returns a threat verdict. Implementing selective execution within a shared VM would require a coordination layer inside the guest that does not currently exist.

The single-VM parallelism option is recorded here as a deliberate path not taken, so future contributors do not need to reconstruct this analysis.

## Current architecture

```
Host: run-scan
  └─ Firecracker VM (single instance)
       └─ guest/run-scan.sh
            ├─ ClamAV      (sequential)
            └─ LOKI-RS     (sequential)
                 └─ VERDICT: emitted to /dev/ttyS0
```

One VM, one serial log, one verdict. The host greps the single log for `VERDICT: THREAT DETECTED` or `VERDICT: CLEAN`.

## Target architecture

```
Host: run-scan
  ├─ Firecracker VM — clamav-guest   ─┐
  │    └─ guest/run-clamav.sh         │  started concurrently
  │         └─ VERDICT → clamav.log   │
  │                                   │
  ├─ Firecracker VM — loki-guest    ──┘
  │    └─ guest/run-loki.sh
  │         └─ VERDICT → loki.log
  │
  └─ [only if both above return CLEAN]
       Firecracker VM — capa-guest
            └─ guest/run-capa.sh
                 └─ VERDICT → capa.log

Host: combine all verdicts under OR semantics → single operator verdict
```

ClamAV and LOKI-RS run concurrently. Capa runs as a conditional third pass, only if both return clean. Wall-clock time on the threat path is bounded by max(ClamAV, LOKI-RS). On the clean path it is max(ClamAV, LOKI-RS) + capa, but capa only runs against the executable subset of the scan target (see `capa-third-engine.md`), which substantially limits its runtime contribution.

## Why isolation is worth having

The existing hardware-virtualisation boundary between host and guest provides the primary isolation guarantee: a parser exploit within any engine cannot reach the CoreOS scanning host. Within the current single guest, however, all engines share a process namespace. A guest-level compromise by one engine could in principle interfere with another engine's verdict signal on `/dev/ttyS0`.

Separate VMs close this gap: each engine writes to its own serial device, the host reads independent logs, and there is no shared address space between engines at any point. The security gain is incremental — the guest-to-host channel is already constrained to one-way text — but it is the honest implementation of the "parser surfaces should be assumed exploitable" principle stated in `architecture.md`.

## What changes

### Guest entrypoint split

The current `guest/run-scan.sh` is replaced by three focused scripts:

**`guest/run-clamav.sh`** — ClamAV only. Mounts `/dev/vdb` read-only, runs `clamscan` with the flags from `clamav-tightening.md`, emits `ENGINE: clamav ...` and `VERDICT: THREAT DETECTED` / `VERDICT: CLEAN` / `VERDICT: ERROR` to `/dev/ttyS0`, reboots.

**`guest/run-loki.sh`** — LOKI-RS only. Same structure: mount, scan, emit verdict, reboot.

**`guest/run-capa.sh`** — capa only. Receives the executable-file subset of the scan target (see scan-target handling below), runs capa, maps capability findings to a verdict under the policy defined in `capa-third-engine.md`, emits `ENGINE: capa ...` and `VERDICT:`, reboots.

Each script is simpler than the combined `run-scan.sh` because verdict combination moves entirely to the host. The `ENGINE:` summary line format is preserved unchanged so the host's `summarise_engine()` function requires no modification per engine — only an additional call for each new engine.

### Three scanner rootfs images

Three separate ext4 images are built:

- `scanner-rootfs-clamav.ext4`: Debian minbase + ClamAV + signatures. No LOKI-RS, no capa.
- `scanner-rootfs-loki.ext4`: Debian minbase + LOKI-RS + YARA rules. No ClamAV, no capa.
- `scanner-rootfs-capa.ext4`: Debian minbase + capa binary + rules. No ClamAV, no LOKI-RS.

Each image contains only what its engine needs. The ClamAV image has no YARA rule attack surface; the LOKI-RS image has no ClamAV parser surface; the capa image has neither. This makes each image independently auditable and keeps image sizes smaller than a combined rootfs would be.

`build-scanner-image.sh` is refactored into a shared base-rootfs builder (debootstrap + busybox) and three engine-specific installer scripts on top. The shared base is built once and copied three times before each engine's installer runs, avoiding three full debootstraps and keeping total build time reasonable.

The data USB carries all three images. `prepare-data-usb.sh` and `load-scanner` are updated accordingly.

### Scan-target handling for capa

ClamAV and LOKI-RS each receive the full scan-target ext4 image as `/dev/vdb`, read-only, as today. Capa is different: it operates only on executable files (PE, ELF, etc.) and is slow per file. Presenting the full file tree to capa would inflate scan time unnecessarily.

The host extracts the executable-file subset from the scan-target image before starting the capa VM, materialises it as a separate smaller ext4 image, and passes that as capa's `/dev/vdb`. This extraction runs on the host using standard tools against the already-existing scan-target loop device, after ClamAV and LOKI-RS have returned clean — so it is only performed when needed. No modifications to the original scan-target image are required.

The definition of "executable" for extraction purposes should be conservative: PE/ELF/Mach-O by magic bytes, not by file extension. Adversarial input cannot be trusted to declare its own type. The implementation detail belongs in `capa-third-engine.md`.

### Host `run-scan` rewrite

The host-side Firecracker wrapper is rewritten to:

1. Build three ephemeral overlay images (one per rootfs).
2. Build one shared read-only scan-target image from the file USB (unchanged from current).
3. Start the ClamAV and LOKI-RS VMs concurrently, each with its own API socket, config, log file, and serial device.
4. `wait` for both PIDs.
5. If either log contains `VERDICT: THREAT DETECTED` → emit red verdict immediately. Do not start capa.
6. If both logs contain `VERDICT: CLEAN` → extract the executable subset, start the capa VM, `wait` for it.
7. Combine all available verdicts: `THREAT` in any log → red; `CLEAN` in all logs → green; anything else → yellow.
8. Display per-engine summaries via `summarise_engine()`, called once per log.

The fail-closed logic is preserved and extended: a missing or empty log from any engine produces yellow. Step 5's early exit on a threat result means the capa VM is never started unnecessarily, keeping the common threat-detected path as fast as today.

### VM sizing

With ClamAV and LOKI-RS running concurrently the natural allocation is 1 vCPU and 1024 MiB RAM per VM. Both engines fit comfortably within these bounds individually. Capa requires more memory for disassembly; `capa-third-engine.md` recommends measuring against a representative corpus before committing, but 2 vCPUs and 2048 MiB is a reasonable starting point.

Per-engine sizing lives in `config/scanner.env` alongside the existing freshness thresholds. Per-engine variables are warranted here because the engines have meaningfully different resource profiles:

```sh
CLAM_GUEST_VCPU_COUNT=1
CLAM_GUEST_MEM_MIB=1024

LOKI_GUEST_VCPU_COUNT=1
LOKI_GUEST_MEM_MIB=1024

CAPA_GUEST_VCPU_COUNT=2
CAPA_GUEST_MEM_MIB=2048
```

This follows the engine-prefixed naming convention already used by the existing per-engine tunables in `scanner.env` (e.g. `LOKI_MAX_FILE_SIZE`, `LOKI_YARA_MAX_AGE_DAYS`).

### Scan-target block device sharing

ClamAV and LOKI-RS VMs both mount the same read-only loop device concurrently. The current architecture already uses `losetup --read-only` and `is_read_only: true` in the Firecracker config; two VMs pointing at the same loop device is safe. Worth a brief verification test: confirm two simultaneous `losetup --read-only` consumers produce no kernel contention warnings on the target hardware.

## Verdict combination at the host

The current single-log logic generalises cleanly to N engines:

```bash
combine_verdicts() {
    # Returns 1 (threat) if any log contains THREAT DETECTED.
    # Returns 0 (clean) if all logs contain CLEAN.
    # Returns 2 (unclear) otherwise.
    local LOGS="$@"
    for LOG in $LOGS; do
        grep -q "VERDICT: THREAT DETECTED" "$LOG" && return 1
    done
    for LOG in $LOGS; do
        grep -q "VERDICT: CLEAN" "$LOG" || return 2
    done
    return 0
}
```

The `THREAT` check precedes `CLEAN` as before, preserving fail-closed semantics: a log containing both (e.g. from a partially written guest output) is treated as a threat. Called first against the ClamAV and LOKI-RS logs; called again including the capa log if capa ran.

Each engine's log is preserved separately under `/var/log/troskel/` with a timestamped name. A short index file listing all log paths for a given scan session is written alongside them, giving the operator a single reference point without requiring log concatenation.

## Side effects

- `run-update.sh` now builds three rootfs images. With the shared-base optimisation the additional build time is roughly two engine installs on top of one debootstrap, rather than three full debootstraps. Estimated additional time: 5–8 minutes over current.
- The data USB must hold three rootfs images. At approximately 400 MiB per image, total USB space for rootfs images increases from ~400 MiB to ~1.2 GiB. Well within the capacity of any contemporary USB drive.
- `check-system-ready` gains three image-presence checks, replacing the current single check. The check names should include the engine name (`ClamAV image loaded`, `LOKI-RS image loaded`, `capa image loaded`) for clarity.
- `SBOM.json` component entries for ClamAV, LOKI-RS, and capa should note their separation into independent rootfs images.
- `tests/test-scan.sh` requires a substantial update: three VMs, conditional capa execution, and combined verdict logic all need exercising. Red paths should be tested per-engine (ClamAV catches, LOKI-RS catches, capa catches) as well as the full clean path through all three. This is the most time-consuming part of the implementation.

## What stays the same

The operator-facing workflow is unchanged: `troskel` is invoked, a green/red/yellow verdict is displayed with a per-engine breakdown. The operator does not need to know about VM topology or the conditional capa execution path.

The security model's primary guarantee — hardware-virtualisation boundary between untrusted input and the scanning host — is unchanged and in fact strengthened by the per-engine isolation.

## Estimated effort

Two to three days. The rootfs build refactor with shared base, the host-side verdict combination rewrite with conditional capa execution, and the test update are the most significant pieces. The guest entrypoint scripts are each simpler than the current combined `run-scan.sh`. Capa-specific work (executable extraction, verdict policy) is scoped in `capa-third-engine.md` and not counted here.

## Sequencing

Depends on `capa-third-engine.md` — the capa guest entrypoint, verdict policy, and executable-extraction logic are defined there; this task consumes those definitions.

Target `1.1.0`. The current single-VM sequential design is correct and safe; this task makes it faster and better isolated, but it is not a correctness fix and should not block `1.0.0`.

## Open questions

- **Should ClamAV and LOKI-RS start with a small stagger rather than strictly concurrently?** On a KVM host with limited RAM, two simultaneous Firecracker boots may contend during kernel decompression. A 1–2 second stagger costs negligible wall-clock time. Worth testing on representative hardware before deciding.
- **What is the right executable-extraction definition for the capa scan target?** Magic-byte detection is more reliable than extension-based filtering but requires tooling on the host. The extraction step must itself be auditable and not introduce new attack surface. Implementation detail belongs in `capa-third-engine.md`.
- **Should per-engine VM sizing variables live in `scanner.env` or a separate `config/engines.env`?** The variables follow the same pattern as the freshness thresholds in `scanner.env` and are adjusted for the same reasons (hardware constraints, operational tuning). Keeping them in one file is simpler; splitting is more organised if the file grows large. Lean toward `scanner.env` unless it becomes unwieldy.
- **Should the log index file be written to the data USB as a post-scan artefact?** This would give the admin a record without requiring a photograph. Requires briefly remounting the data USB writeable after the scan, which complicates the current clean "data USB unmounted after load-scanner" invariant. Probably better served by the "Clean Certificate" feature idea than by ad-hoc log copying.