# Manual scan tests

`test-scan.sh` covers the two happy paths (red on EICAR, green on a clean directory). The cases below are harder to automate cleanly but matter to the verdict pipeline's correctness — work through them by hand after any change to `scan-wrap`, the guest entrypoint, the cleanup trap, or the Firecracker JSON.

Run on a Debian or Ubuntu dev host with `/dev/kvm` accessible. Each session starts by copying `scan-wrap` from its source location:

```bash
cp config/host-scripts/scan-wrap /tmp/scan-wrap
chmod +x /tmp/scan-wrap
```

All checks below are run as root.

## Yellow path — empty log

Kill Firecracker before the guest emits anything. The log should be empty or truncated, and the wrapper should print the yellow block.

```bash
sudo /tmp/scan-wrap tests/files/ &
sleep 2 && sudo pkill -9 firecracker
```

**Expect:** yellow block, no `VERDICT:` line in the log, exit cleanly (no leftover loop devices — check `losetup -a`).

## Yellow path — unrecognised guest output

Modify the copied `/tmp/scan-wrap` to emit a junk verdict line, then run it:

```bash
sudo sed -i 's/VERDICT: CLEAN/VERDICT: BANANA/' /tmp/scan-wrap
```

**Expect:** yellow block. Restore `/tmp/scan-wrap` afterwards (re-copy from `config/host-scripts/scan-wrap`).

## ClamAV error path

Corrupt the signature DB inside the rootfs to force a ClamAV exit code other than 0 or 1:

```bash
# Mount the rootfs and zero out main.cvd, or rebuild with a deliberately broken signature dir.
```

**Expect:** `VERDICT: ERROR (clamav=error loki=clean)` in the log; yellow block on the host. The per-engine summary should show `ClamAV : ERROR` and `LOKI-RS : clean`.

## LOKI-RS error path

Corrupt the YARA rule directory inside the rootfs (or remove it) to force LOKI-RS to fail:

```bash
# Mount the rootfs and remove /opt/loki-rs/signatures, or replace it with garbage.
```

**Expect:** `VERDICT: ERROR (clamav=clean loki=error)` in the log; yellow block on the host. Per-engine summary should show `ClamAV : clean` and `LOKI-RS : ERROR`.

## Cleanup trap on SIGINT

Start a scan, Ctrl-C it, then check that the workdir, loop device, and API socket are gone:

```bash
sudo /tmp/scan-wrap tests/files/
# Ctrl-C during the scan
ls /tmp/scan-wrap-* 2>/dev/null            # should be empty
sudo losetup -a | grep scanfiles         # should be empty
ls /tmp/troskel-*.socket 2>/dev/null     # should be empty
```

**Expect:** all three checks return nothing.

## Resource exhaustion

Point the scanner at a directory with a known zip bomb (e.g. `42.zip`). The guest has 2048 MiB; expect either an engine to detect/refuse it, or the guest to OOM and reboot, producing yellow.

**Expect:** red (detected) or yellow (OOM). Never green.

## Read-only enforcement

After a scan, confirm the file USB image was not modified. The host loop device is read-only and the hypervisor honours `is_read_only`, but a regression in either layer would let the guest write through.

```bash
sha256sum tests/files/EICAR.txt   # before
sudo /tmp/scan-wrap tests/files/
sha256sum tests/files/EICAR.txt   # after — must match
```

**Expect:** identical hashes.

---

When any of these fails, capture the scan log and the hypervisor log (`/tmp/scan-wrap-*/fc-hypervisor.log`, before the cleanup trap fires — easiest is to add `set -x` to your `/tmp/scan-wrap` copy and rerun) and record the finding in `docs/MAINTENANCE.md`.