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

1. Update the `clamscan` invocation in the embedded `run-scan.sh` (in `build-scanner-image.sh`) to enable the recommended flags above.
2. Verify the per-engine summary parser still works — heuristic alerts produce output lines that may differ from the standard `path: signature FOUND` format. May need to adjust the count grep.
3. Add a `tests/files/clamav-heuristic-test.txt` fixture: a deliberately malformed PE or encrypted ZIP that exercises the heuristic path. Confirms the new flags actually fire.
4. Document the false-positive rate observed in initial deployment. Consider whether any flags need to be disabled if they prove too noisy on legitimate transfers.
5. Note in `docs/SECURITY.md` that the scanner now flags encrypted content as suspicious — operationally significant for the operator, who needs to know that "encrypted ZIP from a trusted sender" will produce a red verdict.

## Estimated effort

Small. Half a day, mostly spent on the test fixture and calibration. No architectural changes.

## Open questions

- Should encrypted-content alerts be a separate verdict tier (yellow) rather than red? Treating them as threats is the conservative default but may produce too many false-positive reds on legitimate password-protected archives.
- Should bytecode signatures be explicitly enabled, or is the default behaviour sufficient? Worth reading the ClamAV bytecode documentation before deciding.