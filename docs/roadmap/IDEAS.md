# Feature ideas

Loose-form ideas that are not yet scoped enough for their own roadmap document. Three kinds of entry live here:

- **Speculative**: interesting but not yet thought through. May or may not become roadmap items.
- **Promoted**: has been moved to its own roadmap document in this directory. The entry below is kept as a pointer.
- **Superseded**: overtaken by other roadmap work that covers the same ground. Kept as a historical record.

When an idea becomes concrete enough to have a target version, an effort estimate, and an implementation outline, it graduates to its own `.md` in this directory and the entry here is updated.

## Functionality

**Quarantine Visualization**

> Status: **Partly superseded.** The on-screen "show flagged filenames" portion is covered by [`improved-verdict-output.md`](improved-verdict-output.md) (target `1.0.0`). The USB-report portion (visual report with file hash, written to the output USB) is a follow-on to [`output-usb.md`](output-usb.md) and remains unscheduled.

If a threat is found, don't just block it. Create a visual report (on the result USB) showing exactly which file was infected, the threat type, and a hash of the malicious file. This helps the operator understand why the transfer failed.

**Hardware Integrity Check**

> Status: **Speculative.** Touches the firmware trust boundary, which is currently outside the threat model (`SECURITY.md`'s "No measured boot" residual risk). Needs a concrete mechanism before it can be scoped.

Add a simple check to ensure the "Scan Host" hasn't been tampered with (e.g., checking BIOS settings or USB port integrity) before allowing the LiveOS to boot.

## UX

**Color-Coded Workflow**

> Status: **Speculative**, partly overlapping with [`improved-verdict-output.md`](improved-verdict-output.md). Decide before implementing whether this is a follow-on to the verdict-output work or a separate full-screen-state design.

    Green Screen: "System Ready. Insert Data USB."
    Blue Screen: "Scanning in MicroVM... (Do not remove USB)."
    Red Screen: "Threat Detected. Transfer Aborted."
    Gold Screen: "Scan Complete. Data Verified. Safe to Transfer."

**One-Button "Eject"**

> Status: **Speculative.** The current architecture already unmounts the data USB after `load-scanner` runs at boot. Auto-ejecting the file USB after a scan has security implications (an automated unmount on the file-USB port is the kind of action a HID-injected attacker might want to wait for) that have not been thought through.

Once the scan is done and the data is safe, the software should automatically unmount the data USB and display a large "Safe to Remove" message, preventing accidental removal during the write-back process.

## Funding

**"Powered By Community" Splash**

> Status: **Speculative**, project-direction question rather than an engineering task. Not on the technical roadmap.

On the boot screen, display a subtle message: "Running on community support. If this scan saved your system, consider tipping the developers." + tip jar URL with QR code.

## Safety Net

**Fail-Safe Mode**

> Status: **Partly already implemented.** The microVM-crash and unrecognised-output cases are covered by the existing fail-closed verdict logic (`SECURITY.md`, "Fail-closed verdict" architectural property) — anything other than an explicit `VERDICT: CLEAN` produces yellow or red. The remaining gap is hardware-error detection beyond what OOM and guest panic already produce, which is genuinely speculative and would benefit from a concrete mechanism before scoping.

If the microVM crashes or the LiveOS detects a hardware error, the software should default to blocking the transfer and displaying an error code, rather than allowing the data through.
