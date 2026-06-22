---
id: "sign-data-usb-manifest-2026-06-19"
status: "in-progress"
priority: "high"
assignee: "k"
epic: "tier-2-remediation-plan-2026-06-17"
dueDate: null
created: "2026-06-19T00:00:00.000Z"
modified: "2026-06-21T13:28:27.269Z"
completedAt: null
labels: ["security", "authenticity", "verification", "host"]
order: "a0"
---
# Sign the data-USB manifest so the air-gapped host can verify authenticity

Troskel verifies the integrity of its own artefacts (a SHA-256 sidecar,
soon checked on the host too) but never their authenticity. Integrity
answers "did the bytes change?"; authenticity answers "did these bytes
come from my build station?". A hash cannot answer the second question:
an attacker who can present a substituted TROSKEL-DATA medium can also
present a matching SHA-256, because the hash is co-resident on the same
medium and recomputable over any file. This card adds the missing
property by signing a manifest of the medium's contents with a key the
attacker does not have, and verifying that signature on the host before
the scanner image is loaded or run.

This is the first concrete slice of the Tier 2 construction already
described in docs/roadmap/security/tier-2-remediation-plan.md (section
"Anchor TROSKEL-DATA against substitution and rollback"). It is carved
out as its own card because it is the single change that most directly
underwrites Troskel's central claim, and because the surrounding Tier 2
epic is currently backlog/low, which understates it.

## Motivation

Troskel exists to be trusted in an environment that is not. The air gap
defends against exfiltration and remote compromise, but it does nothing
against physical substitution of the medium that carries the executable
scanner image across the gap. The current model implicitly trusts the
transport: it assumes the USB that arrives is the USB that left. Every
other trust decision the host makes is already signature-based, the boot
ISO is verified against the Fedora signing key embedded in
coreos-installer, and upstream inputs are GPG- or hash-pinned at
download. The host's own scanner image is the one executable thing it
trusts on the basis of an unsigned, self-co-resident hash. That is the
gap.

Relationship to the verification work just completed:
- scripts/lib/verify-artefact.sh and the load-scanner-verify-rootfs card
  perfect INTEGRITY: bytes intact, end to end including the host hop.
  They are necessary and nearly done, but they are silent on
  authenticity. They are rung 0 -> rung 1 on the integrity/authenticity
  ladder.
- This card is rung 2/3: AUTHENTICITY over the medium's contents, via a
  detached signature whose private half is held by the admin (see the
  private-key tiers below for where) and whose public half is baked into 
  the host image. It composes with the integrity work rather than replacing 
  it: the signed manifest carries the per-file SHA-256s, the host verifies 
  the signature once, then trusts and checks those hashes with the 
  existing module.

Why not heavier supply-chain machinery (Sigstore/cosign with a
transparency log, a TUF repository): those solve key distribution and
revocation at internet scale with online infrastructure. An air-gapped,
single-signer, single-verifier system has none of those problems, and
adding that machinery would introduce an online dependency to a
deliberately offline system. Plain detached signatures with a manually
distributed public key are the correct primitive precisely because the
air gap removes the problems the heavier tools exist to solve.

## Current state

- build-manifest.json already records the raw material for a provenance
  manifest: troskel_commit, troskel_dirty, generated_at, the resolved
  upstream input versions, and SHA-256s for the rootfs and kernel
  (generate-build-records.sh). It is unsigned: a claim, not a proof.
- prepare-data-usb.sh writes the rootfs, its sidecar, the kernel,
  signature dates, scanner.env, and build-manifest.json to TROSKEL-DATA,
  and verifies the rootfs and manifest against the medium at write time.
  Nothing is signed.
- load-scanner copies artefacts from the medium with no signature check
  (and, until the load-scanner-verify-rootfs card lands, no hash check on
  the host either).
- config/scanner-host.bu compiles into the Ignition config baked into the
  boot ISO. This is the natural place to embed the verifying public key
  (or a hash of it), so it is present at first boot with no network.
- The tier-2 plan specifies the construction in full, including the
  monotonic build counter and the rollback nuance; this card implements
  the signing-and-verification core of it.

## Target state

At build time, the admin's signing key signs a manifest enumerating every
file written to TROSKEL-DATA together with its SHA-256 (reuse the existing
build-manifest.json content, or a signed superset of it, rather than
inventing a second manifest). The private key's location is the admin's
choice across three documented tiers (docs/medium-authenticity-contract.md,
Private-key handling tiers): minimum is a keyfile on the build station, which
defends against a substituted medium but not against a compromised build
station; better is a separate offline machine; strongest is a hardware token.
The Tier 2 posture this card sits under assumes the off-host tiers; the shipped
gate supports all three without code change, because the signer takes the key
path as an argument. The signing step is a deliberate, operator-mediated action.

The verifying public key (or its hash) is embedded in
config/scanner-host.bu and therefore baked into the boot ISO's Ignition
configuration. load-scanner verifies the manifest signature against the
embedded key BEFORE copying or trusting any artefact from the medium. On
signature failure the host refuses to load the scanner and reports the
failure to the operator. Once the signature is verified, the per-file
hashes in the manifest are trusted, and each artefact is checked against
its hash using the existing verify-artefact module (the integrity layer).

This gives the host a single signature verification that underwrites the
authenticity of the entire medium, then integrity checks against the
now-trusted hashes, covering the rootfs and the kernel together (which
also resolves the "kernel is copied unverified" open question on the
load-scanner card, because the kernel hash is just another signed line).

## Implementation outline

- Choose the signature primitive. Options: GPG detached signature
  (consistent with the existing Butane/Fedora GPG path the project
  already uses and documents), or a minimal ed25519 signature via a small
  tool. GPG is the lower-surprise choice given the codebase already
  performs and documents GPG verification; decide in the open questions.
- Build-station signing step: after prepare-data-usb.sh writes the
  medium, sign the manifest with the offline key and write the detached
  signature to the medium. This must be a separate, explicit step (the
  key is offline), not folded silently into the write path. Consider a
  dedicated script (e.g. scripts/sign-data-usb.sh) the admin runs with
  the token attached.
- Embed the public key in config/scanner-host.bu so it lands in the
  Ignition config on the boot ISO. Document the key-rotation procedure
  (new boot ISO required to change the key, which is acceptable and
  arguably desirable for an air-gapped root of trust).
- Host verification in load-scanner: verify the detached signature
  against the embedded public key before any artefact is copied. On
  failure, abort and report. On success, proceed to the per-file hash
  checks (the integrity layer).
- Keep the manifest content stable and documented as a signed contract:
  the set of files and the hash algorithm are now part of a
  cross-boundary, cross-trust protocol and must have a contract comment
  at producer (sign step) and consumer (load-scanner) naming each other.

## Side effects

- Key management becomes a real operational responsibility: a lost
  private key means no new media can be signed (recoverable: generate a
  new keypair, cut a new boot ISO); a compromised private key means an
  attacker can forge media (the reason the key must stay offline). State
  the key-handling procedure in the operator guide.
- A medium signed under an old key fails verification on a host carrying
  a new key, and vice versa. This is correct behaviour but must be a
  clear operator-facing message, not an opaque failure.
- Pre-signing media (written before this lands) will not verify. Decide
  whether the host rejects them outright or supports an explicit,
  logged "unsigned medium" override for migration. Default should be
  reject; an override, if any, must be loud and deliberate.
- Rollback/replay (presenting an older but validly signed medium) is NOT
  closed by signature verification alone. The tier-2 plan scopes the
  monotonic-counter / operator-mediated freshness response separately;
  this card should display the build counter and date prominently and
  leave the anti-replay enforcement to its own follow-up, noting the
  boundary explicitly so it is not mistaken for solved.

## Failure modes to handle (per QUALITY.md)

- The signature check must be able to fail observably: a test in which
  the manifest is altered after signing, or signed by the wrong key, must
  make load-scanner refuse to load and exit non-zero. A check that cannot
  distinguish a valid signature from an invalid one is decorative, and
  for an authenticity gate that is the whole ballgame.
- Verify the signature BEFORE trusting any hash in the manifest. If the
  host hashes and trusts artefacts first and checks the signature later
  (or not at all on some path), the signature is ornamental. Order is
  load-bearing: signature, then hashes, then load.
- No `|| true` anywhere on the verification path. An authenticity failure
  is fatal by design.
- The embedded public key must be the one actually compiled into the
  running Ignition config, not a copy that can drift. Add a check (build
  or boot time) that the key the host verifies against is the key in
  scanner-host.bu, so a key updated in source but not re-baked into the
  ISO is caught rather than silently verifying against a stale key.

## Estimated effort

Four to seven working days (matching the tier-2 plan's estimate for the
signing, embedding, and verification logic), plus operator-guide changes
for key handling. The signing and verification code is the smaller part;
the key-management procedure and the boot-ISO embedding path are where
the care goes.

## Sequencing

High priority, and arguably the highest-value security work outstanding:
it is the property that most directly supports Troskel's reason to exist.
Sequence it AFTER load-scanner-verify-rootfs (the integrity layer it
builds on) so the host already has the hash-checking machinery this card
extends with a signature gate. It belongs to the tier-2-remediation-plan
epic; raising that epic above backlog/low is part of acting on this card.

## Open questions

1. GPG detached signature vs minimal ed25519. GPG matches the project's
   existing verification idiom and needs no new tooling on the host if
   gpg is present in the CoreOS image (confirm); ed25519 via a small
   static verifier is simpler cryptographically but adds a tool to the
   host image. Which trades better against the "minimal host image"
   value?
2. Sign build-manifest.json directly, or sign a dedicated data-USB
   manifest that enumerates every file on the medium (not just the build
   record)? The tier-2 plan describes "every file on TROSKEL-DATA"; the
   existing manifest covers the build record but not necessarily every
   file written. Reconcile: either extend build-manifest.json to
   enumerate the full medium, or sign a separate medium manifest that
   references the build manifest.
3. Where does the private key live, and how is signing invoked? Hardware
   token (YubiKey-class) is the defensible default for an offline root of
   trust; confirm the operator workflow can accommodate a token at the
   build station and document it.
4. Key rotation cuts a new boot ISO. Confirm this is acceptable
   operationally (it means re-provisioning scanning hosts to rotate the
   root of trust, which is a feature, not a bug, for an air-gapped
   system) and document the procedure.