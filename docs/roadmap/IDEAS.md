# Feature ideas

## Functionality

**Automated "Clean Certificate"** 

Instead of just saying "no AV triggered," generate a cryptographically signed PDF or text file (a "Clean Certificate") that proves when the scan happened, which virus definitions were used, and that the result was clean. This adds auditability for the admin. Should be signed (GPG/PGP).

Requires a third, result USB. When the scan is complete, the certificate is automatically written here, which verifies the transfer for audit log purposes.

**Quarantine Visualization** 

If a threat is found, don't just block it. Create a visual report (on the result USB) showing exactly which file was infected, the threat type, and a hash of the malicious file. This helps the operator understand why the transfer failed.

**Definition Version Display**

Ensure the software explicitly displays the "Last Updated" date of the virus definitions on the boot screen.

**Hardware Integrity Check** 

Add a simple check to ensure the "Scan Host" hasn't been tampered with (e.g., checking BIOS settings or USB port integrity) before allowing the LiveOS to boot.

## UX

**Color-Coded Workflow**

    Green Screen: "System Ready. Insert Data USB."
    Blue Screen: "Scanning in MicroVM... (Do not remove USB)."
    Red Screen: "Threat Detected. Transfer Aborted."
    Gold Screen: "Scan Complete. Data Verified. Safe to Transfer."

***One-Button "Eject"** 

Once the scan is done and the data is safe, the software should automatically unmount the data USB and display a large "Safe to Remove" message, preventing accidental removal during the write-back process.

## Funding

**"Powered By Community" Splash** 

On the boot screen, display a subtle message: "Running on community support. If this scan saved your system, consider tipping the developers." + tip jar URL with QR code.

## Safety Net

**Fail-Safe Mode**

 If the microVM crashes or the LiveOS detects a hardware error, the software should default to blocking the transfer and displaying an error code, rather than allowing the data through. 

 ## Testing

 See if not some of the manual tests could be automated.