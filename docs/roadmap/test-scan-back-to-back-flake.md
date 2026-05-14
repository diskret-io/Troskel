# Back-to-back scan flake in `tests/test-scan.sh`

A back-to-back invocation of `scan-wrap` from `tests/test-scan.sh`
(red scan then green scan, no pause between them) fails on the second
invocation with `Error: RunWithApi(MicroVMStoppedWithError(GenericError))`
before the guest emits any output. Reproduces on commit `b728b7d`
(the last green-CI commit) when the script is run twice in succession.
The flake appears to have escaped CI by virtue of timing variance
rather than by being absent on that commit.

A `sync && sleep 2` between the two scans is currently in
`tests/test-scan.sh` as a temporary mitigation. Removing it
reproduces the failure.

## Motivation

The mitigation is a smell, not a fix. The proper resolution belongs
on the test-pipeline correctness path, not on any feature branch.
Leaving the sleep in indefinitely is acceptable for an internal test
runner but is the wrong shape for a release: a second-scan failure
mode that depends on inter-scan timing also affects any production
flow that runs two scans in close succession, which is a realistic
operator pattern on a busy day.

## Current state

The first scan completes normally: both engines emit verdicts, the
host renders the red verdict, the cleanup trap fires, and the
top-level script exits. The second scan's `scan-wrap` invocation
proceeds through staging, image construction, and the Firecracker
launch; Firecracker then exits with `MicroVMStoppedWithError`
(generic) before the kernel prints. No `ENGINE:` or `VERDICT:` line
is ever emitted by the guest. With `sync && sleep 2` between the
scans the second VM boots normally and the test passes.

The error originates inside Firecracker's `Vm::start` action. The
`GenericError` variant carries no further information; Firecracker's
hypervisor log (`fc-hypervisor.log` in the work directory) is the
next reasonable place to look.

## Target state

The test runs two scans back-to-back without an artificial sleep,
and a third scan immediately after, and so on. Each VM boot is
independent of the previous run's state.

## Implementation outline

The work decomposes into investigation followed by a targeted fix:

1. Reproduce the failure on the affected commit with diagnostic
   output unsuppressed. The current `scan-wrap` redirects
   `mkfs.ext4` stderr to `/dev/null`; the diagnostic run should
   unswallow that and additionally preserve the Firecracker
   hypervisor log between scans rather than letting `cleanup` remove
   it.
2. Inspect the hypervisor log from the failing run. Plausible
   suspects, in decreasing order of likelihood given the symptoms:
   - **Stale `/dev/kvm` state.** Some KVM-host configurations require
     a brief grace period after a VM exits before the next VM can
     allocate. A retry loop on `Vm::start` failure may be the right
     shape; alternatively, an explicit `ioctl` cool-down.
   - **Leftover loop device.** `losetup -a` between the scans will
     show whether `scanfiles.ext4` from the previous run is still
     attached. The cleanup trap removes the work directory but does
     not run `losetup -d`.
   - **Leftover Firecracker artefacts in `/var/lib/troskel/`.** The
     `EPHEMERAL` rootfs lives under `$WORK`, which `cleanup` removes,
     but the base `scanner-rootfs.ext4` could be held open by a
     deferred process.
   - **The `tee -a "$SCAN_LOG")` background subshell.** The `wait
     "$FC_PID"` waits for Firecracker but not for the `tee` process,
     which is in a separate process group. A `tee` that has not
     finished flushing when the next invocation starts could conceivably
     cause a contention pattern.
3. Once the cause is identified, fix it at the right layer. Likely
   candidates: extend the cleanup trap, add a `wait` for the `tee`
   subshell, or add a bounded `Vm::start` retry to `scan-wrap`.
4. Remove the `sync && sleep 2` mitigation from
   `tests/test-scan.sh` and re-verify that the test passes both
   in CI and on a slow developer host (a slow host is more likely
   to absorb the latent issue without a sleep; a fast one less so).

## Side effects

None expected. The fix is in the test runner or in `scan-wrap`'s
cleanup; neither changes the operator-visible workflow or the
verdict pipeline.

## Estimated effort

Half a day to a day. The investigation is the unknown; the fix is
likely one to three lines. If the hypervisor log identifies a
clear cause, this can be done in a single sitting.

## Sequencing

No dependencies. Can land at any point. The mitigation sleep
removes the CI pressure; the proper fix is hygiene work.

Target version: `1.0.0` if convenient, otherwise `1.0.1`. The
mitigation makes this a non-blocker for `1.0.0` shipping.

## Open questions

- **Is the `tee` subshell genuinely a suspect?** The pattern `>
  >(tee -a "$SCAN_LOG") 2>&1` creates a process substitution whose
  lifetime is not directly waited on. A clean wait would be to
  capture the substitution's PID via `coproc` or to use a named
  pipe with explicit reader. Worth investigating before reaching for
  a retry loop.
- **Should `scan-wrap` itself acquire a host-side lock?** Production
  flows could in principle race two `troskel` invocations on the
  same scanning host. The single-operator workflow assumes this
  cannot happen, but a flock on `/var/lib/troskel/scan.lock` would
  be cheap and would surface concurrent-invocation bugs cleanly. The
  test runner's back-to-back pattern is sequential, not concurrent,
  so this would not by itself fix the current flake, but it is
  adjacent hygiene.