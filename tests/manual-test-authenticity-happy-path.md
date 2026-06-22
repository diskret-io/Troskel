# Manual test: data-USB authenticity gate, happy path

A bench walkthrough to confirm the gate works end to end with your own hardware:
generate a key, build a signing host, sign a data USB, and watch the host accept
it. Ends with a 30-second negative check so you actually see the gate refuse a
bad medium, because a gate you have only seen accept is a gate you have not
really tested.

You need: the build station, two USB sticks (one boot, one data), and the
scanning host machine. Roughly 20 minutes, most of it the ISO build.

Throughout, replace /dev/sdX and /dev/sdY with your real device nodes. Check
with `lsblk` before every write. Writing to the wrong device destroys it.

## 1. Generate your signing key (once)

On the build station:

```bash
make gen-signing-key
```

You now have keys/troskel-sign.key (private) and keys/troskel-sign.pub (public).
Confirm:

```bash
ls -l keys/
# troskel-sign.key should be mode -rw------- (0600)
```

## 2. Build a SIGNING boot USB

Insert the boot USB. Find its device node:

```bash
lsblk
```

Build the boot USB with your public key baked in:

```bash
sudo TROSKEL_SIGN_PUBKEY=keys/troskel-sign.pub bash scripts/prepare-boot-usb.sh /dev/sdX
```

Watch for these lines in the output, they confirm the gate was wired in:

```
[*] Authenticity gate: SIGNING host (verifier key keys/troskel-sign.pub).
[*] Bundling shared regions into host scripts...
[+] Drift check passed: baked verifier key matches source (<fingerprint>).
```

Record the passphrase printed at the end. You need it to log in on the host.

## 3. Write and sign a data USB

Insert the data USB. Find its node (`lsblk`), then write it:

```bash
sudo bash scripts/troskel-build.sh --usb-data
```

This writes TROSKEL-DATA but does NOT sign it (signing is a separate, deliberate
step). Now sign it with your private key, passing your public key too so the
signer confirms the keypair matches your host:

```bash
sudo bash scripts/sign-data-usb.sh /dev/sdY keys/troskel-sign.key keys/troskel-sign.pub
```

Expect:

```
[*] Signing key matches the supplied host public key.
[*] Signing manifest (N files) with offline key...
[*] Verifying signature against the medium copy...
[+] Medium signed and verified.
```

If you instead see "REFUSING TO SIGN: the private key does not match the host
public key", you used a mismatched key; you generated a new key after building
the boot USB, or pointed at the wrong file. Rebuild the boot USB with the
current keys/troskel-sign.pub, or sign with the key that matches the host.

## 4. Boot the scanning host and confirm it accepts the signed USB

Put the boot USB and the signed data USB into the scanning host. Boot from the
boot USB.

During load, watch the console for:

```
[*] Authenticity: SIGNING host; verifying data-USB signature...
[+] Authenticity verified: signature matches this host's trusted key.
[+] scanner-rootfs.ext4 verified against sidecar.
[+] Scanner loaded. Signature date: <date>
```

The "[+] Authenticity verified" line is the happy path proven: the host checked
the signature against its baked key and accepted your medium. Log in as `scanner`
with the passphrase from step 2.

That is the happy path. The gate is working.

## 5. Negative check (30 seconds, do this so you trust it)

A gate you have only watched accept could be accepting everything. Prove it
refuses. The quickest way, without a second key:

Take the signed data USB back to the build station, mount it, and alter one
byte of a file the manifest covers (this simulates tampering after signing):

```bash
sudo mount /dev/sdY1 /mnt          # adjust partition node as needed
echo "x" | sudo tee -a /mnt/scanner.env   # append a byte; manifest is now stale
sudo umount /mnt
```

Boot the host with this tampered USB. Expect a REFUSAL:

```
[!] Data USB REFUSED: a file's contents do not match the signed manifest
    (HASH_MISMATCH scanner.env). The medium was altered after signing.
```

The host refused, named the reason, and did not load the scanner. That is the
gate doing its job. Re-sign the USB (step 3) to make it usable again, or rewrite
it.

For a fuller negative test (a USB signed by a DIFFERENT key, the substitution
attack), generate a second key into another directory, sign the USB with that
key, and boot: the host refuses with "signature does not match this host's
trusted key". Not required for a smoke test, but it is the attack the gate
exists to stop, so it is satisfying to see refused.

## If something goes wrong

- Boot build aborts with "No signing key supplied and unsigned operation not
  explicitly requested": you forgot TROSKEL_SIGN_PUBKEY. Re-run step 2 with it
  set.
- Host shows "Authenticity enforcement is OFF": the boot USB was built WITHOUT a
  key (permissive). Rebuild it with TROSKEL_SIGN_PUBKEY set (step 2).
- "signature does not match this host's trusted key" on a USB you signed: the
  boot USB and the signing key are from different keypairs. The public key in the
  boot USB must be the public half of the private key you signed with. Rebuild
  the boot USB from the current keys/, or sign with the matching key.

Full behaviour reference: docs/medium-authenticity-contract.md.
Operator guide: docs/ADMIN.md (Data USB authenticity).