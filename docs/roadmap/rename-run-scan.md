# Rename scripts to disambiguate host wrapper, operator command, and guest entrypoint

The project has three scripts with confusingly related names doing distinct jobs:

- **`run-scan`** — lives on the scanning host (embedded in `config/scanner-host.bu`). Wraps Firecracker, sets up the ephemeral rootfs and read-only scan target, parses the verdict log, prints the coloured block to the operator. Does not perform scanning itself.
- **`scan-files`** — lives on the scanning host. The operator-facing entry point: detects the file USB, mounts it read-only, calls `run-scan`, unmounts. This is the command operators type.
- **`run-scan.sh`** — lives inside the guest rootfs. Mounts the read-only scan target, invokes ClamAV and LOKI-RS, combines verdicts, emits `VERDICT:` and `ENGINE:` lines to serial. Does perform the actual scanning.

The naming conflates the host wrapper with the guest scanner, and gives the operator-facing command a generic name that does not identify the product.

## What changes

**`run-scan` → `scan-wrap`**

The host-side Firecracker wrapper is renamed to `scan-wrap`. The name accurately describes the script's role — it wraps the VM invocation — and is clearly distinct from the guest-side `run-scan.sh`. Contributors working on the wrapper know immediately what it is; operators never interact with it directly.

**`scan-files` → `troskel`**

The operator-facing command is renamed to `troskel`, matching the project name. The operator types `troskel` to initiate a scan — a single, memorable command that identifies the product. This is the only command name operators need to know. The rename is surfaced in `README.md` and `docs/OPERATOR-GUIDE.md`.

**`run-scan.sh` (guest)** — unchanged. It lives inside the microVM, is never on the scanning host's `$PATH`, and its name is invisible to operators. Renaming it would complicate `inittab` and add noise without benefit.

## Files updated

- `config/scanner-host.bu` — file paths for both scripts updated.
- `config/host-scripts/scan-wrap` — new location of former `run-scan`, after the Butane extraction lands.
- `config/host-scripts/troskel` — new location of former `scan-files`, internal call updated from `run-scan` to `scan-wrap`.
- `scripts/check-system-ready.sh` and embedded copy — the network-interface grep that inspects `/usr/local/bin/run-scan` updated to `/usr/local/bin/scan-wrap`.
- `tests/test-scan.sh` — direct file copy updated from `config/host-scripts/run-scan` to `config/host-scripts/scan-wrap`, `/tmp/run-scan` references updated to `/tmp/scan-wrap`.
- `tests/manual-tests-scan.md` — all invocations updated.
- `README.md` — operator workflow updated to `troskel`.
- `docs/OPERATOR-GUIDE.md` — all operator-facing references to `scan-files` updated to `troskel`.

## What stays the same

The operator-facing workflow is simpler, not different: instead of `scan-files`, the operator types `troskel`. The underlying behaviour is identical. No retraining beyond the new command name.

## Estimated effort

One to two hours. Mechanical find-and-replace, plus a careful read of operator-facing documentation to confirm no stale `scan-files` references remain. This task was completed alongside the Butane script extraction.