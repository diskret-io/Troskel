# OPERATOR GUIDE

For when a scan does not produce a green verdict, or when `check-system-ready` reports a failure. Covers the operator-visible cases only — anything not listed here, or anything you are unsure about, contact the admin.

This guide is technical. Site policy on what to do with flagged file USBs (return to sender, retain, destroy, log) is set locally and is not covered here.

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

Do not transfer any files from the file USB, not just the flagged ones. A file USB on which any item flagged is treated as untrusted in its entirety.

For the details of what was flagged:

```bash
grep -E 'FOUND$|"level":"ALERT"' /var/log/troskel/scan-*.log
```

ClamAV's `FOUND` lines and LOKI-RS's JSONL `ALERT` records are the authoritative finding details. Note that the log lives in tmpfs and will be lost when you power off, if the admin needs the log, photograph the screen before powering off.

Then follow your site's policy for handling the file USB and power off:

```bash
sudo poweroff
```

### Yellow — `*** RESULT UNCLEAR — Contact admin ***`

The scan did not produce a recognisable verdict. This is intentional: the system is fail-closed, so any outcome that is not unambiguously clean produces yellow rather than green. Common causes, in rough order of likelihood:

- **An engine errored.** The per-engine breakdown will show `ERROR` next to one or both engines. The most common cause is a corrupted signature or rule file in the scanner image; the admin will need to rebuild the data USB.
- **The guest crashed during the scan.** A malformed file in the scan target can crash a scanner parser. The hypervisor catches this, but no verdict is emitted. The file USB should be treated as suspicious — a file that crashes a parser is, by definition, abnormal.
- **Resource exhaustion.** A very large file or an archive bomb can exhaust the guest's memory. The guest reboots, no verdict is emitted, yellow is shown.

Do not transfer files from the file USB. Treat yellow as "no information", not "probably clean".

When contacting the admin, the useful information to provide is:

- The yellow block's per-engine breakdown (which engine, if any, reported `ERROR`).
- The scan log on screen — photograph it before powering off if the admin wants to inspect it. The log is at `/var/log/troskel/scan-<timestamp>.log` but lives in tmpfs and will be lost at power-off.
- A rough description of the file USB contents, particularly anything unusual (very large files, unfamiliar archive formats, files from an unusual source).

Power off when the admin has what they need:

```bash
sudo poweroff
```

---

## Readiness check failures

Two commands report system state:

- **`show-status`** is the primary diagnostic. It is fast, has no exit-code semantics, and shows everything needed to triage a problem in one screen: signature date, scanner image presence, KVM state, last scan, last result. Run this first.
- **`check-system-ready`** is the gate. It runs seven checks and exits non-zero if any fail. Scanning is permitted only when it passes.

When something is wrong, run `show-status` first to see the system's overall state, then run `check-system-ready` to identify which specific check failed. The categorised list below maps each `check-system-ready` failure to whether the operator can resolve it.

A failure does not always mean the admin needs to be involved, some failures are things the operator can resolve in the room.

### Operator can resolve

**`Scanner image loaded — not found`** and **`Guest kernel loaded — not found`**

The data USB is either not plugged in or `load-scanner` did not run successfully at boot. Steps:

1. Confirm the data USB is plugged in and that the LED (if it has one) indicates activity.
2. Reboot:

   ```bash
   sudo reboot
   ```

3. After reboot, log in as `scanner` and re-run:

   ```bash
   show-status
   check-system-ready
   ```

If the failure persists after a reboot with the data USB plugged in, the data USB itself may be faulty or unwritten. Contact the admin; a fresh data USB from the build station is needed.

**`Signature date present and fresh — signatures are N days old, run update`**

The scanner image is older than 30 days. The system will not scan with stale signatures. The fix is a fresh data USB from the admin, prepared on the build station with `run-update.sh`. The operator cannot resolve this in the room, but the operator *can* identify it as the cause and tell the admin exactly what is needed, which shortens the handoff.

### Admin must resolve

**`No active network interfaces beyond loopback — N interface(s) active`**

The scanning host has come up with a network interface enabled. This must not happen and is a build-configuration regression. Power off and contact the admin. Do not scan.

**`KVM accessible — not accessible`**

Hardware virtualisation is unavailable. The scanner cannot run. Either the BIOS has VT-x / AMD-V disabled, or the hardware does not support it. Power off and contact the admin.

**`Auto-update (zincati) is disabled — status: ...`**

The auto-update daemon is not in its expected state. This is a build-configuration regression. Power off and contact the admin.

**`No network interface in scan config — network config found, review run-scan`**

The Firecracker scan configuration contains a network interface. This must not happen and indicates either a tampered scanner image or a build regression. Power off and contact the admin. **Do not scan, even if other checks pass.**

**`Signature date present — not found`**

The freshness file is missing entirely. The data USB is either malformed or did not load correctly. Contact the admin for a fresh data USB.

---

## What to tell the admin

When contacting the admin about any of the above, the useful information is:

- The output of `show-status`: this is the single most useful artefact and should be shared first. It captures signature date, image load state, KVM accessibility, and the last scan's result in one screen.
- The exact text of the failed check or yellow/red block, as displayed.
- For verdict failures: a photograph of the scan log on screen before power-off, if the admin asks for it. The log path is `/var/log/troskel/scan-<timestamp>.log` but the log lives in tmpfs and is lost at power-off.
- For readiness failures: whether the same failure has occurred before in this session (relevant for transient versus persistent issues).

Power off before stepping away from the host:

```bash
sudo poweroff
```

The host is not designed for unattended idle, RAM is the only place state lives, and the right moment to clear it is at the end of the session.