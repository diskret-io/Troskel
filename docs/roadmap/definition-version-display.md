# Signature date on the pre-login screen

Display the ClamAV signature date and YARA rule date on the scanning host's pre-login screen — visible to the operator before they log in, without needing to run any command.

## Motivation

The operator workflow already requires running `show-status` immediately after login. The signature date is the single most important piece of information that command provides: it tells the operator whether the data USB is fresh enough to scan with, and it tells the admin (when the operator phones in with a problem) which build of the system is in use.

Putting it on the pre-login screen is a small change with two benefits. First, it shifts a piece of information forward in time: the operator sees the dates before they're committed to a session. If a stale data USB has been loaded by mistake, they can power off and contact the admin without going through login. Second, it makes the screen photographable in the air-gapped room without the operator having to type anything — useful for handover, audit, or sharing with the admin when something goes wrong.

The information is already on the system. This is a display change, not a data change.

## What is currently shown

The CoreOS default pre-login screen shows the standard issue file: hostname, kernel version, login prompt. No project-specific content.

After login, `show-status` displays signature date, YARA rule date, KVM availability, network interface count, and zincati status. This is the right command for the operator to run, but it requires logging in first.

## Target behaviour

Replace `/etc/issue` (or augment it via the Ignition config) with a banner that includes the two dates:

```
Troskel scanner
===============

  Signature date  : 2026-05-09T08:00:00+00:00
  YARA rules date : 2026-05-08T14:00:00+00:00

Log in as 'scanner' to begin.

scanner login: _
```

The dates are read from `/var/lib/troskel/signature-date` and `/var/lib/troskel/yara-rules-date` — the same files `show-status` already uses. If either file is missing (the data USB has not been loaded yet, or the load failed), display `not loaded` in place of the date.

## What changes

The change is in two places:

**`config/host-scripts/load-scanner`** — after copying the freshness files from the data USB to `/var/lib/troskel/`, regenerate `/etc/issue` with the current values. This is the right hook because `load-scanner` runs at boot via the Ignition-installed systemd unit and is already responsible for putting these files in place. Writing `/etc/issue` from this script means the banner is current to the loaded data USB, not to whatever was on the boot USB at build time.

**`config/scanner-host.bu`** — add an `/etc/issue` default that displays a "scanner image not loaded" message, so that if `load-scanner` fails the operator sees something informative rather than a confusing stale value. The default is overwritten by `load-scanner` on success.

No changes to `show-status` itself. The post-login status command remains the canonical, more detailed view; the pre-login banner is the at-a-glance subset.

## Implementation detail

`/etc/issue` is read by `agetty` when it prints the pre-login prompt. The escape sequences `\d`, `\t`, `\s` etc. that agetty interprets are not needed here — plain text is fine. Newlines are literal.

A minimal `load-scanner` addition:

```bash
SIG_DATE="$(cat /var/lib/troskel/signature-date 2>/dev/null || echo 'not loaded')"
YARA_DATE="$(cat /var/lib/troskel/yara-rules-date 2>/dev/null || echo 'not loaded')"

cat > /etc/issue <<ISSUE
Troskel scanner
===============

  Signature date  : ${SIG_DATE}
  YARA rules date : ${YARA_DATE}

Log in as 'scanner' to begin.

ISSUE
```

The `\n` terminator agetty inserts means the prompt itself (`scanner login:`) appears below the banner without further effort.

## Side effects

- `docs/OPERATOR-GUIDE.md` should note that the dates are visible before login, and that `show-status` after login provides the fuller picture. This is a small simplification rather than a rewrite.
- Manual test addition (informal — not necessarily an automated case): boot the scanner with no data USB and confirm the banner shows `not loaded` for both fields rather than a stale value or a crash.
- `check-system-ready` already enforces the freshness gate; this change does not affect that logic. A stale data USB will still fail the check. The pre-login banner just makes the staleness visible earlier.

## Estimated effort

Half a day. The `load-scanner` change is a few lines; the Butane config addition is a few lines; the rest is testing on a real boot to confirm the banner renders as expected.

## Sequencing

No dependencies. Independent of other roadmap items.

Target `1.1.0`. The information is already accessible via `show-status` after login, so this is a usability improvement rather than a correctness fix. Not blocking `1.0.0`, but a clear next step for operator experience once the `1.0.0` operator-experience items (improved verdict output, ClamAV tightening) have landed.

## Open questions

- **Should the banner include the boot USB write date as well?** The boot USB carries its own implicit "last updated" via the embedded passphrase regeneration, but there is no separate freshness file for it. Probably not worth adding — the data USB is the one that needs to be fresh per scan session.
- **Should the banner show the site name (from `output-usb.md`'s `SITE_NAME` config) if set?** Useful in multi-host deployments where the operator might not otherwise know which scanning host they're standing in front of. Easy to add once `output-usb.md` lands and introduces `SITE_NAME`.