# Roadmap: getting more out of ClamAV

The current `clamscan` invocation uses signature matching only. ClamAV has several detection capabilities already shipped in the binary that we don't engage. Enabling them is a low-cost win, same engine, same scan time roughly, broader coverage.

## What is currently done

```
clamscan --recursive --infected --official-db-only=no \
    --database=/var/lib/clamav "$SCANDIR"
```

Pure signature matching. Heuristic flags off, PUA detection off, bytecode signatures default-loaded but unaudited.

## What's worth engaging

**`--heuristic-alerts`**: emits findings for encrypted documents, structural anomalies, broken/truncated executables, phishing-style URL constructs. Currently default-off; the matches go to a separate heuristic-alerts category that we'd treat as threats.

**`--detect-pua`**: flags Potentially Unwanted Applications: bundleware, adware, hack tools, dual-use utilities. Useful for transfer-scan because dual-use tools (network scanners, password recovery, remote access) often arrive disguised as innocuous content. Brings false positives, calibration needed.

**Bytecode signatures** (`.cbc` files in the signature database). ClamAV ships compiled bytecode that runs heuristic logic against scanned files: entropy analysis, packer unpacking, format-aware detection. Already loaded if present in the database directory. Worth confirming `bytecode.cvd` is reaching the guest rootfs (it should, it's in the `.cvd` glob in `download-latest-signatures.sh`).

**`--max-scansize` and `--max-filesize`**: currently default. The default `--max-filesize` is 100 MB; anything larger is silently skipped. For a transfer scanner the silent-skip is a false-negative vector, same concern as we hit with LOKI-RS's `--max-file-size 0`. Set both to a large explicit value (e.g. 4 GiB).

**`--alert-encrypted`, `--alert-encrypted-archive`, `--alert-encrypted-doc`**, flag encrypted content as suspicious by default. For air-gap transfer this is appropriate behaviour: an encrypted ZIP that the scanner can't inspect should not pass as clean.

**`--alert-broken`, `--alert-broken-media`**: flag malformed PE/ELF/media files. Often a deliberate evasion technique against signature scanners.

## What to avoid

`--detect-broken` and other auto-quarantine flags. Don't quarantine; report. The host wrapper handles the verdict pipeline.

`--scan-mail`, `--scan-html`, `--scan-pdf` — already on by default. No need to set explicitly.

## Implementation outline

1. Update the `clamscan` invocation in `guest/run-scan.sh` (the real location; an earlier draft of this doc mis-identified it as `build-scanner-image.sh`, which only installs ClamAV, it doesn't run it).
2. Verify the per-engine summary parser still works — heuristic alerts produce output lines that may differ from the standard `path: signature FOUND` format. May need to adjust the count grep.
3. Add a `tests/files/encrypted-test.zip.b64` fixture: a deliberately encrypted ZIP that exercises the `--alert-encrypted-archive` path. Confirms the new flags actually fire. A malformed-PE fixture for `--alert-broken` is a candidate follow-up.
4. Document the false-positive rate observed in initial deployment. Consider whether any flags need to be disabled if they prove too noisy on legitimate transfers.
5. Note in `docs/SECURITY.md` that the scanner now flags encrypted content as suspicious — operationally significant for the operator, who needs to know that "encrypted ZIP from a trusted sender" will produce a red verdict.

## Estimated effort

Small. Half a day, mostly spent on the test fixture and calibration. No architectural changes.

## Sequencing

Independent of the other roadmap items. No dependencies.

Target `1.0.0`. Engaging these flags is `1.0.0`-grade hardening: same engine, same scan time, broader coverage of exactly the threats a transfer scanner should catch (encrypted archives, malformed PEs, dual-use tools). Shipping `1.0.0` while ClamAV runs in signature-only mode would mean leaving free detection capability on the table.

The new `--alert-encrypted` and `--alert-broken` flags will produce visible behavioural change — legitimate password-protected archives and structurally unusual PEs that previously passed as green will now go red. The verdict-display refactor needed to make this behavioural change usable for operators (showing flagged filenames on screen rather than requiring a `grep` command) has already landed in `main`, so operators will see *what* was flagged when the new flags fire.

## Open questions

- Should encrypted-content alerts be a separate verdict tier (yellow) rather than red? Treating them as threats is the conservative default but may produce too many false-positive reds on legitimate password-protected archives.
- Should bytecode signatures be explicitly enabled, or is the default behaviour sufficient? Worth reading the ClamAV bytecode documentation before deciding.
- Should `--detect-pua` be enabled? Brings false positives on legitimate dual-use tools. The current decision is to leave it disabled in the initial clamav-tightening commit and revisit post-`1.0.0` with operator feedback. Discussed further in the commit message of that work.