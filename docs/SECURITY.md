# SECURITY

Threat model and residual risks. The reference for evaluating proposed changes. Anything that weakens an assumption here needs explicit reconsideration.

---

## What is defended against

- **Commodity malware on the file USB.** ClamAV signature detection plus LOKI-RS YARA-rule matching. Probabilistic.
- **Web shells, hack tools, and APT-associated artefacts.** LOKI-RS rule corpus is tuned for these; ClamAV covers them less thoroughly.
- **BadUSB / HID injection (with hardware write blocker).** A write blocker that intercepts HID at the USB protocol layer prevents the file USB from claiming to be a keyboard. This is the strong defence. The kernel-argument fallback (`usbhid.quirks`) handles specific known-bad VID:PID combinations when the blocker's HID-blocking can't be confirmed, but it is a list-based defence and cannot block unknown attackers. Without a write blocker, see "BadUSB / HID injection (no blocker)" under residual risks.
- **Persistence between sessions.** No persistent storage. CoreOS boots into RAM, the guest runs from an ephemeral image, the data USB is read-only, power-off clears everything.

## What is not defended against

- **Compromised build station.** Every artefact downstream is trusted on its word. Operational mitigation only (sensitive-system hardening).
- **Supply-chain compromise of upstreams.** ClamAV signatures, LOKI-RS releases, YARA Forge rules, CoreOS, Firecracker, kernel, Debian, TLS to those hosts is the trust root. No checksum pinning.
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
- **Centralised version pinning.** All upstream component versions live in `config/versions.env`, sourced by every script that needs them. Pins fall into three documented categories: PINNED (specific version, deliberate review to bump), FLOATING (tracks upstream `latest`/`stable`, accepted as residual risk), and DERIVED (must match another pin, e.g. the guest kernel CI version must match Firecracker's). Inventory is auditable from a single file.
- **Per-build scanner credential.** The `scanner` user's password is regenerated on each boot-USB build by `prepare-boot-usb.sh` — a fresh four-word diceware passphrase (~51.6 bits of entropy from the EFF Long Wordlist) is hashed with `openssl passwd -6` and substituted into a temporary copy of the Butane config; the committed config carries only the sentinel `@@SCANNER_PASSWORD_HASH@@`. The plaintext is printed to the admin's terminal once at the end of the build and is never written to disk by the build process. The credential's lifetime is bounded by the boot USB's lifetime (which is in turn bounded by the 30-day signature freshness gate), so a long-lived password leak is impossible by construction.

## Residual risks

- **Pattern-based detection only.** Recorded under "what is not defended against" above. Most consequential current limitation.
- **Closed-source-adjacent components in the trust path.** LOKI-RS is open-source (GPLv3), but its default rule corpus (YARA Forge) is curated externally and scanned only as opaque rule files. A compromised rule release would propagate at next update.
- **Unpinned upstream artefacts.** Currently three components float by design (Butane, coreos-installer image tag, CoreOS stable stream); the rest are pinned in `config/versions.env`. None of the downloads are checksum-verified against published `.sha256` sidecars or signed manifests. Probability low, impact high. Adding SHA-256 verification alongside the existing pins is the planned next iteration; the central config makes this a single-file change.
- **Floating upstream channels.** `BUTANE_VERSION="latest"`, `COREOS_INSTALLER_TAG="release"`, and `COREOS_STREAM="stable"` are all moving targets. A compromise of any of these upstream tags would propagate at the next build-station run. Accepted because the alternatives (manually tracking and bumping each) significantly increase admin toil for components whose interfaces are stable.
- **Guest rootfs Debian release pinned to trixie.** Trixie was selected over bookworm because LOKI-RS v2.10.0 requires glibc 2.39+ and bookworm ships 2.36. Trixie is currently in freeze leading up to its release as Debian 13; this is acceptable for a build-station target that is itself rebuilt on every signature update, but should be re-confirmed when trixie reaches stable.
- **LOKI-RS scan-time defaults overridden.** `--max-file-size 0` disables the 64 MB default that would otherwise silently skip large files (a false-negative vector for a transfer scanner). `--scan-all-files` overrides the default extension-based filtering, since adversarial input cannot be trusted to declare its own type. Both deviations are deliberate; they trade scan time for coverage.
- **No measured boot.** A physical attacker swapping firmware or USBs is not detected. Mitigated by physical security of the room and labelled USBs.
- **BadUSB / HID injection (no blocker).** Without a hardware write blocker on the file USB port, a malicious file USB can claim to be a keyboard (HID device class) and inject keystrokes during the window between physical insertion and any software-level HID rejection. The kernel-argument `usbhid.quirks` defence is list-based and cannot block unknown VID:PID combinations. Consequences are bounded by structural properties: the scanning host has no network, leaves no persistent state, and clears RAM at power-off — so an attacker gaining a keyboard cannot exfiltrate or persist. The realistic worst case is forging a green verdict during the active session, leading the operator to transfer malware. Mitigations available without the blocker: tighter kernel-level HID defence (e.g. `modprobe.blacklist=usbhid hid-generic` in CoreOS boot args, accepting that no keyboard input is possible after login) or a userspace USB-allowlist daemon. The system is operable without a blocker but the attack surface is meaningfully wider.
- **HID input via non-blocked ports.** The data and LiveOS USB ports cannot be behind the write blocker (they need to be writeable). Mitigated by physical control and operator training.
- **Trust in CoreOS signing.** Compromise of the signing keys would produce a tampered scanning host. Accepted as a property of using the upstream.
- **AV false negatives.** Structural. Green is "no signature or rule matched", not "guaranteed clean".
- **Scan-time resource exhaustion.** No scan timeout. A zip bomb OOMs the guest, producing yellow, correct but inefficient. Adding a host-side timeout is a candidate improvement. The two-engine design now compounds this: both engines walk the same tree sequentially, so total scan time is roughly additive.