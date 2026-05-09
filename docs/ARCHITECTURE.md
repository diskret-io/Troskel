# ARCHITECTURE

## Why two machines

Signature freshness needs internet; air-gapped operation forbids it. The design partitions the workflow: 
- A networked **build station** produces artefacts
- An air-gapped **scanning host** consumes them.

## Why two USB sticks

The boot USB and the data USB serve distinct purposes.

- The **boot USB** carries the operating system. It is essentially read-only in operation.

- The **data USB** carries the scanner image, kernel, and signature metadata.

The split enforces a useful access pattern: `load-scanner` reads the data USB at one well-defined point in boot, copies its contents to RAM, and unmounts it. The data USB is never touched again during the session.

## Why CoreOS

Four properties are required: boot from removable media into RAM, apply a declarative configuration on every boot, leave no persistent state, small attack surface. CoreOS satisfies all four.

## Why Firecracker

The scans run against adversarial input. Both ClamAV and LOKI-RS have parser surfaces that should be assumed exploitable. 

Firecracker provides a hardware-virtualised boundary with an extremely small attack surface, purpose-built for serverless workloads with the explicit goal of minimising hypervisor exposure. 

## Why Debian inside the guest

The scanner image that runs inside Firecracker is built on Debian trixie minbase.

ClamAV's behaviour on Debian is well-understood. Its packaging is mature, and its
behaviour matches upstream documentation.

## Why two engines

Two engines with independent detection logic produce an OR over their detection sets. A file evading one may still be caught by the other.

The two engines are deliberately complementary rather than overlapping:

**ClamAV** is a signature-based AV engine with broad coverage of commodity malware, ransomware, and known exploits. Its strength is breadth: a large catalogue of known threats, archive unpacking, format-aware scanning of PE/ELF/script/document files.

**LOKI-RS** is a YARA-rule and IOC scanner with a curated threat-hunting rule corpus. Its strength is targeted detection of web shells, hack tools, APT-associated artefacts, and malicious scripts, categories ClamAV covers less thoroughly. Uses the YARA Forge Core rule set by default and supports filename, hash, and C2 IOCs.

Both engines are fundamentally pattern-based. The architecture is not equivalent to combining a signature-based AV with a behavioural or heuristic engine. 

## Why an ext4 image for the scan target

The data USB's content is presented to the guest as a read-only block device backed by an ext4 image. It has less hypervisor surface than alternatives plus a cleaner read-only enforcement than alternatives.

## Why a 30-day signature freshness threshold

Encoded in `check-system-ready`. Short enough that signatures are still reasonably current but without allowing to much drift.

## Why the verdict pipeline is structured as it is

The scan verdict is the highest-stakes output the system produces. Layered deliberately so no single component can produce a false-clean.

**The guest entrypoint emits explicit verdict strings**, not numeric exit codes. Ambiguous outcomes are mapped conservatively. A clean result requires both engines to return 0clean results; a threat from either returns red. The guest then reboots, regardless of outcome.

**The host parses with three discrete grep checks**, in order: `THREAT DETECTED` first (so a log containing both `THREAT DETECTED` and `CLEAN` is treated as a threat), `CLEAN` second, anything else falls through to UNCLEAR.

**The logic is fail-closed.** A log matching neither pattern produces yellow. This covers empty logs, truncated logs, kernel panics, hypervisor crashes, OOM in the guest, ENOSPC during the scan, and any future failure mode we have not anticipated. The system never defaults to clean.

The redundancy between guest-side and host-side logic is intentional. Either alone would be sufficient under nominal conditions; both are present so a defect in one cannot silently change the verdict.

## Why power-off is the end-of-session signal

The operator's workflow ends with powering off the scanning host. Not logout, not a session-end script. It relies on a hardware property (RAM loses state without power) rather than software correctness. Atomic, irreversible, and easily verifiable.

## Component boundaries
 
```
File USB                       (UNTRUSTED — assumed adversarial)
    │
    ▼
Hardware write blocker         (Read-only at USB protocol layer)
    │
    ▼
Host kernel mount /mnt/usb     (Read-only mount option)
    │
    ▼
mkfs.ext4 -d /mnt/usb scan.img (Materialised as opaque block image)
    │
    ▼
losetup --read-only            (Read-only at block layer)
    │
    ▼
virtio-blk drive (is_read_only: true)
    │                          ◀── HARDWARE VIRTUALISATION BOUNDARY ──
    ▼
Guest: mount -o ro /dev/vdb    (Read-only mount inside guest)
    │
    ▼
ClamAV  +  LOKI-RS             (UNTRUSTED — parsers assumed exploitable)
    │
    ▼
Verdict on /dev/ttyS0          (One-way serial out)
    │                          ◀── HARDWARE VIRTUALISATION BOUNDARY ──
    ▼
Host: /var/log/troskel/...  (Tmpfs — destroyed on power-off)
    │
    ▼
grep VERDICT → green / red / yellow
```
 
This architecture means that even if an attacker breaks a scanner with a malformed file, their only way out is a one-way text channel the host reads with simple pattern checks. A green light requires the scanner to print 'VERDICT: CLEAN', but breaking it makes it crash rather than print that. The attacker is trapped; the only remaining attack is malware the rules don't recognise, which is a known limit of any pattern-matching scanner.
