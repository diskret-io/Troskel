# Identified Security Enhancements

## 1. Eliminate direct mounting of untrusted file USB filesystems on the host

**Priority:** Critical
**Tier 2 blocker:** Yes

### Current issue

The scanning host mounts attacker-controlled filesystems directly using kernel filesystem drivers (`ext4`, `exFAT`, `NTFS`, etc.) before the microVM boundary.

This is the single most dangerous architectural weakness because it bypasses the intended isolation model.

### Why this matters

A malicious filesystem image can exploit:

* kernel filesystem drivers
* mount handling
* path traversal edge cases
* metadata parsing

This compromises the scanning host before Firecracker isolation begins.

For Tier 2, the host must treat the USB as hostile media, not merely “read-only media”.

### Recommended fix

Preferred:

* Present the raw block device directly into a dedicated Firecracker “ingest VM”
* Perform filesystem mounting inside the guest only

Acceptable Tier 2 interim mitigation:

* Restrict supported filesystems to FAT32/ext4 only
* Mount with:

  * `nodev,nosuid,noexec`
  * `ro`
* Disable NTFS and exFAT support entirely
* Use dedicated mount namespaces
* Apply strict symlink handling (`O_NOFOLLOW`)
* Refuse nested mountpoints/special files

### Rough effort

* Interim hardening: **2–4 days**
* Proper architectural fix (guest-only mounting): **1–2 weeks**

---

## 2. Add default BadUSB/HID mitigation

**Priority:** Critical
**Tier 2 blocker:** Yes

### Current issue

BadUSB/HID attacks are acknowledged but not technically mitigated.

The scanner user also has `wheel`, so injected keystrokes can escalate rapidly.

### Why this matters

This is one of the most realistic real-world attack paths for an air-gap transfer workflow.

A malicious USB keyboard can:

* inject shell commands
* alter verdicts
* establish persistence during session runtime
* enable USB networking

This is far more practical than a Firecracker escape.

### Recommended fix

Tier 2 baseline:

* Disable HID by default:

  * `modprobe.blacklist=usbhid`
* Or:

  * `usbcore.authorized_default=0`
  * allowlist only storage-class devices via USBGuard
* Remove `wheel` from scanner operator account
* Replace sudo access with narrowly scoped systemd actions

### Rough effort

* Basic hardening: **1–3 days**
* USBGuard policy refinement/testing: **~1 week**

---

## 3. Remove automatic “last hotplug USB” selection

**Priority:** High
**Tier 2 blocker:** Probably

### Current issue

The scanner chooses the last hotplugged device automatically:

```bash
tail -1
```

This is attacker-influenceable.

### Why this matters

An attacker can:

* reconnect rapidly
* introduce multiple USBs
* socially engineer operators

Result:

* wrong USB scanned
* forged “green” workflow

### Recommended fix

Require explicit operator confirmation.

Display:

* device serial
* vendor
* size
* label

Additionally:

* refuse operation if more than one removable USB exists
* optionally require explicit manual selection

### Rough effort

* **0.5–1 day**

This is low-cost and should be implemented immediately.

---

## 4. Centralize build assurance and add signed provenance

**Priority:** High
**Tier 2 blocker:** Yes

### Current issue

The project currently relies heavily on trust in local developer environments while lacking:

* signed releases
* signed manifests
* signed SBOMs
* cryptographic provenance
* reproducible build guarantees

This creates a weak supply-chain trust model.

### Why this matters

Administrator trust should be placed in:

* a transparent build pipeline,
* signed artefacts,
* reproducible processes,
* and verifiable provenance,

rather than in the security posture of individual developer laptops.

Developer workstations are difficult to standardize and audit. A centralized hardened pipeline is:

* easier to verify,
* easier to document,
* and more realistic operationally.

For a security-sensitive project like Troskel:

> the CI/CD pipeline becomes part of the trusted computing base.

### Recommended fix

Tier 2 baseline:

* Produce official artefacts exclusively through CI/CD
* Generate signed releases via Sigstore/cosign
* Sign:

  * release artefacts
  * Git tags
  * SBOMs
  * update manifests
* Publish signed provenance metadata
* Generate SBOMs only in CI
* Move administrator trust toward:

  * signed provenance
  * immutable build logs
  * deterministic build processes

Strongly recommended:

* ephemeral CI runners
* pinned runner images
* pinned GitHub Actions by digest
* immutable build inputs
* artifact retention policies
* separation of developer and release authority

Tier 3 direction:

* in-toto attestations
* SLSA provenance
* partially reproducible or reproducible builds
* isolated signing workflows
* hardware-backed signing keys

### Operational model

Recommended trust statement:

> “Developer systems are not trusted for release integrity. Official artefacts are produced only through an attested CI pipeline using pinned dependencies, ephemeral runners, signed provenance, and controlled release signing.”

### Rough effort

* Basic signing and provenance: **2–5 days**
* Hardened centralized pipeline: **1–2 weeks**
* Reproducible build maturity: **longer-term Tier 3 effort**

---

## 5. Stop using floating and weakly verified upstream artefacts

**Priority:** High

### Current issue

Several upstreams are insufficiently pinned:

* `coreos-installer` floating tag
* unsigned Firecracker CI kernels
* YARA Forge over TLS only

### Why this matters

This weakens:

* reproducibility
* provenance
* rollback resistance
* build integrity

This is especially important once CI/CD becomes the central trust anchor.

### Recommended fix

* Pin immutable container digests
* Eliminate floating tags
* Use signed release artefacts only
* Maintain internal signed mirror of YARA rules
* Stop downloading unsigned CI kernels from S3
* Introduce `versions.lock`

### Rough effort

* **4–7 days**

---

## 6. Reduce unnecessary privileged execution paths

**Priority:** Medium-High

### Current issue

The project currently relies heavily on:

* `--privileged`
* root-only scripts
* broad host privileges

### Why this matters

This amplifies:

* container breakout impact
* accidental host damage
* CI compromise blast radius

This becomes especially important once the CI pipeline becomes a primary trust anchor.

### Recommended fix

Tier 2 acceptable:

* reduce capabilities incrementally
* separate build and runtime privilege domains
* narrow sudoers permissions
* isolate dangerous operations into dedicated helper containers

Longer-term:

* isolate sensitive build stages into disposable microVMs
* separate signing from build execution
* minimize trusted build components

### Rough effort

* **1–2 weeks**

This is important but can follow the media-boundary fixes.

---

## 7. Harden CI/CD permissions and runner isolation

**Priority:** Medium

### Current issue

* broad GitHub token permissions
* floating `ubuntu-latest`
* incomplete PR validation coverage

### Why this matters

Once centralized build assurance is adopted:

* CI compromise becomes higher impact
* runner integrity becomes critical
* provenance quality depends on pipeline integrity

### Recommended fix

* Pin runner image versions
* Reduce GitHub token permissions
* Use ephemeral runners where possible
* Pin GitHub Actions by digest
* Run Tier 2 validation on pull requests
* Separate:

  * build
  * signing
  * release
  * publication
* Restrict release permissions to dedicated workflows

### Rough effort

* **2–4 days**

---

## 8. Improve anti-rollback and freshness enforcement

**Priority:** Medium

### Current issue

* no anti-rollback
* weak version anchoring
* mutable `versions.env` semantics

### Why this matters

An attacker could reintroduce:

* stale signatures
* vulnerable kernels
* older scanner images

This also weakens provenance assurances.

### Recommended fix

* Monotonic build IDs
* Signed manifests
* Refuse older TROSKEL-DATA versions
* Immutable version-lock workflow
* Tie release manifests to signed provenance metadata

### Rough effort

* **3–5 days**

---

# Recommended implementation order

## Phase 1 — Tier 2 blockers

1. Stop host-side hostile filesystem mounting
2. Add BadUSB/HID mitigation
3. Remove hotplug auto-selection
4. Centralize build assurance and signed provenance

---

## Phase 2 — Tier 2 hardening

5. Remove floating upstream dependencies
6. Harden CI/CD permissions and runner isolation
7. Anti-rollback controls

---

## Phase 3 — Tier 3 maturity

8. Reduce privileged execution
9. Fuzzing/parser hardening
10. Rewriting critical Bash paths in a memory-safe language
11. Reproducible builds
12. Formal attestation chain
13. Offline or hardware-backed release signing
14. Disposable microVM-based build stages for sensitive workflows
