# Roadmap: capa as a third engine

Capa adds detection diversity that ClamAV and LOKI-RS don't currently provide. The engines we already have are both pattern-based (signatures, YARA rules). Capa is *capability-based*, it identifies what an executable can do (network access, persistence, anti-analysis, credential theft, etc.) by combining file features with disassembly-derived behaviours. A genuinely orthogonal detection paradigm.

Source repos:
- Engine: https://github.com/mandiant/capa
- Rules: https://github.com/mandiant/capa-rules
- Test fixtures: https://github.com/mandiant/capa-testfiles

## What capa is and isn't

**Is:** Static analysis of executables. Recognises >890 capabilities (per current bundled ruleset) mapped to MITRE ATT&CK and MAEC.

**Isn't:** A general-purpose file scanner. Capa only handles executable formats: PE (Windows), ELF (Linux), .NET, shellcode, and a handful of others. It cannot inspect documents, archives, or arbitrary content. It does not replace LOKI-RS or ClamAV; it complements them.

**Output model:** Capa reports *capabilities*, not threats. A binary may "create a process" (capability) without being malware. Mapping capabilities to threat verdicts is a policy decision the integrator makes.

## Why this fits the architecture

- Static, no execution. Same safety property as ClamAV and LOKI-RS — adversarial input is parsed but not run. The hypervisor boundary remains the only thing between the parsers and the host.
- Standalone Linux binary (PyInstaller-bundled). No Python install needed in the guest rootfs. Pinned to a specific version like LOKI-RS.
- Embedded ruleset (~890 rules) ships with the binary. Equivalent to LOKI-RS bundling YARA Forge, refresh by bumping the binary version, no second update path required.
- JSON output via `-j` flag. Same parsing pattern as LOKI-RS's JSONL.
- Apache 2.0 licence (more permissive than LOKI-RS's GPLv3).
- Maintained by Mandiant / Google, more durable upstream than a one-person side project.

## Integration outline

1. **Bundle the binary into the rootfs.** Add `CAPA_VERSION` to `config/versions.env`. Extend `prepare-build-machine.sh` to download the standalone Linux binary, install to `/opt/capa/`. Extend `build-scanner-image.sh` to copy it into the rootfs.
2. **Wrap capa in a per-file loop in the guest entrypoint.** Capa analyses one file at a time. The wrapper walks `$SCANDIR`, identifies executable formats by magic byte, and invokes capa for each. Skip everything that isn't PE/ELF/.NET (capa would refuse anyway).
3. **Define a capability-to-verdict policy.** Most capabilities aren't threats. The reasonable default is to treat *combinations* as threats: e.g. "anti-debug AND credential-theft AND network-c2" is a clear malware fingerprint; any one alone might be legitimate. The exact rule set needs calibration against real-world transfers. Conservative starting point: any rule in the `nursery/` namespace is research-grade and should not produce a verdict; anything in `att&ck/persistence/`, `att&ck/defense-evasion/`, `att&ck/credential-access/`, `att&ck/exfiltration/`, `att&ck/impact/` produces a verdict. Tunable.
4. **Wire into the verdict pipeline.** Emit `ENGINE: capa status=<clean|threat|error> count=<N>` alongside the existing engines' lines. The host wrapper's `summarise_engine` helper takes a third call. Verdict combination stays OR — any engine flagging produces red.
5. **Per-engine summary in the host wrapper.** `summarise_engine "capa" "capa"`. Three lines under the verdict block instead of two.

## Test fixtures

The capa-testfiles repo contains binaries known to trigger specific capabilities. For our purposes we need:
- One binary that triggers a capability we've classified as a threat (red path).
- One binary that triggers only benign capabilities (green path — capa runs but no findings cross the threshold).
- A non-executable file (txt, image) — capa should skip cleanly without erroring.

Don't bundle capa-testfiles into the repo; it includes real malware samples in some directories. Instead, document the URL of specific test files and have `tests/test-scan.sh` download them when run, into a gitignored `tests/files/capa-samples/` directory. Or pick small, known-safe samples and bundle just those. Decide before implementing.

## Estimated effort

Larger than the ClamAV tightening. Two to three days, broken down:
- ~half day: build-machine and rootfs bundling
- ~one day: guest-entrypoint integration, format detection, per-file loop, JSON parsing
- ~half day: capability-to-verdict policy and calibration
- ~half day: test fixtures and CI integration

## Open questions

- **Capability-to-verdict policy.** This is the hard part and the place where the project takes on real opinion. A too-liberal policy floods the operator with false-positive reds; a too-conservative policy makes capa's contribution irrelevant. Worth prototyping against a corpus of known-good and known-bad transfers before committing.
- **Scan time.** Capa's static analysis is slower than YARA — disassembly is non-trivial. For a directory of 100 binaries, expect minutes, not seconds. Combined with ClamAV and LOKI-RS, total scan time may approach the operator's patience threshold. Consider running capa only on files that the first two engines cleared (a "third pass" model) rather than all three engines walking the full tree.
- **Memory footprint.** Capa's disassembly is memory-hungry. The current 2048 MiB guest may be tight; bumping to 4096 MiB is probably cheap but should be measured.
- **Capa's "this sample appears to be packed" warning.** Static capa is less useful against packed binaries (it says so itself). Whether the warning alone constitutes a verdict signal, or whether it should produce yellow rather than red, is a policy call.
- **Architecture limitation.** Capa is a third *static* engine. The "detection diversity" point in `docs/ARCHITECTURE.md` would gain a real basis — capability-based vs pattern-based, but the system still cannot detect novel obfuscation that defeats both approaches. This is a real ceiling, recorded honestly in `SECURITY.md`.