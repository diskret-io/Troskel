---
id: "load-scanner-verify-rootfs-2026-06-19"
status: "in-progress"
priority: "high"
assignee: "k"
epic: null
dueDate: null
created: "2026-06-19T00:00:00.000Z"
modified: "2026-06-20T12:58:50.591Z"
completedAt: null
labels: ["security", "verification", "host"]
order: "a0"
---
# load-scanner copies the rootfs to the air-gapped host without verifying it

`config/host-scripts/load-scanner` copies `scanner-rootfs.ext4` from the
data USB into `/var/lib/troskel` on the scanning host with a bare `cp` and
performs no integrity check. The sidecar `scanner-rootfs.ext4.sha256` is
present on the USB (written and verified by `prepare-data-usb.sh` on the
build station) but `load-scanner` never reads it. The scanning host
therefore trusts the rootfs purely on `cp` returning zero.

This is the most security-sensitive hop in the whole pipeline: the file
being copied unverified is the executable image that becomes the scanning
VM. A bit-flip on the USB in transit, a partial read, or a tampered medium
would be loaded and run with no signal. Every other consumer of this
sidecar (build-station verify in `prepare-data-usb.sh`, orchestrator phase
5) now routes through the shared verification module; the host-side hop is
the one that was left bare.

## Motivation

The verification-protocol consolidation
(`rewrite-verification-protocol`) deliberately scoped itself to the build
station, because the module is bash-plus-coreutils and the build container
guarantees those. `load-scanner` runs on the CoreOS scanning host, which
was out of that card's scope, so the host-side copy was never brought under
verification. Closing `rewrite-verification-protocol` surfaced this as the
next layer: the build station now verifies the USB it writes, but the host
that consumes the USB does not re-verify before loading.

"Exit codes are not the only signal" (QUALITY.md): `cp` returning zero does
not establish that the bytes on the host match the bytes the build station
hashed. The sidecar exists precisely to make that checkable, and the check
is currently skipped on the one hop where the artefact crosses the air gap.

## Current state

`load-scanner` does, in order: mount the data USB read-only, `mkdir -p
/var/lib/troskel`, then a series of bare `cp` calls including
`cp "$MOUNT/scanner-rootfs.ext4" "$DEST/"`. No sidecar read, no checksum,
no re-read of the destination. The manifest hop added in the
manifest-propagation work does validate the manifest's fields, but the
rootfs itself is copied unchecked.

The script is `#!/bin/bash` and the manifest block already uses
`grep`/`sed`; coreutils (hence `sha256sum`) is expected to be present on the
CoreOS host via the Butane-provisioned image, but this MUST be confirmed
(see open questions), not assumed.

## Target state

`load-scanner` verifies `scanner-rootfs.ext4` against its sidecar after
copying it to `/var/lib/troskel`, re-reading from the destination (not the
USB), and refuses to leave a corrupt rootfs in place. Because this is the
artefact that will be executed, a failed verification here is fatal: the
script must remove the bad copy and exit non-zero rather than load it. This
is unlike the manifest hop, where corruption degrades to a warning;
metadata can be unknown, but the executable image cannot be unverified.

The verification re-reads from `$DEST` rather than the USB so that a copy
which succeeds off the USB but lands corrupt on the host (full filesystem,
device error on write) is still caught. Per the destructive-operations
rule, a cheap post-condition immediately after the copy plus the sidecar
check before the artefact is consumed.

## Implementation outline

- Reuse the shared protocol if the host can source it. The cleanest option
  is to make `scripts/lib/verify-artefact.sh` available on the host image
  (it is pure bash + coreutils) and call `verify_artefact_check "$DEST"
  "$DEST/scanner-rootfs.ext4.sha256"`. This keeps one implementation across
  build station and host, which is the whole point of the module. Requires
  confirming the module is shipped to the host (Butane file, or copied off
  the USB) and that the host has bash + coreutils.
- If sourcing the module on the host proves impractical, fall back to an
  inline `cd "$DEST" && sha256sum --check scanner-rootfs.ext4.sha256` with a
  contract comment pointing at the module as the canonical implementation
  and a note explaining why the host cannot use it. This reintroduces a
  second implementation, so prefer the first option; the module exists to
  avoid exactly this.
- The sidecar must be copied to `$DEST` alongside the rootfs (currently it
  is not copied at all). Add `cp "$MOUNT/scanner-rootfs.ext4.sha256"
  "$DEST/"` before the verification.
- On verification failure: `rm -f "$DEST/scanner-rootfs.ext4"`, print a loud
  diagnostic naming the expected vs actual state, and exit non-zero so the
  scanner is not started against a bad image.

## Side effects

- An old data USB written before sidecars existed would now fail to load.
  Confirm whether any such media is still in circulation; if so, the failure
  message must tell the operator to rewrite the USB on the build station.
  (By 1.0.0 every written USB carries a sidecar, so this mirrors the
  manifest "old USB" handling, but the rootfs case is fatal, not a warning.)
- Adds a `sha256sum` over the rootfs on the host at load time. The rootfs is
  multi-hundred-MB, so this is a few seconds of additional load time; name
  it in the progress output so it does not look hung (the orchestrator's
  heartbeat is build-station only and does not apply here).

## Failure modes to handle (per QUALITY.md)

- Verification must re-read from `$DEST`, not from `$MOUNT`. Verifying the
  USB copy and then trusting a separate `cp` to the host is the same class
  of gap this card exists to close. The check named in the artefact's
  sidecar must be run against the host copy that will actually be executed.
- The success path must be substantive: a test in which the host copy is
  corrupted must make `load-scanner` exit non-zero and remove the bad image.
  If verification cannot in principle fail (e.g. it re-reads the USB, or the
  sidecar is the one on the USB rather than a hash of the host copy), it is
  decorative.
- A path-bearing or malformed sidecar must fail closed, not be skipped. If
  the module is reused this is handled; if the inline fallback is used,
  `sha256sum --check` on a path-bearing sidecar can resolve the wrong file,
  so the fallback must guard against an absolute or slashed path field the
  way the module does.
- `|| true` must not be used to soften the rootfs verification. A failure
  here is fatal by design.

## Estimated effort

Half a day if the module ships to the host cleanly; a little more if the
host-image plumbing (getting `verify-artefact.sh` onto the CoreOS host)
needs work, which is the main unknown.

## Sequencing

High priority despite landing after 1.0.0: this is an unverified
executable-image load across the air gap, which is a stronger security gap
than anything in the 1.0.0 list closed. It pairs naturally with whoever
next touches the host-side scripts. It does not block other work, but it
should not sit in the backlog as "low".

## Open questions

1. Does the CoreOS scanning host have `sha256sum` (coreutils) and a bash
   compatible with `verify-artefact.sh`? The script is `#!/bin/bash` and
   uses coreutils already, which strongly suggests yes, but confirm against
   the actual provisioned image before relying on the module on the host.
2. How does `verify-artefact.sh` reach the host? Options: bake it into the
   boot/host image via Butane, or copy it off the data USB (it would need to
   be written there by `prepare-data-usb.sh`). The second keeps the module
   versioned with the artefacts it verifies, which is appealing, but means
   trusting a copy of the verifier that arrived on the same USB as the thing
   it verifies. Decide which trust model is acceptable; baking it into the
   host image is the more defensible choice.
3. Should `vmlinux` (also copied unverified, and also executed) get the same
   treatment in this card, or a sibling? It has no sidecar today. Arguably
   the kernel deserves the same integrity guarantee as the rootfs; scope
   this card to the rootfs and raise the kernel as a follow-up, or widen it.