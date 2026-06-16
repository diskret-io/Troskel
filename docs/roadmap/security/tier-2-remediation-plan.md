# Tier 2 readiness: remediation plan

This document is the remediation programme required to bring Troskel to a state suitable for Tier 2 adoption (mid-market enterprise, important but non-critical functions, ISO/IEC 27001:2022 baseline). 

Each item is justified from the artefact as it stands, cites the location of the defect or omission, and states the evidence on which the recommendation rests. 

Tier 3 (regulated critical infrastructure under IEC 62443 and NIS2) is held out as a separate horizon, addressed in a closing section but not committed to here.

---

## Posture summary

Troskel’s architectural premise is sound: a stateless CoreOS host that boots from removable media into RAM, hands a freshly built ext4 image into a Firecracker microVM over a one-way text serial channel, and produces a colour-coded verdict from two signature-based engines (ClamAV and LOKI-RS) running inside the guest. 

The trust boundary the system intends is host-untrusts-guest, guest-untrusts-media. That boundary is not yet fully realised.

Two architectural defects sit above the rest in materiality. 

**First**, the scanning host mounts attacker-controlled filesystems using its own kernel filesystem drivers before any virtualisation boundary is crossed, which inverts the project’s own stated assumption that parser surfaces should be regarded as exploitable. 

**Second**, the verdict-detection logic on the host parses untrusted guest output with substring matching over the entire scan log, with no grammar, no neutralisation of terminal control sequences, and no constraint that a `VERDICT:` token appear on its own line. This means that the guest, which the project elsewhere assumes to be potentially compromised, can in principle produce a misleading green verdict by emitting the right substring anywhere in its output, including embedded in a filename in a ClamAV finding or a rule field in a LOKI-RS alert.

Around these sit a cluster of secondary issues: hotplug-based device auto-selection, an operator account in `wheel` with no scoped sudoers rules, the absence of any cryptographic freshness anchor against rollback of the TROSKEL-DATA medium, the absence of a signed scan certificate or any tamper-evident output, and a build pipeline that relies on developer-workstation trust without signed provenance over its outputs. Each is tractable; the combination is what currently keeps the artefact below Tier 2.

The Tier 2 deltas are bounded. The work below is sequenced into three phases over an estimated eight to twelve weeks of focused effort, with the first phase containing the items without which Tier 2 cannot be claimed.

---

## Phase 1 — blockers for Tier 2 readiness

Items in this phase address defects that an informed external reviewer would identify within a single reading. None may be deferred and called Tier 2.

### Mount untrusted media inside the guest, not on the host
See [ingest-vm.md](../ingest-vm.md).

The host script `config/host-scripts/troskel` invokes `mount -o ro` against an operator-supplied block device using the host kernel’s autodetected filesystem driver. The contents are then walked by `mkfs.ext4 -F -d` inside `scan-wrap` to construct a fresh ext4 image which is handed to the Firecracker guest as a read-only block device. The vulnerable surface is the host-side mount: a malicious ext4, exFAT, or NTFS image can target the corresponding in-kernel driver before any virtualisation boundary is crossed. CoreOS’s minimal attack surface does not help here, because the surface in question is the file-system driver subsystem in the host kernel, which is exercised against attacker-chosen input on every scan.

The correct architecture is the one the rest of the system already commits to: present the raw block device into a Firecracker ingest VM and mount inside the guest. The mount’s failure mode then becomes a guest fault, not a host fault, and is contained by the same hardware-virtualisation boundary the project already relies on for parser exploits. CWE-1188 (insecure default initialisation of resource); the underlying defect is misplaced trust in kernel drivers parsing hostile input. CVSS:4.0/AV:P/AC:L/AT:P/PR:N/UI:P/VC:H/VI:H/VA:H/SC:H/SI:H/SA:H — score 7.4 (High).

Interim mitigation, while the architectural change is in progress: restrict accepted filesystems to ext4 and FAT32 by explicit `-t` argument with no autodetection, mount with `nodev,nosuid,noexec,ro`, use a dedicated mount namespace, open all paths with `O_NOFOLLOW`, refuse any file whose type is not regular file or directory, and refuse to proceed if the medium contains nested mountpoints. NTFS and exFAT support must be removed entirely from the supported-formats list, both from `troskel` and from operator documentation. The interim takes two to four working days; the architectural fix one to two weeks.

### Constrain and seal the verdict channel grammar
See [verdict-grammar.md](../verdict-grammar.md).

The host parses guest output with substring searches against the entire serial log. The relevant lines from `config/host-scripts/scan-wrap` are `grep -q "VERDICT: THREAT DETECTED"` and `grep -q "VERDICT: CLEAN"`. These are global substring matches: any occurrence of those exact bytes anywhere in the log, including inside a filename that ClamAV reports as `FOUND` or inside a rule name in a LOKI-RS JSONL alert, satisfies the test. The order of detection is THREAT-then-CLEAN, so a hostile guest that emits a string containing `VERDICT: THREAT DETECTED` will produce a red verdict regardless of intent, and one that emits *only* a string containing `VERDICT: CLEAN` will produce green. Combined with the fact that the guest is — by the project’s own architectural reasoning — assumed potentially exploitable, this turns the verdict channel into a forgeable surface.

A second defect attaches to the same parser: `show_findings` and `summarise_engine` feed untrusted guest output through `printf "    %s\n"` to the operator’s terminal. Neither path neutralises ANSI escape sequences. A guest that emits cursor-positioning, colour-reset, or screen-clearing escapes can rewrite the visual presentation of the verdict block after `scan-wrap` has printed it — for example, replacing the red banner with a green one, or scrolling the genuine verdict out of view and pinning a forged one. The operator’s eye on the screen is the final verification step; that channel must be presumed addressable.

The remediation has three parts. First, define a sealed verdict grammar: a single line of the form `VERDICT: <token>` where `<token>` is drawn from a fixed alphabet (`CLEAN`, `THREAT_DETECTED`, `ERROR`), the line is delimited by literal start-of-line and end-of-line markers, and only one such line per engine is permitted. The host’s parser matches against this grammar exclusively, on a line-by-line basis with anchored regular expressions, and aborts to yellow on any ambiguity. Second, neutralise the display path: all text emitted by the guest that may reach the operator’s terminal must pass through a sanitiser that strips or escapes the C0 and C1 control characters and the CSI sequences. Third, decouple the verdict signal from the descriptive text: the verdict is read from a dedicated single-purpose channel (a second serial device, or a fixed-format header line) that contains no engine-emitted descriptive content; descriptive content remains free-form but is treated only as advisory and is sanitised before display.

CWE-20 (improper input validation), CWE-150 (improper neutralisation of escape, meta, or control sequences), CWE-451 (user interface misrepresentation of critical information). CVSS:4.0/AV:L/AC:L/AT:P/PR:N/UI:P/VC:N/VI:H/VA:N/SC:N/SI:H/SA:N — score 5.4 (Medium); rated Medium rather than High because exploitation requires the guest to be already compromised, which is the threat model’s explicit non-default state, but treated as a Phase 1 blocker because once the host-mount issue is addressed this becomes the principal post-Firecracker channel through which a compromised guest influences the operator.

Effort: three to five working days, the bulk of which is in the guest-side grammar discipline and the host-side sanitiser.

### Remove implicit privilege from the operator account

`config/scanner-host.bu` defines the `scanner` user with `groups: [kvm, wheel]`. The `wheel` membership grants sudo to a root shell on the scanning host. CoreOS’s defence-in-depth posture — stateless, no persistent storage, no network — bounds the blast radius of any host-side compromise to the session, but does not eliminate the relevance of in-session privilege: a credential-injecting HID device, an exploit of the host-side mount path before that path is remediated, or any compromise of the host-side scripts can be amplified to full root by virtue of the `wheel` membership. The operator workflow as documented requires elevated privilege only for `mount`, the Firecracker invocation in `scan-wrap`, and `poweroff`. None of these requires unrestricted sudo.

The remediation is to remove `wheel` from the `scanner` user’s group list and to replace the privileged operations with narrowly scoped systemd units invoked through `systemd-run` or polkit rules, parameterised over the specific operations required (mount a USB device by major:minor at a fixed path with fixed options; launch Firecracker with a fixed configuration; initiate a clean shutdown). The principle is that the operator account is incapable of executing any command not explicitly enumerated.

This change must be made in conjunction with the BadUSB mitigation below; a `wheel`-less account that nevertheless accepts injected keystrokes does not solve the problem the change is intended to solve, because the keystrokes can drive whatever the account *is* permitted to do, and an enlarged set of permitted operations expands what an injected stream can achieve.

CWE-250 (execution with unnecessary privileges), CWE-269 (improper privilege management). CVSS:4.0/AV:L/AC:L/AT:N/PR:L/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N — score 7.3 (High); exploitation requires existing footing on the host (HID injection, mount-path compromise, or media-mediated guest escape) but the amplification from that footing to full session compromise is what this finding addresses.

Effort: two to three working days, dominated by writing and testing the polkit rules and systemd units.

### Mitigate HID injection from the file medium

The artefact’s threat model presumes USB media as a primary attack surface but addresses only storage-class threats. A removable USB device that presents itself as a Human Interface Device — a keyboard, a composite keyboard+storage device, or a programmable microcontroller emulating one — can inject keystrokes into the active terminal session. With the operator logged in as `scanner` and a shell available, injected keystrokes are executed in that account’s context. This is the BadUSB family of attacks; it is well-documented, the hardware is commodity, and it is among the most realistic real-world threats to an air-gap transfer workflow because the same human-mediated workflow that makes the air-gap necessary is the workflow the attack rides.

Two mitigations are appropriate and complementary. The base layer is to deny HID class devices at the kernel level: setting `usbcore.authorized_default=0` in the boot arguments emitted by `config/scanner-host.bu` causes the kernel to refuse to authorise newly attached USB devices, leaving only those explicitly enabled. A udev rule, scoped narrowly, then authorises storage-class devices while leaving HID, networking, and audio devices unauthorised. The base layer denies the class entirely; the second layer, USBGuard, refines the policy by allowing a per-device allowlist if site policy requires it. For Tier 2 the base layer alone is sufficient if HID is genuinely unnecessary on the scanning host — and it is, because the keyboard the operator uses is a fixed device known to the host configuration and can be allowlisted by serial number at build time.

The `troskel` and operator-guide content must be updated to reflect that only the explicitly allowlisted keyboard works; an operator who reaches the host without that keyboard fails closed and contacts the admin.

CWE-1191 (on-chip debug and test interface with improper access control) is the nearest formal mapping, though the structural defect is the absence of class-level authorisation by default. CVSS:4.0/AV:P/AC:L/AT:N/PR:N/UI:P/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N — score 7.0 (High). Attack vector is Physical because the attacker must physically present the device; user interaction is Present because the operator must insert it; impact is High across confidentiality, integrity, and availability of the session.

Effort: one to two working days for the base layer and udev rule; allowlist work an additional one to two days depending on whether per-host serial-number allowlisting is adopted.

### Remove hotplug-order device selection
See [ingest-vm.md](../ingest-vm.md).

`config/host-scripts/troskel` selects the scan device with `lsblk -dpno NAME,HOTPLUG | awk '$2==1{print $1}' | tail -1`, i.e. the most recently hotplugged USB device. This is attacker-influenceable: an attacker who can present additional USB devices — a second stick during the workflow, a HID-storage composite, or a device that disconnects and reconnects rapidly — can manipulate which device is scanned. The operator guide already acknowledges this implicitly by advising the operator to plug in only the file USB, which is a documentation-displaced workload that the secure-by-default principle requires the artefact to absorb itself.

The remediation is to require explicit operator confirmation of the device. `troskel` should enumerate every connected removable USB block device and display, per device, the kernel name, vendor and product identifiers, serial number, capacity, and label, and require the operator to type or select the device. If more than one removable USB device is present and no selection has been made, the script refuses to proceed. The TROSKEL-DATA medium, having been unmounted by `load-scanner` at boot, is already excluded from the candidate list — that exclusion must be made explicit in the enumeration rather than incidental.

CWE-732 (incorrect permission assignment for critical resource) does not quite fit; the closer mapping is CWE-345 (insufficient verification of data authenticity) applied at the device-selection layer. CVSS:4.0/AV:P/AC:L/AT:P/PR:N/UI:P/VC:N/VI:H/VA:N/SC:N/SI:H/SA:N — score 5.3 (Medium); the impact is integrity of the scan workflow rather than direct compromise.

Effort: one to two working days, including the operator-guide update.

### Anchor TROSKEL-DATA against substitution and rollback

The data USB carries `scanner-rootfs.ext4`, the guest kernel, signature dates, the operational tunables, and a SHA-256 file. The SHA-256 is co-resident on the same medium, which makes it useful only against bit-rot, not against substitution: an attacker who can present a substituted TROSKEL-DATA can also present a matching SHA-256. The boot USB is verified by the Fedora signing key embedded in coreos-installer, but the boot USB does not, today, anchor the data USB.

This is the principal supply-chain-of-evidence defect on the deployment side. For Tier 2 the construction is: at build time, the admin’s signing key signs a manifest that enumerates every file on TROSKEL-DATA together with its SHA-256 and a monotonic build counter. The corresponding public key (or a hash of it) is embedded in `config/scanner-host.bu` and therefore baked into the Ignition configuration on the boot ISO, making it available to the host at first boot. `load-scanner` verifies the manifest signature against the embedded key before copying any artefact from the medium; on failure, the host refuses to load the scanner and reports the failure to the operator.

Against rollback specifically, the host must record the highest build counter it has seen previously. The CoreOS host has no persistent storage by design, so the counter must be anchored on the boot USB itself in a write-once region, or — more practically — the freshness check is operator-mediated: the host displays the build counter and date prominently at boot, and the operator-facing show-status output makes a previously-seen-newer-data state visible. A fuller anti-replay construction requires a TPM-backed counter or operator-mediated freshness, which is properly a Tier 3 commitment; the Tier 2 commitment is signature verification of the medium’s contents, monotonic counter display, and operator-visible freshness state.

CWE-345 (insufficient verification of data authenticity), CWE-294 (authentication bypass by capture-replay) at the freshness layer. CVSS:4.0/AV:P/AC:H/AT:P/PR:N/UI:P/VC:H/VI:H/VA:H/SC:H/SI:H/SA:H — score 6.6 (Medium-High); attack complexity is High because the attacker must produce a substitute medium, attack requirements are Present because physical access to the medium-handling workflow is needed, but the impact upon success is total compromise of the integrity of every scan thereafter.

Effort: four to seven working days for the signing, embedding, and verification logic, plus the operator-guide changes.

### Signed scan certificate, key off the scanning host

A scan’s value to a downstream party rests on the integrity of the verdict as evidence. Today the verdict exists only on the operator’s screen and in `/var/log/troskel/scan-*.log`, both of which are tied to the live session and are lost at reboot. There is no signed artefact that the operator carries off with the file USB to attest that a scan was performed, what it found, against what signatures, on what host, and at what time.

For Tier 2, the scan must produce a signed certificate written to an output USB, with the signature performed off the scanning host. The scanning host writes the unsigned certificate together with a manifest of the file USB’s contents (paths, SHA-256s) and the scan-relevant metadata (verdict, engine outputs, signature and rule dates, build manifest fields) to the output USB. The admin, on the build station, retrieves the output USB, verifies the manifest, and GPG-signs the certificate using a key that never touches the scanning host. The signed certificate is returned to the output USB before the medium leaves the build-station enclave.

The defect of this construction is the temporal gap between scan and signature: a window exists between scan completion and admin signing during which the certificate is not yet authenticated. The mitigating consideration is that the alternative — embedding the signing key into the guest — places the signing material on the scanning host and inside the guest, both of which the threat model treats as potentially compromised. The temporal gap is acceptable for Tier 2; an alternative construction with the signing key inside a hardware token attached to the scanning host is a Tier 3 horizon.

The certificate, signed or not, must include the build manifest’s commit identifier and dirty-tree flag, the resolved upstream versions, the signature and YARA-rules dates, the verdict, and a hash chain over the per-file findings.

CWE-345 (insufficient verification of data authenticity); the absence of a signed certificate is a defect of construction rather than a vulnerability strictly construed, but it is the defect that determines whether a downstream party can trust the artefact’s output. No CVSS score is given; severity is judged in terms of fitness-for-purpose rather than exploitability.

Effort: five to seven working days, including the build-station signing tooling and the output-USB preparation path.

### Signed provenance over build outputs

The official artefacts a deploying admin downloads or receives — the project’s release tarballs or repository contents at a tagged commit — currently rest on the security posture of whichever developer cuts the release. There is no signed provenance, no SLSA-style attestation, and no signing over release artefacts, SBOMs, or update manifests. For an artefact whose own marketing rests on operator trust, the build pipeline is part of the trusted computing base; it should be acknowledged as such and engineered for.

For Tier 2 the construction is: release artefacts are produced exclusively from CI/CD; the CI runner is ephemeral and pinned by image digest; GitHub Actions are pinned by commit digest, not by tag; the GitHub token granted to the release workflow is scoped to the minimum required; the SBOM is generated in CI from the resolved versions and signed; release artefacts and the SBOM are signed via Sigstore/cosign; the Git tag is signed; the SLSA provenance statement is emitted in the v1.0 format. Developer workstations are explicitly out of the release trust path; the trust statement that accompanies a release reads, in substance, that developer systems are not trusted for release integrity and that official artefacts are produced only through the attested CI pipeline.

The Tier 2 commitment stops short of in-toto attestation over the full build graph and stops short of reproducible builds; both are Tier 3 horizons. The Tier 2 commitment is signed, attested, single-source-of-truth release artefacts.

Floating dependencies — the `coreos-installer:release` tag in `versions.env`, unsigned Firecracker CI kernels downloaded from S3, the YARA Forge bundle pulled over TLS only — are addressed as part of this work. Each is replaced by a pinned digest, a signed release, or an internal signed mirror. The kernel download in particular requires construction of an internal mirror that re-signs the artefacts under an admin key, because the upstream does not sign the CI kernels.

CWE-494 (download of code without integrity check), CWE-829 (inclusion of functionality from untrusted control sphere) for the floating dependencies. No CVSS scores given; the issue is supply-chain hygiene rather than a single exploitable vulnerability.

Effort: seven to ten working days for the centralised pipeline, signing infrastructure, and pinning of floating dependencies. The Sigstore/cosign integration is the smaller piece; the larger piece is the pipeline restructure.

---

## Phase 2 — readiness hardening

Items in this phase do not block Tier 2 in the sense that an external reviewer would refuse signoff without them, but address issues that a reviewer with operational experience would press on, and that reduce the residual risk surface the Tier 2 verdict carries.

### Read-only re-presentation: harden the host-side image construction

After the Phase 1 host-mount item is addressed and untrusted filesystems are mounted inside the guest, an interim period will remain in which the existing path persists. During and after that transition, `scan-wrap`’s construction of the scan ext4 image (`truncate`, `mkfs.ext4 -F -d "$TARGET_DIR"`) must be hardened against the input it walks. `mkfs.ext4 -d` parses the source tree as a normal filesystem walk; symbolic links, device nodes, sockets, and FIFOs in the source tree are reflected into the constructed image. The host-side trust in this walk is implicit. Each of these node types must be explicitly excluded; the safest construction is to build the scan image by enumerating only regular files and directories, with depth, count, and total-size limits enforced before construction begins, with an explicit failure mode if any limit is reached.

CWE-22 (path traversal), CWE-59 (link following) at the image-construction layer. CVSS:4.0/AV:P/AC:L/AT:P/PR:N/UI:P/VC:N/VI:H/VA:H/SC:N/SI:H/SA:N — score 4.6 (Medium).

Effort: three to four working days.

### Resource-exhaustion discipline on the guest

The guest is configured with 2048 MiB of memory and 2 vCPUs by default, with `SCAN_IMG_SIZE` defaulting to 4 GiB. Decompression bombs, archive amplification, and pathological YARA inputs are realistic threats; the documented test posture handles `42.zip` correctly (red or yellow, never green), but this is one case rather than a discipline. For Tier 2 the engines must run with explicit limits, both as ClamAV options (which are already partially configured per the project’s comments about `--alert-encrypted-archive` and similar) and as cgroup-enforced memory and CPU limits inside the guest. The guest’s OOM behaviour is currently the verdict-pipeline’s yellow-path safety net; that is acceptable as a backstop but is not a discipline.

The test posture should be expanded to cover the principal amplification classes — zip bombs at multiple depths, billion-laughs-style XML, polyglot files that present as one type to one engine and another to the other, malformed archives whose central directory disagrees with their content stream — and the expected verdict for each must be a defined outcome (red on detection, yellow on engine failure, never green).

CWE-400 (uncontrolled resource consumption), CWE-674 (uncontrolled recursion). CVSS:4.0/AV:P/AC:L/AT:P/PR:N/UI:P/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N — score 2.3 (Low) for the availability impact considered in isolation; the importance of the item is in closing a class of false-green pathways rather than in the availability impact itself.

Effort: three to five working days, including the test fixtures.

### Build-time `--privileged` discipline

The build container is invoked with `--privileged` for debootstrap and `mkfs.ext4`. Once the CI pipeline becomes the trust anchor under the Phase 1 provenance work, the build container is the single most privileged process in the trusted computing base. `--privileged` is broader than needed: the operations require, specifically, `CAP_SYS_ADMIN` for mount operations and access to the loop device for image construction. The remediation is to replace `--privileged` with a minimal capability set and explicit device exposure (`--cap-add=SYS_ADMIN --device=/dev/loop-control`, with the loop devices created and bound inside the container’s namespace). This reduces the blast radius of a CI runner compromise without changing the build’s functional behaviour.

The runtime-host privileged execution path (root on the scanning host) is a separate matter and is largely defensible: the host is stateless, RAM-resident, networkless, and reboots cleanly. The Tier 2 commitment for the runtime side is the operator-account scoping addressed in Phase 1; further reduction of root scope on the host is a Tier 3 consideration.

CWE-250 (execution with unnecessary privileges) at the build-container layer. CVSS:4.0/AV:L/AC:L/AT:N/PR:H/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N — score 5.4 (Medium); exploitation requires existing footing on the CI runner.

Effort: two to four working days.

### Forensic posture and tamper-evident logging

The scanning host’s scan logs live in `/var/log/troskel/` in tmpfs and are lost at reboot. The operator-guide instructs the operator to photograph the screen on a yellow or red verdict, which is a workable but unhardened evidence path. For Tier 2 the output USB introduced in Phase 1 should also carry, on every scan regardless of verdict, the full scan log, the per-engine outputs, and the build manifest, all under the same signature as the certificate. This makes the output USB the authoritative incident artefact for any scan whose handling later becomes consequential. The host-side log is then operationally useful in-session but not the authoritative record.

CWE-778 (insufficient logging), CWE-693 (protection mechanism failure) at the forensic-evidence layer. No CVSS score; this is a fitness-for-purpose item.

Effort: two to three working days, building on the certificate work in Phase 1.

### Reverse-direction discipline on the file medium

The file USB enters the scanning host, is mounted read-only, has its contents walked into a guest-side image, and is unmounted. The mount is read-only and `umount` is honoured, so under correct host behaviour there is no write path back to the medium. Under compromised host behaviour — which the threat model does treat as possible — there is no architectural barrier to the host writing to the medium between mount and umount. The Tier 2 commitment is to make the medium’s integrity verifiable after the scan: the host computes and emits, into the signed certificate, a SHA-256 of the file USB’s partition table and a manifest hash over its contents at mount time. A subsequent comparison at the IT side, on the operator’s return, can detect any divergence introduced during the scan. This does not prevent reverse-direction exfiltration, but makes it detectable, which raises the bar from undetectable to forensically visible.

CWE-200 (exposure of sensitive information to an unauthorised actor), considered against the reverse channel. CVSS:4.0/AV:P/AC:H/AT:P/PR:N/UI:P/VC:H/VI:N/VA:N/SC:H/SI:N/SA:N — score 3.5 (Low); the threat is contingent on host compromise, which is itself constrained by other Phase 1 work.

Effort: two to three working days.

---

## Phase 3 — Tier 3 horizon (not committed in this plan)

The items below are recorded for completeness and to make explicit what Tier 2 readiness does *not* claim. They are the substance of any Tier 3 commitment (regulated critical infrastructure under IEC 62443 and NIS2) but are not promised here.

Reproducible builds of the guest rootfs are the highest-value Tier 3 item: a bit-for-bit reproducible debootstrap with deterministic timestamps and ordering would close the residual supply-chain gap that signed-but-not-reproducible artefacts leave. 

The host ISO is a secondary target because it is largely unmodified CoreOS plus an Ignition embed; the rootfs is where reproducibility delivers proportionate value. In-toto attestations over the full build graph extend the SLSA-style provenance of Phase 1 from outputs-only to inputs-and-process. 

Hardware-backed release signing — an offline signing workstation or a hardware security module holding the release key — moves the build-station GPG key out of the file-system-resident trust path.

Per-engine isolation, with each engine in its own Firecracker microVM, is on the project’s existing roadmap and addresses the within-guest cross-engine concern that the current single-VM design accepts. 

A TPM-backed monotonic counter on the scanning host, anchored across boots, would convert the operator-mediated freshness check of Phase 1 into a cryptographically enforced anti-rollback. 

A structured verdict-grammar implementation in a memory-safe language — Rust on the host side, replacing the relevant shell parsing in `scan-wrap` — would compound the grammar-discipline work of Phase 1 with implementation-language safety; this is worth doing for clarity but not for memory safety per se, since the host-side defects are not memory-safety defects.

Disposable microVM-based build stages for the most sensitive workflows (signing, release packaging) close the build-time compromise-amplification surface.

---

## Residual risk under Tier 2

Even after this plan is executed, the artefact carries residual risks that the Tier 2 verdict acknowledges rather than eliminates.

Signature-based scanning does not detect novel malware; this is inherent to the engines, not to Troskel. 

The guest is hardware-virtualised against the host but the guest kernel itself is a Linux kernel with its own exposure to crafted block-device content; the per-engine isolation on the Tier 3 horizon reduces the within-guest cross-engine surface but does not eliminate the guest kernel’s own exposure. 

The operator workflow remains human-mediated and remains the boundary across which most realistic compromise traverses; the Phase 1 items reduce the operator’s latitude for foreseeable misuse but cannot eliminate it. 

The build-station compromise pathway is bounded by the Phase 1 provenance work to "compromise produces detectable artefacts" rather than "compromise is undetectable", but is not bounded to "compromise is impossible".

These are the items a Tier 2 deployment must understand it is accepting.