# Optional output USB — scan log and clean certificate

Provide an optional `TROSKEL-OUTPUT` USB that receives the scan log and a signed clean certificate after each session. The output USB is entirely optional — deployments that do not need an audit trail continue to work unchanged with two USBs (boot + data). When a `TROSKEL-OUTPUT` USB is present, it is detected automatically and written to after the scan completes.

The file USB is never written to. The read-only invariant on the file USB is preserved.

## Motivation

Some deployments require an auditable record of every transfer: when it was scanned, which signature versions were used, what the verdict was, and a cryptographic tie between the record and the exact files scanned. A screenshot of a terminal is not a sufficient audit trail for regulated environments. A signed, machine-readable certificate on a physical USB is.

Smaller or less formal deployments do not need this. The feature must not add friction for them.

## What the output USB contains after a scan

```
TROSKEL-OUTPUT/
  scans/
    20260510T123456Z/
      verdict.txt          Human-readable verdict summary
      scan.log             Full scan log (copied from /var/log/troskel/)
      certificate.txt      Signed clean certificate (green only)
      manifest.sha256      SHA-256 of all files in this directory
```

The timestamp directory groups each scan session. Multiple scans per session are supported — each gets its own subdirectory. The USB accumulates records across sessions until formatted.

### `verdict.txt` — always written

```
Troskel Scan Record
===================
Timestamp  : 2026-05-10T12:34:56+00:00
Verdict    : CLEAN
ClamAV     : clean (0 findings)
LOKI-RS    : clean (0 findings)
Sig date   : 2026-05-09T08:00:00+00:00
YARA date  : 2026-05-08T14:00:00+00:00
File USB   : SHA-256 of scan target image
Host ID    : configured site name or hostname
```

Written regardless of verdict. RED and YELLOW records are equally important to retain.

### `certificate.txt` — written on GREEN only

A plain-text document suitable for printing or attaching to a transfer record. Contains the same information as `verdict.txt` plus a GPG signature block.

The signature is produced by an admin GPG key configured at build time. If no admin key is configured, the certificate is written unsigned with a clearly marked `[UNSIGNED]` notice — useful for sites that want the record but have not yet set up key management.

### `scan.log` — always written

The full raw scan log from `/var/log/troskel/`, including all engine output. Useful for forensic analysis on a red verdict.

---

## Admin configuration

The admin configures the output USB feature in `config/scanner.env`:

```sh
# Optional output USB configuration.
# Set SITE_NAME to identify this scanning host in certificates.
# Leave ADMIN_GPG_KEY empty to produce unsigned certificates.
SITE_NAME="Example Organisation — Room B"
ADMIN_GPG_KEY_FINGERPRINT=""
```

The GPG public key is embedded in the scanner rootfs at build time. The corresponding private key never touches the scanning host — certificates are signed by the admin key on the build station and the public key is used on the host only for display purposes. Wait — this is the wrong model. See Open Questions.

---

## Operator workflow (with output USB)

The operator workflow changes minimally:

1. Insert TROSKEL-BOOT, TROSKEL-DATA, and TROSKEL-OUTPUT USBs and power on.
2. `check-system-ready` detects and reports the output USB presence.
3. Insert file USB and run `troskel` as normal.
4. After the verdict, `troskel` writes automatically to the output USB.
5. On green: the output USB and the file USB both proceed through the air gap. The certificate travels with the files as provenance.
6. On red: the output USB is retained for the admin's records. The file USB does not proceed.
7. Power off.

The operator does not need to do anything differently to trigger the output USB write — detection is automatic.

---

## How the output USB is detected

`troskel` (the operator entry point) currently calls `scan-wrap` with the file USB path. After `scan-wrap` exits, `troskel` checks for a USB device labelled `TROSKEL-OUTPUT`:

```bash
OUTPUT_DEV="$(blkid -L TROSKEL-OUTPUT 2>/dev/null || true)"
if [ -n "$OUTPUT_DEV" ]; then
    write_output_usb "$OUTPUT_DEV" "$SCAN_LOG" "$VERDICT"
fi
```

If `TROSKEL-OUTPUT` is not present, `write_output_usb` is never called and the operator sees no difference.

---

## How the output USB is prepared

On the build station, `troskel-build.sh` gains a `--usb-output` option that formats a USB with the `TROSKEL-OUTPUT` label and writes the admin GPG public key into a `.troskel/` directory on the USB. This is the only setup step. The USB can be reused across sessions — new scan records accumulate in `scans/`.

`prepare-data-usb.sh` is not involved. The output USB has its own preparation path.

---

## Certificate signing model

The clean certificate must be tied to the scan and verifiable without trusting the scanning host. Two options:

**Option A — admin signs the certificate on the build station**

After the session, the admin retrieves the output USB, verifies the `manifest.sha256`, and GPG-signs the certificate on the build station using a key that never touches the scanning host. The signed certificate is written back to the output USB.

Pro: the private key never touches the scanning host — the strongest security model. Con: the certificate is not signed at scan time — there is a gap between the scan and the signature.

**Option B — the scanning host signs at scan time**

The admin GPG private key is embedded in the scanner rootfs (inside the Firecracker guest, not on the host). The guest signs the certificate before emitting the verdict and writes the signed certificate to a well-known path in the guest filesystem, from which `scan-wrap` copies it to the output USB.

Pro: the certificate is signed at the moment of scanning. Con: the private key is on the scanning host — inside the guest, which has no network access and is ephemeral, but still reachable if the guest is compromised.

**Recommendation: Option A for v1, document Option B as a future consideration.** The gap between scan and signature is acceptable for most deployments, and keeping the private key off the scanning host entirely is the stronger security stance. The unsigned-with-notice fallback covers deployments that want a record but have not set up GPG.

---

## Estimated effort

Two to three days:
- `troskel` (operator entry point): output USB detection and `write_output_usb` function (~half day)
- `verdict.txt` and `scan.log` writing (~half day)
- Certificate generation — unsigned version (~half day)
- `troskel-build.sh --usb-output` preparation path (~half day)
- `check-system-ready` output USB presence check (~1 hour)
- GPG signing — Option A (~half day, if implemented in v1)
- Test coverage (~half day)

## Sequencing

No outstanding dependencies. The two earlier roadmap items this work would have interacted with — the verdict-display refactor (formerly tracked as `improved-verdict-output.md`) and the upstream-artefact integrity verification (formerly `checksum-verification.md`) — have both landed in `main`. The end-of-scan section of `scan-wrap` is now in the shape this work expects to extend, and the per-build provenance fields that the certificate references (signature dates, resolved upstream versions) are already recorded in `versions.env` and on the data USB.

Does not depend on the parallel engines or capa tasks.

Target `1.1.0`. Does not block `1.0.0`.

## Open questions

- **Option A vs Option B for signing.** Recommendation above is Option A. Worth confirming with anyone who has deployment experience in regulated environments — some require the signature to be contemporaneous with the scan.
- **What happens if the output USB fills up?** Old scan records should probably not be deleted automatically — the admin should review and format the USB deliberately. `write_output_usb` should check available space and warn (yellow block? separate notice?) if less than a threshold remains.
- **Should the output USB label be configurable in `scanner.env`?** `TROSKEL-OUTPUT` is the default; a site with multiple scanning hosts might want `TROSKEL-OUTPUT-ROOM-B`. Low priority but worth noting.
- **PDF certificate vs plain text?** A PDF is more presentable for a formal audit record but requires PDF generation tooling in the guest or on the build station. Plain text is universally readable and GPG-signable without additional dependencies. Start with plain text; consider PDF as a follow-on if there is demand.
- **Should RED scans produce a certificate?** A "THREAT DETECTED" certificate signed by the admin provides a formal record that a bad transfer was caught. Useful for incident reporting. Add as an option rather than the default — some sites may not want a signed artefact associated with a malware event.
- **Crypto primitive?** Align with sign-data-usb-manifest (ed25519/openssl), not GPG. The 'wrong model' marker in Admin Configuration is resolved by the input gate's pattern: keyholder signs off-host, public key delivered to host. Revisit once the input gate lands.