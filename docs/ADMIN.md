# Admin guide

The admin prepares the two USBs that the operator uses on the scanning host. One command on the build station handles the full session-preparation cycle.

## Quick start

On the build station, insert both USB sticks and run:

```bash
sudo bash scripts/troskel-build.sh
```

`troskel-build.sh` guides through the full process interactively:

- Detects connected USB devices and asks for role assignment.
- Downloads fresh ClamAV signatures and YARA rules.
- Builds the scanner image.
- Writes both USB sticks and verifies checksums.
- Displays the scanning host passphrase prominently at the end.

The passphrase is not stored anywhere. Record it on the boot USB label or in a password manager before continuing.

## Command reference

```bash
sudo bash scripts/troskel-build.sh [OPTIONS]
```

| Flag         | Effect                                                          |
|--------------|-----------------------------------------------------------------|
| `--usb-all`  | Write both boot and data USBs (default).                        |
| `--usb-data` | Write TROSKEL-DATA only. Expects one USB device.                |
| `--usb-boot` | Write TROSKEL-BOOT only. Expects one USB device.                |
| `--update`   | Refresh signatures and rebuild scanner image; skip USB writing. |
| `--debug`    | Stream full output from all sub-steps.                          |

`--update` is the right flag between sessions when the boot USB is still good but signatures have aged. The boot USB only needs rewriting if the underlying CoreOS or the scanner's host-side configuration changes.

## First-time setup

On a fresh build station, install Docker first:

```bash
# See https://docs.docker.com/engine/install/ for your distribution
sudo bash scripts/prepare-build-machine.sh
```

`prepare-build-machine.sh` installs everything else the build pipeline needs. The host needs Docker; the container provides every other tool.

After first-time setup, the regular workflow is `sudo bash scripts/troskel-build.sh`.

## Data USB authenticity
 
The scanning host can verify that a data USB (TROSKEL-DATA) was signed by you,
not substituted by someone else. This is optional but recommended: without it,
an attacker who can swap the data USB can feed the host a scanner image and
definitions of their choosing, and the host has no way to tell. With it, the
host refuses any data USB not signed by your key.
 
This rests on a keypair you generate once. The private key signs data USBs and
stays secret; the public key is baked into the boot USB and verifies signatures
on the scanning host. They are a matched pair: only the private key can produce
a signature the baked public key accepts.
 
### One-time: generate your signing key
 
```bash
make gen-signing-key
```
 
This writes `keys/troskel-sign.key` (private, keep secret, back it up) and
`keys/troskel-sign.pub` (public). If you lose the private key you cannot sign
new media and must generate a new key and rebuild the boot USB (see Rotating the
key below). Back the private key up somewhere safe and offline.
 
### Building a signing host
 
Build the boot USB with your public key, so the resulting host enforces
authenticity:
 
```bash
sudo TROSKEL_SIGN_PUBKEY=keys/troskel-sign.pub bash scripts/prepare-boot-usb.sh /dev/sdX
```
 
The boot build refuses to proceed if you set neither `TROSKEL_SIGN_PUBKEY` nor
`TROSKEL_ALLOW_UNSIGNED`, so you never accidentally build a host whose posture
you did not choose. To deliberately build a host that does NOT verify
authenticity (for testing, or if you do not want signing), set
`TROSKEL_ALLOW_UNSIGNED=1` instead and provide no key. Such a host announces on
every load that it is not enforcing authenticity.
 
### Signing a data USB
 
After `prepare-data-usb.sh` (or `troskel-build.sh`) has written a data USB, sign
it:
 
```bash
sudo bash scripts/sign-data-usb.sh /dev/sdY keys/troskel-sign.key keys/troskel-sign.pub
```
 
The third argument (your public key) is optional but recommended: it lets the
signer confirm the private key matches the key your host trusts, catching a
key mix-up at your desk rather than as a baffling rejection at the air-gapped
host. A signing host refuses any data USB that is unsigned, signed by a
different key, or altered after signing.
 
### Where the private key lives: three levels
 
The location of the private key is your choice, traded off against how much you
need to defend. From minimum to strongest:
 
- Minimum (a working floor, not a recommendation): the private key is a file on
  the build station, where `gen-signing-key` puts it. This is enough to defend
  against a substituted data USB, the threat most deployments actually face. It
  does NOT defend against an attacker who has already compromised the build
  station itself: such an attacker can sign media with your key.
- Better: keep the private key on a separate machine that is not networked,
  carry the data USB to it for signing, and never let the key touch the build
  station. This defends against build-station compromise.
- Strongest: keep the private key on a hardware token from which it cannot be
  extracted. `sign-data-usb.sh` takes the key path as an argument and does not
  care where the key lives, so moving up these levels needs no code change, only
  a different key location.
Whichever level you choose, the scanning host is unaffected: it only ever holds
the public key, baked into its boot image.
 
### Rotating the key
 
To change which key a host trusts (because the private key was lost, or you
suspect it was exposed), you must rebuild the boot USB with the new public key
and re-image the host from it. There is deliberately no way to update the
trusted key on a running host: the key is part of the host's boot-time trust
anchor, so changing it is as deliberate an act as first standing the host up.
After rotating, re-sign your data USBs with the new private key; media signed
with the old key will be refused.
 
### What a refusal looks like
 
On a signing host, a refused data USB stops the load with a specific reason:
the medium is unsigned, the signature does not match the host's trusted key
(a different key, or a substitution), the manifest is malformed, or a file was
added, removed, or altered after signing. The scanner is not loaded and nothing
is copied from the refused medium. If you see "signature does not match this
host's trusted key" on a USB you signed yourself, you have a key mix-up: the
private key you signed with does not correspond to the public key baked into
that host. Re-sign with the matching key, or rebuild the host with the public
half of the key you are signing with. (Passing your public key to
`sign-data-usb.sh` as shown above prevents this.)
 
The full behavioural specification is docs/medium-authenticity-contract.md.

## What troskel-build.sh actually does

The phases that run depend on the mode. In the default `--usb-all` run they are:

1. **Runtime detection** verifies Docker is available.
2. **USB detection** enumerates connected USB block devices and assigns them to roles.
3. **Preflight checks** verify internet connectivity, EFF wordlist presence, and disk space under `/var/lib/troskel`.
4. **Artefact update** delegates to `make update`, which runs the full refresh pipeline inside the troskel-build container.
5. **USB writes** call `prepare-data-usb.sh` and `prepare-boot-usb.sh` on the assigned devices.
6. **Verification** re-mounts the data USB read-only and verifies the SHA-256 checksums on the materialised rootfs.

`--update` skips the USB detection, write, and verification stages; `--usb-boot` skips verification (there is no data USB to check). 

### Confirmation prompts

The script asks you to confirm before it writes to a device: in `--usb-all` mode you assign each USB to a role by number and then confirm the assignment, and in single-device modes you confirm the one device. These confirmations require you to type `y` (or `Y`) deliberately. Pressing Enter on its own does not confirm and re-asks the question.

This is a deliberate safety behaviour, not a quirk. USB writes are destructive and irreversible, so the prompt will not accept an empty response or a keystroke buffered from an earlier stage as approval. If you have developed the habit of holding or tapping Enter to move through prompts, note that it no longer advances the destructive gates; type `y` when you have read and agree with what the prompt states.

## When things fail

The script halts at the first failed phase and prints the failing sub-step's full output. Common failures and what to do about them:

- **Docker not found.** Install Docker and rerun. See [docker.com/engine/install](https://docs.docker.com/engine/install/).
- **No internet access.** The build station needs network connectivity to download signatures, YARA rules, and the guest kernel. Resolve connectivity and rerun.
- **Disk space warning.** The `/var/lib/troskel` directory is where the build container persists artefacts. About 5GB free is sufficient. Free space and rerun.
- **USB detection finds wrong number of devices.** Insert exactly the USBs you intend to write to. Other USB devices, including ones in use as system storage, are excluded from the list, but it is safer to unplug them anyway.
- **`make update` fails inside the container.** Run `make update` directly outside `troskel-build.sh` for a clean view of the container's output. The script wraps `make update` for convenience but does not transform its output; running it directly gives the same information without the wrapper.
- **TROSKEL-DATA checksum verification fails.** Do not use the USB. The data was written incorrectly. Rewrite via `--usb-data`.

For deeper diagnostics or to investigate a recurring failure, run with `--debug` and capture the full output.

## Routine maintenance

Between sessions, refresh the data USB to keep signatures current:

```bash
sudo bash scripts/troskel-build.sh --usb-data
```

The boot USB rarely needs rewriting. Rewrite it only when:

- The scanner's host-side configuration changes (`config/scanner-host.bu` or anything under `config/host-scripts/`).
- The pinned CoreOS version in `config/versions.env` is bumped.
- The scanning host passphrase needs to change. A new boot USB will print a fresh passphrase.

The signature freshness gate is configured in `config/scanner.env` (`CLAM_SIG_AGE_DAYS`, `LOKI_YARA_AGE_DAYS`). When a data USB ages past the gate, `check-system-ready` on the scanning host will reject it; that is the operator's signal that a fresh data USB is needed.