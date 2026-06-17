# Automating the manual test cases

`tests/manual-tests-scan.md` documents seven test cases that the automated suite does not cover: yellow path (empty log), yellow path (unrecognised guest output), ClamAV error path, LOKI-RS error path, cleanup trap on SIGINT, resource exhaustion, read-only enforcement, and the freshness gate. They sit in a markdown file because each one was, at the time it was written, harder to automate cleanly than to perform by hand.

That assessment is correct for some of the seven and convenient-but-wrong for others. This task scopes which of them are worth automating now, what the automation costs, and which should stay manual on their merits rather than by inertia.

## Why this is a scoping document, not a build spec

Unlike the other roadmap items, this one does not arrive with a pre-formed implementation. The first deliverable is a triage decision per case, with the implementation following from it. Writing the triage decisions down as the task is half of the actual work.

The cases split into three groups by automation feasibility:

**Mechanically automatable.** The test conditions are fully reproducible in a standard CI environment, the success criterion is a string match on the verdict, and the test takes seconds rather than minutes.

**Automatable with cost.** The test conditions are reproducible but require setup that the existing automated tiers don't do (mounting and modifying a rootfs, generating malformed inputs, simulating hardware-level conditions). The automation is possible but the maintenance cost may exceed the value.

**Genuinely manual.** The test condition involves hardware behaviour or non-determinism that cannot be reliably reproduced in CI. Automating these would either produce flaky tests (worse than no test) or trivially-passing tests (worse than the manual procedure).

## Triage

### Freshness gate — stale signatures
**Group: mechanically automatable.** The manual procedure already shows the recipe: backdate `/var/lib/troskel/signature-date` and `/var/lib/troskel/yara-rules-date`, run `check-system-ready`, expect two FAIL lines and a non-zero exit. The test runs against the scanning host's `check-system-ready` directly; no KVM, no Firecracker, no scanner image needed. Tier 1 (`test-validate.sh`) can run it.

The test should exercise each threshold independently (stale ClamAV only, fresh YARA; and vice versa) to confirm the gates are genuinely independent — the manual document already flags this as worth testing, and an automated version makes it tractable to do on every commit.

### Cleanup trap on SIGINT
**Group: mechanically automatable, but only on a KVM host.** Start `scan-wrap`, send SIGINT after a short delay, then assert that the workdir, loop device, and API socket are gone. Tier 3 (`test-scan.sh`) is the natural home — it already needs `/dev/kvm` for the existing red and green path tests. The new assertion is three `ls` invocations that should return nothing, plus a `losetup -a | grep scanfiles` check.

The one subtlety is timing the SIGINT to land *during* the scan, not before Firecracker has started or after it has exited. A `sleep` is fragile. The robust approach is to poll for the API socket's existence in a tight loop, then signal the second the socket appears. That gives the same coverage as the manual `sleep 2 && pkill -9` without the flakiness.

### Read-only enforcement
**Group: mechanically automatable.** Hash the EICAR file before the scan, run the scan, hash it again, assert identical. The manual procedure is already a three-line shell sequence; lifting it into `test-scan.sh` is straightforward and the assertion is exact (hashes match) rather than probabilistic.

This test is more valuable automated than manual: it is exactly the kind of property that breaks silently from an unrelated change (a regression in `losetup` flags, a hypervisor config mistake), and a manual procedure that catches such regressions only when someone happens to remember to run it is not really a safeguard. CI catching it on every commit is.

### Yellow path — unrecognised guest output
**Group: automatable with cost.** The manual procedure modifies `/tmp/scan-wrap` to emit `VERDICT: BANANA` instead of `VERDICT: CLEAN`. The automated equivalent is to do the same modification on a copy of `scan-wrap` before invoking it, then run a scan and assert the host wrapper prints the yellow block.

The cost is in keeping the modification path robust. The current `sed 's/VERDICT: CLEAN/VERDICT: BANANA/'` works as long as that exact string appears in `scan-wrap`. If `scan-wrap` is refactored such that the string is constructed rather than literal, the modification silently no-ops. The robust automation is to inject the unrecognised verdict from the guest side — make a one-line variant of `guest/run-scan.sh` that emits `VERDICT: BANANA` unconditionally, build a rootfs with it, and run a scan. That works but adds a build step. Worth doing once and keeping; not worth doing every commit.

The right shape is: a separate `tests/test-yellow-paths.sh` that builds an "unrecognised-verdict" rootfs and a "no-verdict" rootfs as fixtures, then runs scans against each. Slow (a minute or two for the rootfs builds), so it should not run on every commit; gate it behind an explicit `make test-yellow` invocation and run it before each release.

### Yellow path — empty log
**Group: automatable with cost.** Same approach as above — a one-line variant rootfs that exits before emitting anything. Same shape, same cost. Lives in the same `test-yellow-paths.sh` if the previous case is automated.

### ClamAV error path / LOKI-RS error path
**Group: automatable with cost, possibly not worth it.** The manual procedures involve modifying the rootfs to corrupt the signature DB or remove the YARA rule directory. The automated equivalent is straightforward but requires the same fixture-rootfs machinery as the yellow paths above.

The value of automating these is lower than the yellow paths: a corrupted signature DB or missing rule directory is a build failure, not a runtime regression that could plausibly creep in unnoticed. `build-scanner-image.sh` already sanity-checks the presence of these directories before debootstrap. The realistic failure mode the test catches is "we changed the verdict-combination logic and broke the error path"; that's a real concern but it's covered by other paths through the verdict pipeline.

Recommend: leave as manual for now, document the recommendation explicitly so the next contributor doesn't re-evaluate from scratch.

### Resource exhaustion (zip bomb)
**Group: genuinely manual.** A 42.zip OOM-kill is hardware-dependent: it depends on the guest's memory ceiling, the host's swap behaviour, and the kernel's OOM scoring. CI environments tend to have generous memory ceilings and disable swap, neither of which matches the deployed scanning host. An automated test that passes in CI but fails on real hardware (or vice versa) is worse than no test — it gives false confidence.

Leave manual. The case is valuable to perform before each release on representative hardware, but adding it to CI would degrade rather than improve the test pipeline.

## Summary

| Case                               | Triage          | New home                    |
|------------------------------------|-----------------|-----------------------------|
| Freshness gate (stale signatures)  | Automate        | `test-validate.sh` (Tier 1) |
| Cleanup trap on SIGINT             | Automate        | `test-scan.sh` (Tier 3)     |
| Read-only enforcement              | Automate        | `test-scan.sh` (Tier 3)     |
| Yellow path — empty log            | Automate, gated | `test-yellow-paths.sh`      |
| Yellow path — unrecognised verdict | Automate, gated | `test-yellow-paths.sh`      |
| ClamAV error path                  | Leave manual    | (no change)                 |
| LOKI-RS error path                 | Leave manual    | (no change)                 |
| Resource exhaustion (zip bomb)     | Leave manual    | (no change)                 |

After the changes land, `tests/manual-tests-scan.md` is shorter: three test cases remain (the two engine error paths and the zip bomb), with a paragraph at the top explaining what was automated and where it now lives.

## Estimated effort

The freshness-gate automation is half a day, mostly in writing the test fixture for the date-restoration step so the test does not leave the host in a broken state.

The cleanup-trap and read-only automations together are half a day; they are small additions to `test-scan.sh` and the only real subtlety is the SIGINT timing.

The `test-yellow-paths.sh` fixture is the biggest single piece — one day, almost entirely in the rootfs build path. Building two variant rootfs images means two extra debootstraps (or, more efficiently, a shared base rootfs that gets two different `run-scan.sh` overlays — the same shared-base pattern that `parallel-engines.md` already proposes). If `parallel-engines.md` lands first, this work piggybacks on the shared-base machinery. If it lands first, it builds its own.

Total: two days, including documentation updates to `manual-tests-scan.md` and `tests/README.md`.

## Sequencing

No hard dependencies on other roadmap documents. If `parallel-engines.md` has landed by the time this work starts, the yellow-paths fixture can use the shared-base rootfs builder rather than reimplementing it; if not, the fixture introduces a smaller version of the same pattern that `parallel-engines.md` would later subsume.

Target `1.1.0`. The freshness-gate automation specifically is more valuable than the others — it covers a fail-open path that, if it regresses, produces silent green verdicts on stale signatures. If `1.1.0` slips, the freshness-gate piece is worth pulling forward into `1.0.0` as a half-day addition to `test-validate.sh`. The rest of the work can wait.

## Open questions

- **Should `test-yellow-paths.sh` be a fourth `make` target?** The existing tiers (`validate`, `build`, `scan`) are organised by "what privileges and hardware are needed". The yellow-paths work fits Tier 3 (needs KVM, needs build artefacts) but takes longer than the other Tier 3 tests. A fourth tier — `make release-tests`, run before each release rather than on every commit — would be the honest categorisation. Decide when the script is written, not now.
- **Does automating the freshness gate make the manual procedure redundant?** No: the manual procedure documents the recovery path (`date -u --iso-8601=seconds > /var/lib/troskel/signature-date`) which the automated test does not exercise. Keep the recovery instructions in `manual-tests-scan.md` even after the gate itself is automated.
- **CI runtime budget.** Two more checks in Tier 1 (freshness gate) and two more in Tier 3 (cleanup trap, read-only enforcement) probably add ten to twenty seconds to each tier. Acceptable. The yellow-paths tier is the one that needs an explicit budget call — if it grows past five minutes it should not run on every commit.