# Improved screen output on non-green verdicts

Currently `scan-wrap` prints the verdict block and tells the operator to run `grep FOUND` on a log path to see what was flagged. That is too technical for an operator — they should see the flagged filenames immediately on screen without needing to know what tool to run or where the log lives.

## Current behaviour

On a red verdict the operator sees:

```
************************************************
   *** THREAT DETECTED — DO NOT TRANSFER ***
************************************************

  ClamAV   : THREAT (3 flagged)
  LOKI-RS  : clean

Full log: /var/log/troskel/scan-20260510T123456Z.log
For flagged item details:  grep -E 'FOUND$|"level":"ALERT"' "/var/log/troskel/..."
```

The operator is expected to run a grep command. Most operators will not know how to do this, and some will not be able to read the log at all.

On a yellow verdict the operator sees the log path and nothing else useful.

## Target behaviour

**RED verdict** — immediately below the verdict block, display the flagged filenames:

```
************************************************
   *** THREAT DETECTED — DO NOT TRANSFER ***
************************************************

  ClamAV   : THREAT (3 flagged)
  LOKI-RS  : clean

Flagged by ClamAV:
  /scanfiles/transfers/invoice.pdf   Win.Trojan.Agent-12345
  /scanfiles/transfers/setup.exe     Win.Trojan.Agent-12346
  /scanfiles/transfers/data.zip      Heuristics.Encrypted.Archive

Do not transfer any files from this USB.
Full log: /var/log/troskel/scan-20260510T123456Z.log
```

**YELLOW verdict** — display a short explanation of what yellow means rather than just a log path:

```
************************************************
   *** RESULT UNCLEAR — Contact admin ***
************************************************

  ClamAV   : no result
  LOKI-RS  : no result

The scanner did not complete normally. The files have NOT been scanned.
Do not transfer them.

Contact the admin with this information:
  Log: /var/log/troskel/scan-20260510T123456Z.log
  (Photograph this screen before powering off — the log is lost on shutdown)
```

**GREEN verdict** — unchanged by default. The log path is shown quietly at the bottom for anyone who wants to verify. No new output.

## What changes

`config/host-scripts/scan-wrap` — the verdict display section at the bottom of the script. Two additions:

1. After the red verdict block, extract and display ClamAV `FOUND` lines and LOKI-RS `ALERT` records from the scan log in a readable format. Strip the log timestamp prefix and format as a simple list. Truncate at 20 items if the list is very long, with a "and N more — see full log" notice.

2. After the yellow verdict block, replace the terse "No recognisable verdict in log" message with a plain-language explanation of what yellow means and what the operator should do.

The `summarise_engine()` function is unchanged. The log format is unchanged. Only the display logic at the end of the file changes.

## Implementation detail

ClamAV finding lines have the format:
```
/mnt/scanfiles/path/to/file: SignatureName FOUND
```

Extract with:
```bash
grep ' FOUND$' "$SCAN_LOG" \
    | sed 's|/mnt/scanfiles/||; s|: | — |' \
    | head -20
```

LOKI-RS ALERT lines are JSONL. Extract the file path and rule name with:
```bash
grep '"level":"ALERT"' "$SCAN_LOG" \
    | python3 -c 'import sys,json; [print(f"  {j[\"file\"]} — {j[\"rule\"]}") for l in sys.stdin for j in [json.loads(l)]]' \
    2>/dev/null | head -20
```

The Python dependency is acceptable here — it is already present in the Debian guest and the scan-wrap script runs on the scanning host (CoreOS), which ships Python. If Python is unavailable for any reason, fall back to showing the raw JSONL lines truncated to 120 characters.

## Side effects

- `docs/OPERATOR-GUIDE.md` no longer needs to explain the `grep` command for finding flagged files — the operator sees them directly. Simplify that section.
- `tests/test-scan.sh` should assert that flagged filenames appear in the output of `scan-wrap`, not just that `VERDICT: THREAT DETECTED` is present. This makes the test more meaningful.

## Estimated effort

Two to three hours. The display logic is straightforward; the main care is ensuring the log parsing does not break if the log is empty, truncated, or contains unexpected characters from a hostile filename.

## Sequencing

Independent. Can land at any time. Should land before `1.0.0` — this is the operator's primary interaction with the system on a bad day, and the current experience is not good enough.

## Open questions

- **Should the LOKI-RS JSONL parser be Python or pure shell?** Python is more robust but adds a dependency assumption. A pure-shell parser using `grep` and `sed` can extract the `file` and `rule` fields from well-formed JSONL without Python, though it is fragile against edge cases (filenames with quotes or backslashes). Start with Python and fall back to the truncated raw line if Python fails.
- **How many findings to show before truncating?** 20 is suggested above. If a scan produces 200 findings, showing all of them scrolls the operator's terminal and buries the verdict. 20 is enough to communicate the scope of the problem without overwhelming.
- **Should the finding list be shown on yellow too?** Yellow means the scanner did not complete — there are no findings to show. The explanation text is sufficient.