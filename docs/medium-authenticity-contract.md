# Data-USB authenticity gate: behavioural contract

This document is the authoritative specification for how Troskel decides whether to trust the contents of a TROSKEL-DATA medium. It is referenced by name from every script that implements a part of it. If the behaviour here and the behaviour in a script ever disagree, one of them is a bug; this document is the intended design, and the divergence should be resolved rather than left.

Implementing sites:
  - scripts/prepare-boot-usb.sh   (decides host type at boot-build time)
  - config/host-scripts/load-scanner (enforces the gate at data-load time)
  - scripts/sign-data-usb.sh       (produces the signature; optional sign-time guard)
  - scripts/lib/medium-manifest.sh (shared verification primitives)
  - the gen-signing-key make target (produces the keypair)

## What problem this solves

The existing per-file SHA-256 sidecars answer "did these bytes change since they were written?" (integrity). They cannot answer "did these bytes come from the legitimate administrator's build station?" (authenticity). An attacker who can substitute the TROSKEL-DATA medium can also write a matching set of hashes, so integrity alone does not detect substitution. This gate adds authenticity: the
administrator signs the medium's manifest with a private key held only by them, and the scanning host verifies that signature against the administrator's public key, which is baked into the host's boot image. A substituted medium signed by any other key is refused.

## Trust model, in one paragraph

The administrator generates an ed25519 keypair. The PRIVATE half signs media and never needs to enter the repository or the build host (though for a low-threat solo deployment it may; see the tiers below). The PUBLIC half is baked into the host's boot ISO at build time, becoming part of the host's immutable boot-time trust anchor. Because the public key lives in the boot image, changing which key
a host trusts requires rebuilding and re-flashing the boot ISO; this is intentional, as it makes the trust anchor as hard to alter as the act of standing the host up in the first place. There is deliberately no way to update the trusted key on a running host.

## Two artefacts, two enforcement points

The boot ISO is built once and determines whether a host is a SIGNING host (a verifier public key was baked in) or a PERMISSIVE host (none was). The data USB is built and signed separately. The gate's behaviour at load time is the product of the host type and the medium's signature state.

## Host type, decided at boot-build time (prepare-boot-usb.sh)

The build reads the environment variable TROSKEL_SIGN_PUBKEY (a path to the administrator's public key) and the flag TROSKEL_ALLOW_UNSIGNED.

  - Key provided, flag unset      -> bake the key; host is SIGNING. (default path)
  - Flag set, key not provided    -> bake nothing; host is PERMISSIVE; the build
                                     prints a prominent warning that the host
                                     will not enforce medium authenticity.
  - Neither provided              -> ABORT the build, before the ISO download, with
                                     a message explaining how to generate a key
                                     (the gen-signing-key target) and how to opt
                                     out (TROSKEL_ALLOW_UNSIGNED=1). Silence must
                                     never resolve to an unsigned host: that is the
                                     failure mode where an operator believes they
                                     are protected and is not.
  - Both provided                 -> ABORT. Providing a key and asking for unsigned
                                     operation are contradictory; the build refuses
                                     to guess which was meant.

The abort-on-neither and abort-on-both rules exist so that a host's type is always the result of a deliberate choice, never of a forgotten variable.

## Load-time behaviour (load-scanner), full state table

A SIGNING host enforces authenticity. It loads a medium only when ALL hold:
  - a medium manifest and detached signature are present,
  - the signature verifies against the host's baked public key,
  - the set of files on the medium equals the set named in the manifest,
  - every named file matches its recorded SHA-256.
Any failure is fatal and reported with a specific reason:
  - manifest/signature absent      -> refuse: "medium is unsigned; this host
                                       requires signed media." (MISSING_SIGNATURE)
  - signature does not verify       -> refuse: "signature does not match this
                                       host's trusted key." (BAD_SIGNATURE) This is
                                       the substitution attack being refused.
  - manifest malformed              -> refuse (MALFORMED_MANIFEST)
  - file set differs from manifest  -> refuse (SET_MISMATCH): a file was injected
                                       or removed after signing.
  - a file's hash differs           -> refuse (HASH_MISMATCH): a file's contents
                                       were altered after signing.

A PERMISSIVE host cannot verify authenticity (it has no key) and says so on every load, without exception, so that the operator is never unaware that enforcement is off. It then does what it still can:
  - medium is signed   -> verify set-equality and per-file hashes (integrity,
                          which need no key) and refuse on an integrity failure,
                          while stating clearly that authenticity could not be
                          verified because the host holds no key. Loads only if the
                          integrity checks pass.
  - medium is unsigned -> load, and say so.

A PERMISSIVE host cannot, by construction, detect the substitution attack: an attacker's correctly-signed medium and the administrator's are indistinguishable to a host with no key. This is the definition of opting out, not a weakness in the opt-out path, and it must be documented as such. A permissive host offers integrity assurance only, never authenticity.

## Signing behaviour (sign-data-usb.sh)

The signer always:
  - builds the medium manifest from the medium's ACTUAL contents (re-read from the
    medium, never from the source directory), so the signed claim describes what is
    really on the stick,
  - signs the manifest with the administrator's offline private key,
  - re-verifies the signature and the file set against the medium copy before
    declaring success, deleting both artefacts on any post-condition failure so a
    half-signed medium never ships.

The signer optionally, when given the host's public key (an extra argument):
  - confirms the signing private key corresponds to that public key, and REFUSES to
    sign on a mismatch. This catches a keypair mix-up (signing with one keypair's
    private half while the host trusts another keypair's public half) at the signing
    desk, where it is cheap to fix, rather than at the air-gapped host, where the
    resulting universal rejection is indistinguishable from an attack and there are
    no debugging tools. When the host public key is not supplied, this cross-check
    is skipped and only the always-on self-verification runs.

## Key generation (gen-signing-key make target)

Generates an ed25519 keypair with the correct algorithm, sets the private key to owner-only permissions, and prints both paths plus a reminder to back up the private key and to pass the public key to the boot build via TROSKEL_SIGN_PUBKEY. The repository ships NO key and NO default keypair: a shipped default private key would be known to everyone and would make every signature meaningless.

## Private-key handling tiers

The location of the private key is the administrator's choice. Three tiers, stated honestly:

  - Minimum (a working floor, not a recommendation): the private key is a file on
    the build/sign host. The signature scheme is cryptographically identical at this
    tier; it defends against a substituted medium, which is the threat most solo
    deployments actually face. It does NOT defend against an attacker who has already
    compromised the build host itself.
  - Better: the private key lives on a separate offline machine, carried to signing,
    never on a networked or shared host. Defends against build-host compromise.
  - Strongest: the private key lives on a hardware token from which it cannot be
    extracted. The intended long-term posture.

The code supports all three without modification, because the signer takes the private-key path as an argument and never assumes where the key lives.

## The two failure modes this contract exists to defeat

  - The substitution attack: an attacker swaps in their own medium, signed with
    their own key. Defeated only on a SIGNING host, which refuses any signature not
    matching its baked public key.
  - The silent self-mismatch: the administrator's own keypair mix-up, producing a
    universal rejection that masquerades as an attack. Defeated at the signing desk
    by the optional cross-check, and made diagnosable at the host by the distinct
    error tokens (MISSING vs BAD vs MALFORMED vs SET vs HASH).

Every test in tests/test-sign-data-usb.sh and the forthcoming load-scanner tests maps to a row of the state table or to one of these two failure modes. A test that does not is either redundant or testing the wrong thing.