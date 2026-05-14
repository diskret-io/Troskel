# OPERATOR GUIDE

For when a scan does not produce a green verdict, or when `check-system-ready` reports a failure. Covers the operator-visible cases only — anything not listed here, or anything you are unsure about, contact the admin.

This guide is technical. Site policy on what to do with flagged file USBs (return to sender, retain, destroy, log) is set locally and is not covered here.

---

## The file USB — preparing files for scanning

The file USB is a standard USB storage device containing the files you want to transfer into the air-gapped environment. It is separate from the TROSKEL-BOOT and TROSKEL-DATA USBs used by the scanning host itself.

**Format:** The file USB must be formatted as **ext4** or **FAT32**. NTFS and exFAT are not supported as of this release; reformat or use a different medium if your USB is currently NTFS or exFAT.

The narrower supported set reduces the host's exposure to malicious filesystem images. The scanning host refuses to mount any other filesystem, returning a clear message before any scan is attempted. (For the engineering rationale, see `docs/roadmap/ingest-vm.md`.)

There is no other special preparation required. Copy the files to the USB as you normally would on any machine.

**What to put on it:** The files you intend to transfer — documents, software packages, datasets, or anything else. Organise them however you like. `troskel` scans everything on the USB recursively, including files inside subdirectories.

**What the scanner does with it:** `troskel` detects the file USB automatically when you run it, mounts it read-only, copies its contents into the Firecracker microVM as a read-only block device, and scans everything inside. The USB itself is never written to during the scan. After the scan completes the USB is unmounted and you can remove it safely.

**If you have multiple USBs plugged in:** `troskel` picks the last hotplug USB device it detects. To avoid ambiguity, plug in only the file USB when running the scan. The TROSKEL-DATA USB is already unmounted after boot and will not be confused with the file USB.

---

## Scan session — step by step

1. **Prepare the file USB** on any networked machine — copy the files you want to transfer onto a standard USB drive.

2. **Transport** the file USB and yourself to the air-gapped room.

3. **Insert both TROSKEL USBs** (boot and data) into the scanning host and power on. Do not insert the file USB yet.

4. **Log in** as `scanner` with the passphrase from the admin.

5. **Check the system is ready:**
   ```
   show-status
   check-system-ready
   ```
   Both must pass before scanning. If either reports a problem, see the troubleshooting section below.

6. **Insert the file USB.** Wait a moment for the OS to register it.

7. **Run the scan:**
   ```
   troskel
   ```
   The scan runs automatically — it detects the file USB, mounts it, scans everything on it, and displays the verdict. Do not remove any USB during the scan.

8. **Read the verdict:**
   - **GREEN** — files may be transferred. Remove the file USB and carry it to the destination.
   - **RED** — do not transfer. See the Red verdict section below.
   - **YELLOW** — something went wrong with the scanner itself. Contact the admin.

9. **Power off when finished:**
   ```
   sudo poweroff
   ```
   The scan log lives in RAM and is lost on power off. If the admin needs the log, photograph the screen before powering off.

---

## Verdicts

### Green — `*** CLEAN — Files may proceed ***`

Both engines completed and neither flagged anything. Files may be transferred. Power off when finished:

```bash
sudo poweroff
```

### Red — `*** THREAT DETECTED — DO NOT TRANSFER ***`

At least one engine flagged at least one file. The per-engine breakdown under the verdict block tells you which:

```
  ClamAV   : THREAT (3 flagged)
  LOKI-RS  : clean
```

Below the breakdown, the screen lists the specific files that were flagged together with the rule or signature name that flagged each one. The list is truncated at 20 items if a scan produced many findings; the full log path is shown beneath it for the admin's reference.

Do not transfer any files from the file USB, not just the flagged ones. A file USB on which any item flagged is treated as untrusted in its entirety.

The scan log lives in tmpfs and will be lost when you power off — if the admin needs the log, photograph the screen before powering off.

### Yellow — `*** RESULT UNCLEAR — Contact admin ***`

Neither a clean nor a threat verdict was produced. This means something went wrong with the scanning infrastructure itself — the VM crashed, ran out of memory, or produced unrecognisable output. The files have not been scanned. Do not transfer them.

Contact the admin with the output of:

```bash
show-status
cat /var/log/troskel/scan-*.log
```

---

## Troubleshooting `check-system-ready` failures

`show-status` gives an overview. `check-system-ready` identifies the specific failing check. Run this first.

### Operator can resolve

**`Scanner image loaded — not found`** and **`Guest kernel loaded — not found`**

The data USB either is not plugged in or `load-scanner` did not run successfully at boot. Steps:

1. Confirm the data USB is plugged in.
2. Reboot: `sudo reboot`
3. Log in and re-run `show-status` and `check-system-ready`.

If the failure persists after a reboot with the data USB plugged in, the data USB may be faulty or unwritten. Contact the admin.

**`Signature date present and fresh — signatures are N days old`**

The scanner image is older than the configured freshness threshold. A fresh data USB from the admin is needed. The operator cannot resolve this in the room but can tell the admin exactly what is needed.

**`YARA rules date present and fresh — rules are N days old`**

Same as above but for the LOKI-RS rule set. Fresh data USB needed.

### Admin must resolve

**`No active network interfaces beyond loopback — N interface(s) active`**

A network interface is active. This must not happen. Power off and contact the admin. Do not scan.

**`KVM accessible — not accessible`**

Hardware virtualisation is unavailable. Power off and contact the admin.

**`Auto-update (zincati) is disabled — status: ...`**

Build-configuration regression. Power off and contact the admin.

**`No network interface in scan config — network config found`**

The Firecracker config contains a network interface. This must not happen and indicates tampering or a build regression. Power off and contact the admin. **Do not scan, even if other checks pass.**

**`Signature date present — not found`** or **`YARA rules date present — not found`**

The freshness file is missing entirely. The data USB is malformed or did not load. Contact the admin for a fresh data USB.

---

## What to tell the admin

When contacting the admin, the useful information is:

- The output of `show-status` — share this first.
- The output of `check-system-ready` — identifies which check failed.
- The scan log if a yellow verdict occurred: `cat /var/log/troskel/scan-*.log`
- The signature date shown in `show-status` — this tells the admin whether a fresh data USB is needed.