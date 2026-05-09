# Gate YARA-rule freshness in `check-system-ready`

The readiness check enforces a 30-day age limit on ClamAV signatures but not on YARA rules, even though `download-yara-rules.sh` records a refresh date for exactly this purpose. The asymmetry is documented in `SECURITY.md` ("YARA Forge rule freshness is recorded under `/var/lib/troskel/yara-rules-date` but not currently enforced") but not justified, it is an oversight rather than a deliberate design choice, and a scanner image built with stale rules currently passes the readiness check.

## What is currently done

`check-system-ready` reads `/var/lib/troskel/signature-date` and computes its age in days against a 30-day threshold. The corresponding `/var/lib/troskel/yara-rules-date` file exists, is written by `download-yara-rules.sh`, and is propagated to the data USB by `prepare-data-usb.sh` — except it is not, in fact, currently copied. `prepare-data-usb.sh` copies `signature-date` but not `yara-rules-date`. So the freshness file exists on the build station and inside the rootfs but never reaches the scanning host's filesystem at the path `check-system-ready` would inspect. This bug needs fixing as part of this task.

## What changes

Three coupled changes:

1. **`prepare-data-usb.sh`** — add `yara-rules-date` to the list of files copied to the data USB.
2. **`load-scanner` (in `config/scanner-host.bu`)**, add `yara-rules-date` to the files copied from the data USB to `/var/lib/troskel/`.
3. **`check-system-ready`** (both the embedded copy in `scanner-host.bu` and the standalone copy in `scripts/`, until the duplication is resolved separately), add an eighth check, structurally identical to the existing signature-freshness check, against `/var/lib/troskel/yara-rules-date`.

Skeleton of the new check:

```sh
if [ -f /var/lib/troskel/yara-rules-date ]; then
    YARA_DATE="$(cat /var/lib/troskel/yara-rules-date)"
    YARA_EPOCH="$(date -d "$YARA_DATE" +%s 2>/dev/null || echo 0)"
    YARA_AGE_DAYS=$(( (NOW_EPOCH - YARA_EPOCH) / 86400 ))
    check "YARA rules date present and fresh (age: ${YARA_AGE_DAYS} days)" \
        "$([ "$YARA_AGE_DAYS" -le 30 ] && echo ok || echo "rules are ${YARA_AGE_DAYS} days old — run update")"
else
    check "YARA rules date present" "not found"
fi
```

`NOW_EPOCH` already exists from the ClamAV check; the second check reuses it.

## Why 30 days is the right threshold here too

The ClamAV threshold was chosen as "short enough that signatures are reasonably current but without allowing too much drift". The same argument applies to YARA Forge rules — the corpus updates frequently, but a 30-day-old rule set is still meaningfully useful, and tightening below that would push admin toil up without a corresponding security gain on a system whose update cadence is anchored to physical USB transport. Using the same threshold also keeps the readiness check's mental model simple: a scanner image is fresh, or it isn't, with one age limit applying to both.

If experience shows YARA rules deserve a different cadence — either tighter because the upstream moves faster, or looser because operationally the two updates always travel together — the threshold can be split into two variables (`SIG_MAX_AGE_DAYS` and `YARA_MAX_AGE_DAYS`) at that point. Premature for now.

## Side effects

- A scanning host with up-to-date ClamAV signatures but stale YARA rules will now fail the readiness check. This is the intended behaviour but should be flagged in `SECURITY.md` as a change in operator-visible failure modes.
- The duplication between the embedded and standalone copies of `check-system-ready` becomes one notch more painful: both files need the new check added in lockstep. This is independent justification for resolving the duplication (currently deferred under `extract-butane-scripts.md`), and arguably makes that task higher-priority than its current sequencing suggests.
- `tests/test-build.sh` and the manual-test recipes do not currently exercise `check-system-ready` — the readiness check is run on the scanning host, not the build station. No automated test changes are strictly required, but a test fixture that backdates `yara-rules-date` to >30 days and confirms `check-system-ready` correctly fails would be valuable. The same fixture pattern would also retroactively cover the existing ClamAV freshness check, which is currently untested.

## What stays the same

The `download-yara-rules.sh` and `run-update.sh` scripts are unchanged — they already produce `yara-rules-date`. The fix is downstream of the producer, on the consumer side. The verdict pipeline is unaffected.

## Estimated effort

Two to three hours. The check itself is mechanical; the bulk of the time is the bug fix in `prepare-data-usb.sh` and `load-scanner`, plus updating `SECURITY.md` to remove the now-resolved residual risk and re-running the test pipeline to confirm nothing regresses.

## Sequencing

Independent of the other roadmap items. Lands cleanly before or after the Butane and guest-script extractions; sequence-wise, doing it before those extractions is slightly easier (only two `check-system-ready` copies to keep in sync, rather than three places where the check might live mid-extraction).

Should land before 1.0.0. The asymmetry between gated and ungated freshness is exactly the kind of small inconsistency that erodes confidence in the wider security story when a reader notices it.

## Open questions

- **Should `yara-rules-date` and `signature-date` be unified into a single `freshness-date` file recording the timestamp of the most recent end-to-end update run?** This would simplify the readiness check (one age, not two) at the cost of losing per-component diagnostic information when an update partially fails. The current two-file design is the more honest one — it surfaces "ClamAV is fresh but YARA isn't" as a distinguishable state — and probably the right design. But worth noting the alternative exists.
- **Is the 30-day threshold the right number for YARA rules specifically, or just convenient?** Genuinely an open question. The current answer is "same as ClamAV, by analogy"; a stronger answer would come from reviewing YARA Forge's release cadence and the rate at which rule additions cover novel threats. Out of scope for this task as written, but the threshold should be revisited when there is real operational data.