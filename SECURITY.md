# SECURITY

Threat model and residual risks. The reference for evaluating proposed changes. Anything that weakens an assumption here needs explicit reconsideration.

---

## What is defended against

- **Commodity malware on the file USB.** ClamAV signature detection plus LOKI-RS YARA-rule matching. Probabilistic.
- **Web shells, hack tools, and APT-associated artefacts.** LOKI-RS rule corpus is tuned for these; ClamAV covers them less thoroughly.
- **BadUSB / HID injection (with hardware write blocker).** A write blocker that intercepts HID at the USB protocol layer prevents the file USB from claiming to be a keyboard. This is the strong defence. The kernel-argument fallback (`usbhid.quirks`) handles specific known-bad VID:PID combinations when the blocker's HID-blocking can't be confirmed, but it is a list-based defence and cannot block unknown attackers. Without a write blocker, see "BadUSB / HID injection (no blocker)" under residual risks.
- **Persistence between sessions.** No persistent storage. CoreOS boots into RAM, the guest runs from an ephemeral image, the data USB is read-only, power-off clears everything.
- **Transit-level tampering with upstream artefacts.** Every software component is integrity-verified at download. The verification path is component-specific (see "Architectural security properties" below) but the net effect is the same: a corrupted or man-in-the-middled download fails closed before installation, before any byte from the artefact reaches a built rootfs.

## What is not defended against

- **Compromised build station.** Every artefact downstream is trusted on its word. Operational mitigation only (sensitive-system hardening).
- **Supply-chain compromise at the source.** An attacker who controls a signing key (ClamAV's, Fedora's), or who can substitute artefacts on a CDN that publishes its own SHA-256 sidecars, defeats the verification at the source. Probability low for the established upstreams Troskel depends on; impact high. No client-side mechanism can defend against this.
- **Threats that evade pattern-based detection generally.** Both engines are fundamentally pattern-based. Novel obfuscation, never-before-seen samples, or targeted bespoke malware will pass both. The two-engine architecture provides detection diversity (independent rule corpora, independent maintainers), not orthogonality of detection paradigm.
- **Zero-days** in the block layer, virtio-blk, ext4, or Firecracker's hypervisor surface. The architecture limits consequences but cannot prevent the breach.

## Trust boundaries

| Component            | Trust               | Why                                                                                                                |
|----------------------|---------------------|--------------------------------------------------------------------------------------------------------------------|
| Build station        | Fully trusted       | Produces every artefact. Operational hardening only.                                                               |
| Data USB             | Trusted at write    | SHA-256 verified at write; physical chain of custody after.                                                        |
| LiveOS USB           | Trusted at write    | Equivalent to data USB. Holds password hash.                                                                       |
| File USB             | **Fully untrusted** | Filenames, contents, descriptors, device class, all hostile.                                                       |
| Firecracker guest    | **Untrusted**       | ClamAV and LOKI-RS parsers (and the YARA-X engine LOKI-RS embeds) are assumed exploitable; confined by hypervisor. |
| Scanning host kernel | Trusted             | Guest-to-host escape defeats the design. Mitigated by Firecracker's small attack surface.                          |

## Architectural security properties

Each is structurally enforced and testable.

- **No network in the guest.** Firecracker JSON omits `network-interfaces`. `check-system-ready` greps for it and fails closed.
- **Read-only scan target.** Two enforcement layers: `losetup --read-only` (host kernel) and `is_read_only: true` (hypervisor).
- **Ephemeral guest state.** Guest boots from `cp --sparse=always` of the rootfs; `trap cleanup` removes the workdir on every exit path.
- **Fail-closed verdict.** Three discrete `grep -q` checks: `THREAT DETECTED` → red, `CLEAN` → green, anything else (empty log, panic, OOM, ENOSPC, garbage) → yellow. The verdict-combination logic in the guest entrypoint maps any engine error or anomalous result to ERROR rather than CLEAN.
- **No persistent storage on the scanning host.** CoreOS live USB, tmpfs root, `zincati.service` masked.
- **Signature freshness gate.** `check-system-ready` enforces age limits on both signature sources independently: ClamAV signatures (`CLAM_SIG_MAX_AGE_DAYS`, default 30) and LOKI-RS YARA rules (`LOKI_YARA_MAX_AGE_DAYS`, default 60). The thresholds differ because the upstream cadences differ — ClamAV publishes signatures daily, YARA Forge weekly — and both gates fail closed: a missing or stale freshness file produces a non-zero exit from `check-system-ready` and blocks the scan.
- **Centralised version pinning.** All upstream component versions live in `config/versions.env`, sourced by every script that needs them. Pins fall into the documented categories described in that file's header (PINNED, PINNED-TAG, FLOATING, DERIVED). Inventory is auditable from a single file.
- **Upstream artefact integrity verification.** Every software component the build station fetches is integrity-verified at download. Verification paths differ by what each upstream publishes; the project records the verification method per component so an auditor can see at a glance how trust in each is established. The verification taxonomy:

  | Method                     | Used by              | What it verifies                                                                                                                                                                                                                                                  |
  |----------------------------|----------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
  | `sidecar`                  | Firecracker, LOKI-RS | Upstream publishes a `.sha256` sidecar per asset; the download script fetches both and verifies the asset against the sidecar from the same release URL. Catches transit corruption and CDN tampering.                                                            |
  | `gpg-bootstrap`            | Butane               | Upstream publishes a GPG signature (`.asc`) against the Fedora signing key but no SHA-256 sidecar. The SHA-256 was recorded once after a manual GPG verification; subsequent builds verify against the recorded value, transitively inheriting the GPG guarantee. |
  | `recorded`                 | EFF wordlist         | A pinned SHA-256 was recorded by a developer at the time of pinning. Used for upstreams that publish no per-asset integrity files.                                                                                                                                |
  | `record-at-first-download` | Guest kernel         | The Firecracker CI S3 bucket publishes no sidecars. The first build resolves "latest under CI series", records both the resolved filename and SHA-256 to `versions.env`, and subsequent builds verify against the recorded values.                                |
  | `upstream-signed`          | CoreOS ISO           | The artefact carries an upstream signature verified by tooling outside Troskel (`coreos-installer` against the Fedora signing key). No SHA-256 is recorded by Troskel because the upstream tooling does the verification.                                         |
  | `tls-only`                 | YARA Forge           | YARA Forge publishes no sidecars or signatures alongside its release assets. TLS-from-GitHub is the only integrity guarantee at download time. The downloaded archive's SHA-256 is logged for reproducibility but did not gate the download.                      |
  | `freshclam-embedded-keys`  | ClamAV signatures    | `freshclam` verifies `.cvd` files against keys embedded in the ClamAV binary at download time. Upstream-signed; Troskel relies on the upstream tooling.                                                                                                           |
  | `tag-pinning`              | LOKI-RS IOC base     | The upstream is pinned to an immutable release tag (not a moving branch). Reproducibility rests on tag immutability; per-file hashes are not recorded because the marginal protection over TLS-from-a-tagged-tree is small.                                       |

  The mismatch error path in every verification step is informative: it names the artefact, both checksum values, and the three plausible causes (upstream re-publication, transit corruption, man-in-the-middle), with a clear separate path for accepting a deliberate upstream change.

- **Per-build scanner credential.** The `scanner` user's password is regenerated on each boot-USB build by `prepare-boot-usb.sh` — a fresh four-word diceware passphrase (~51.6 bits of entropy from the EFF Long Wordlist) is hashed with `openssl passwd -6` and substituted into a temporary copy of the Butane config; the committed config carries only the sentinel `@@SCANNER_PASSWORD_HASH@@`. The plaintext is printed to the admin's terminal once at the end of the build and is never written to disk by the build process. The credential's lifetime is bounded by the boot USB's lifetime (which is in turn bounded by the 30-day signature freshness gate), so a long-lived password leak is impossible by construction.

## Residual risks

- **Pattern-based detection only.** Recorded under "what is not defended against" above. Most consequential current limitation.
- **Closed-source-adjacent components in the trust path.** LOKI-RS is open-source (GPLv3), but its default rule corpus (YARA Forge) is curated externally and scanned only as opaque rule files. A compromised rule release would propagate at next update.
- **YARA Forge publishes no integrity sidecars.** Unlike Firecracker and LOKI-RS, YARA Forge release assets carry neither `.sha256` files nor GPG signatures. TLS-from-GitHub is the only integrity guarantee at download time. The downloaded archive's hash is recorded for reproducibility but did not gate the download.
- **Floating upstream channels.** `COREOS_INSTALLER_TAG="release"` and `COREOS_STREAM="stable"` remain moving targets. Pinning each is tracked separately: pinning the CoreOS stream requires accepting a different bump workflow (security updates flow through the stream, so pinning means accepting responsibility for tracking CVEs); pinning the installer container by digest requires a different mechanism (`docker pull` by digest rather than SHA-256 of a downloaded file).
- **Guest rootfs Debian release pinned to trixie.** Trixie was selected over bookworm because LOKI-RS v2.10.0 requires glibc 2.39+ and bookworm ships 2.36. Trixie is currently in freeze leading up to its release as Debian 13; this is acceptable for a build-station target that is itself rebuilt on every signature update, but should be re-confirmed when trixie reaches stable.
- **LOKI-RS scan-time defaults overridden.** `--max-file-size 0` disables the 64 MB default that would otherwise silently skip large files (a false-negative vector for a transfer scanner). `--scan-all-files` overrides the default extension-based filtering, since adversarial input cannot be trusted to declare its own type. Both deviations are deliberate; they trade scan time for coverage.
- **No measured boot.** A physical attacker swapping firmware or USBs is not detected. Mitigated by physical security of the room and labelled USBs.
- **BadUSB / HID injection (no blocker).** Without a hardware write blocker on the file USB port, a malicious file USB can claim to be a keyboard (HID device class) and inject keystrokes during the window between physical insertion and any software-level HID rejection. The kernel-argument `usbhid.quirks` defence is list-based and cannot block unknown VID:PID combinations. Consequences are bounded by structural properties: the scanning host has no network, leaves no persistent state, and clears RAM at power-off — so an attacker gaining a keyboard cannot exfiltrate or persist. The realistic worst case is forging a green verdict during the active session, leading the operator to transfer malware. Mitigations available without the blocker: tighter kernel-level HID defence (e.g. `modprobe.blacklist=usbhid hid-generic` in CoreOS boot args, accepting that no keyboard input is possible after login) or a userspace USB-allowlist daemon. The system is operable without a blocker but the attack surface is meaningfully wider.
- **HID input via non-blocked ports.** The data and LiveOS USB ports cannot be behind the write blocker (they need to be writeable). Mitigated by physical control and operator training.
- **Trust in CoreOS signing.** Compromise of the signing keys would produce a tampered scanning host. Accepted as a property of using the upstream.
- **AV false negatives.** Structural. Green is "no signature or rule matched", not "guaranteed clean".
- **Scan-time resource exhaustion.** No scan timeout. A zip bomb OOMs the guest, producing yellow — correct but inefficient. Adding a host-side timeout is a candidate improvement. The two-engine design now compounds this: both engines walk the same tree sequentially, so total scan time is roughly additive.