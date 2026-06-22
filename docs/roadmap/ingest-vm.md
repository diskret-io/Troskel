# Mount untrusted media inside the guest, not on the host

Move the file-USB mount out of the CoreOS scanning host and into a Firecracker guest. The host presents the raw block device to the guest; the guest's kernel parses the filesystem. Host-kernel filesystem drivers no longer touch attacker-controlled bytes.

## Motivation

The scanning host today mounts the file USB itself, before any virtualisation boundary is crossed. `config/host-scripts/troskel` runs `mount -o ro "$SCAN_DEV" /mnt/usb` against an operator-supplied block device, leaving filesystem-type autodetection to the host kernel. `scan-wrap` then walks the mounted tree with `mkfs.ext4 -F -d "$TARGET_DIR"` to build the read-only image handed to the existing Firecracker scanner guest as `/dev/vdb`.

The architectural premise of the rest of the system, "parser surfaces should be assumed exploitable, so they run inside Firecracker", is contradicted at this point. A malicious ext4, exFAT, or NTFS image targets a kernel filesystem driver on the scanning host itself, with no hardware-virtualisation boundary in between. CoreOS's minimal attack surface does not help: the surface in question is the filesystem-driver subsystem in the host kernel, and that surface is exercised against attacker-chosen input on every scan.

This is the single architectural defect that most undermines the project's stated isolation model. Fixing it brings the file-USB parsing path inside the same Firecracker boundary that ClamAV and LOKI-RS already live behind.

## Current architecture

```
Host: troskel
  └─ mount -o ro /dev/sdX /mnt/usb         ← host kernel parses hostile FS
       └─ scan-wrap
            └─ mkfs.ext4 -F -d /mnt/usb scanfiles.ext4
                 └─ Firecracker VM
                      └─ /dev/vdb (read-only, fresh ext4 built by host)
```

The hostile-input boundary is crossed at the first `mount`, on the host kernel.

## Target architecture

```
Host: troskel
  └─ Firecracker VM — ingest-guest
       ├─ /dev/vdb (raw file-USB block device, read-only)
       └─ guest/ingest.sh
            ├─ mount -t <FS> -o ro,nodev,nosuid,noexec /dev/vdb /mnt/usb
            ├─ walk /mnt/usb, build /tmp/scanfiles.ext4
            └─ emit scanfiles.ext4 to host via virtio-fs / virtio-vsock
                 │
                 ▼
       host receives sealed scanfiles.ext4
            └─ scan-wrap (unchanged from here)
                 └─ Firecracker VMs — clamav-guest, loki-guest, ...
                      └─ /dev/vdb (read-only, image built by ingest-guest)
```

The hostile-input boundary moves to `/dev/vdb` of the ingest guest. The host kernel never sees the file USB's filesystem. The scanner guests downstream see only a host-validated ext4 image, byte-for-byte identical to today.

## Why a separate ingest guest, not the existing scanner guest

The scanner guests (ClamAV, LOKI-RS, and capa under `parallel-engines.md`) receive a read-only ext4 image and are intentionally simple: mount one filesystem of known type, scan, emit a verdict. Adding "also parse arbitrary attacker-chosen filesystems" to that role would conflate two trust boundaries: the boundary against malicious file content and the boundary against malicious filesystem metadata, inside a single VM.

A separate ingest guest keeps the boundaries distinct. The ingest guest mounts the hostile filesystem and produces a sealed ext4 image; the scanner guests consume that image. If the ingest guest is compromised by a malicious filesystem, the blast radius is bounded by what it can write into the scanfiles.ext4 it emits, which is then re-parsed at ext4 level by independent scanner guests inside their own VMs. The compromise does not propagate sideways to the engines.

This also makes the ingest path independently auditable: a single VM with a single job (parse one filesystem, emit a sealed image) is easier to reason about than a VM that does both ingestion and scanning.

## What changes

### New: `guest/ingest.sh`

The ingest guest's entrypoint. Mounts `/dev/vdb` read-only with a fixed `-t` argument, walks the tree, builds a fresh ext4 image at `/tmp/scanfiles.ext4`, and emits it to the host. 

All decisions about which filesystems to support are made at the host level via the `INGEST_FS_TYPE` parameter; the guest never autodetects. Symlink-following, device nodes, and special files are excluded by construction. Path length and tree depth caps belong inside `find` and are tuned against expected operator transfers.

### New: `guest/ingest-rootfs.ext4`

A minimal Debian rootfs containing just busybox, `mount`, `mkfs.ext4`, `tar`, `find`, and the kernel modules for the supported filesystems. Built by a new `scripts/build-ingest-image.sh` alongside the existing `build-scanner-image.sh`. Significantly smaller than the scanner rootfs because it carries no ClamAV, no YARA engine, no signatures.

Two important properties of the ingest rootfs:

- **No network tools.** The ingest guest has no network device exposed by the Firecracker config, and the rootfs carries no `nc`, `curl`, `wget`, `ssh`, or networking utilities. Even given a guest compromise, there is no way out via the network because there is no network and no tools to use it.
- **Read-only root.** The rootfs is mounted read-only inside the guest. The only writeable surface is the tmpfs at `/tmp` where `scanfiles.ext4` is built. A compromised ingest guest cannot persist anything across boots because there is nothing to persist to.

### Modified: `config/host-scripts/troskel`

The hotplug auto-selection (`tail -1`) and the host-side `mount` both go away. The new flow:

1. Enumerate candidate file-USB block devices (USB transport, removable, not the TROSKEL-DATA medium).
2. Require explicit operator selection if more than one is present. (This subsumes the "remove hotplug auto-selection" remediation; doing both changes together is cleaner than sequencing them.)
3. Determine the filesystem type via `blkid` on the host. The host reads the filesystem signature only — it does not mount. The result is one of a fixed allowlist (`ext4`, `vfat`); anything else is refused with a clear operator message.
4. Pass the raw block device to `scan-wrap` along with the detected filesystem type.

`blkid` reads only the superblock magic and label region, not the full filesystem; it does not constitute the same parsing surface as a mount. Even so, the call should be wrapped in a strict timeout and its output validated against the allowlist before being used.

### Modified: `config/host-scripts/scan-wrap`

The image-construction logic (`truncate`, `mkfs.ext4 -F -d "$TARGET_DIR"`) is removed. Instead:

1. Launch the ingest VM with `/dev/vdb` bound to the file-USB raw block device (read-only) and the filesystem type passed via Firecracker `boot_args` as `troskel.ingest_fs=<type>`.
2. Wait for the ingest VM to terminate. Parse its serial output for the `INGEST:` line under the verdict-grammar rules from `verdict-grammar.md` (see Sequencing).
3. On `status=ok`, retrieve the sealed `scanfiles.ext4` from the ingest guest. The transport is virtio-vsock with a fixed message format, or virtio-fs with the guest exposing `/tmp` read-only to the host post-ingest — the choice is an open question below.
4. Proceed with the existing scanner-VM flow against the retrieved image.

The fail-closed property of the existing verdict pipeline extends naturally: an ingest VM that fails to emit `INGEST: status=ok` produces a yellow verdict at the operator level, exactly as a failed scanner VM does today.

### Modified: filesystem support policy

Today the operator guide states that any filesystem the scanning host can mount works, including NTFS and exFAT. This changes. The supported set becomes:

- **ext4**: principal Linux filesystem, well-exercised parser.
- **vfat (FAT32)**: simplest parser, universal interchange format.

NTFS and exFAT are removed. NTFS in particular has a parser history substantial enough that, even running inside the ingest guest, the cost-benefit is poor for a transfer scanner. Operators who today bring NTFS media will need to reformat or use a different medium; this is an acceptable operator-facing cost in exchange for shedding a complex driver from the attack surface.

The operator guide is updated. `check-system-ready` does not need to know about this, the host-side `blkid` allowlist enforces it.

### Modified: `scripts/build-ingest-image.sh` (new) and `scripts/run-update.sh`

`run-update.sh` gains a step to build the ingest rootfs alongside the scanner rootfs. The shared-base optimisation from `parallel-engines.md` applies: the ingest rootfs and scanner rootfs share a common debootstrap base, with engine-specific installers running on top. Additional build time over the present pipeline: roughly two to three minutes for the ingest-specific install steps.

### Modified: `prepare-data-usb.sh` and `load-scanner`

The data USB now carries `ingest-rootfs.ext4` alongside the scanner rootfs(es). `prepare-data-usb.sh` copies it across with a corresponding SHA-256; `load-scanner` includes it in the artefacts it copies into `/var/lib/troskel/`.

### Modified: `check-system-ready`

Gains an `Ingest image loaded` check, paralleling the existing `Scanner image loaded` check. The check name should match the operator-visible naming.

## How the sealed image travels back to the host

Two viable transports:

**Option A — virtio-vsock.** The ingest guest opens a vsock listener on a fixed port; the host connects post-ingest and reads the image stream. Pro: cleanly one-way (host is the reader, guest is the writer), no shared filesystem state. Con: requires vsock support in the guest kernel (already present in the Firecracker-recommended kernel) and a small host-side reader written carefully.

**Option B — virtio-fs with host-exposed scratch directory.** The host exposes a fresh empty directory to the guest as a writeable virtio-fs mount; the guest writes `scanfiles.ext4` into it; the host reads from the same directory after the guest terminates. Pro: simpler host code (just read a file). Con: the directory is bidirectional during the ingest VM's lifetime, which is a wider channel than vsock.

Recommendation: Option A. The vsock channel is constrained by construction to "guest writes bytes, host reads them"; the host-side reader rejects anything that does not parse as a sized ext4 image header followed by the declared number of bytes, with a hard cap on size. This composes well with the sealed-grammar discipline in `verdict-grammar.md`.

## Side effects

- **`run-update.sh` builds an additional rootfs.** Roughly two to three minutes of additional build time over the present pipeline, less than `parallel-engines.md` adds because the ingest rootfs is much smaller (no engines, no signatures, no YARA rules).
- **Data USB grows.** Ingest rootfs adds approximately 80–120 MiB to the data USB footprint. Negligible against contemporary USB capacities.
- **`tests/test-scan.sh` needs an ingest-failure path.** A new fixture — a file USB image that the ingest guest cannot mount, or one whose tree exceeds the configured limits — should produce a yellow verdict at the operator level. The existing red and green paths are unaffected because they operate on the post-ingest image, which is byte-for-byte equivalent to today's `scanfiles.ext4`.
- **Operator-guide updates.** The supported-filesystems section changes; the "any filesystem the scanning host can mount" sentence goes away; the multi-USB section is rewritten to describe the new explicit-selection flow.
- **SBOM additions.** The ingest rootfs needs its own SBOM component entries (busybox, debian-base, kernel modules for the supported filesystems).
- **Boot-time presence checks.** check-system-ready and the pre-login banner (the signature-date display, shipped) both already display loaded-image state.

## What stays the same

The operator-facing workflow does not change visibly. `troskel` is still the entry point; the operator still inserts a file USB, still sees a green / red / yellow verdict; the per-engine breakdown under the verdict is identical because the scanner VMs receive an ext4 image identical to today's. The security model's primary guarantee, hardware virtualisation between hostile bytes and the scanning host, is unchanged in headline terms and strengthened in substance: it now covers filesystem parsing as well as engine parsing.

The verdict-grammar work (`verdict-grammar.md`) and the per-engine isolation work (`parallel-engines.md`) compose cleanly with this change. The ingest VM's `INGEST:` output is parsed under the same grammar discipline as `ENGINE:` and `VERDICT:` lines; the post-ingest sealed image flows into the per-engine VMs unchanged.

## Estimated effort

One to two weeks for the architectural fix.

The work decomposes into:

- Ingest rootfs build and the shared-base refactor of `build-scanner-image.sh`: two to three days.
- Host-side enumeration, `blkid`-based filesystem detection, and the explicit-selection flow in `troskel`: one to two days.
- Ingest-guest launch and sealed-image retrieval in `scan-wrap`: two to three days, dominated by the vsock reader and its bounds-checking.
- `prepare-data-usb.sh`, `load-scanner`, `check-system-ready` updates: half a day.
- Test additions (ingest-failure fixture, oversized-tree fixture, malformed-superblock fixture): one to two days.
- Operator-guide and architecture-doc updates: half a day.

The interim mitigation, stay on the host mount path, restrict filesystems to ext4 and FAT32 only, mount with `nodev,nosuid,noexec`, use `O_NOFOLLOW`, refuse special files, takes two to four days and can be deployed first while the full architectural fix is in flight. Interim mitigation is acceptable for a working release; it is not acceptable for the Tier 2 readiness claim.

## Sequencing

This is the highest-priority item on the Tier 2 readiness path. It should land before any external Tier 2 review.

Depends on `verdict-grammar.md` (the `INGEST:` line consumes the same sealed grammar). Does not depend on `parallel-engines.md`; the two are independent and compose without ordering constraints. Does not depend on the signed-certificate or data-USB anchoring work; those are downstream of this in the Tier 2 plan but architecturally unrelated.

Target `1.2.0`. The host-mount path is correctness-critical for the Tier 2 claim but is not a defect that blocks `1.0.0` or `1.1.0` deployment under the present (sub-Tier-2) posture — the interim mitigation suffices for those releases.

## Open questions

- **Should `blkid` run on the host or inside a separate read-only-superblock helper VM?** Running on the host re-introduces a small parsing surface (the superblock-magic and label region) on the host kernel, which is the surface the rest of this work is trying to eliminate. Running it in a helper VM is cleaner but adds a third VM to the scan pipeline. The host-side `blkid` is probably acceptable because the surface it exercises is genuinely small and well-bounded, but the alternative deserves a careful look.
- **Should the ingest VM be given the file USB as `/dev/vdb` directly, or via an intermediate loop device on the host?** Direct exposure is simpler. Loop indirection allows the host to enforce strict read-only at the loop layer, which the Firecracker `is_read_only: true` flag also enforces — but defence in depth here is cheap.
- **What is the upper bound on `scanfiles.ext4` size?** Today `SCAN_IMG_SIZE` defaults to 4 GiB. The ingest VM's resource budget needs sizing against this. Pre-allocating a 4 GiB image inside the ingest VM costs RAM in a tmpfs-resident `/tmp`; the ingest VM needs `mem_size_mib` increased to accommodate. Alternatively, the host pre-allocates the target image and exposes it to the ingest guest as a writeable block device, which sidesteps the tmpfs question but introduces another guest-to-host write path that needs constraining.
- **Should the ingest VM emit per-file hashes alongside the sealed image?** A manifest of paths and SHA-256s, signed implicitly by the `INGEST:` line's place in the grammar, would feed the reverse-direction integrity work in the Tier 2 plan's Phase 2 (detect post-scan modification of the file USB). Probably worth doing in this same change because the ingest guest is already walking the tree.
- **Is the executable-extraction step from `parallel-engines.md` performed by the ingest guest or by the host?** Either is defensible. Performing it in the ingest guest keeps all filesystem-walking on one side of a virtualisation boundary; performing it on the host keeps the ingest guest's job minimal. Decide once both `parallel-engines.md` and this change are scheduled together.