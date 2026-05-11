# SBOM automation

The CycloneDX SBOM at `SBOM.json` is currently hand-maintained: when a version pin changes in `config/versions.env`, someone has to remember to update the corresponding component entry in the SBOM. This is fragile, easy to miss, and the symptom of the gap is exactly the kind of detail an external auditor looks for. Automate the SBOM so that it is generated from `versions.env` (and the other authoritative sources) rather than copied alongside them.

## What is currently in the SBOM

`SBOM.json` is a CycloneDX 1.6 document with three rough categories of content:

- **Static facts.** Project metadata (name, version, licence, supplier), architectural properties (`detection-engines`, `virtualization`, `persistence`), the SBOM serial number. These do not change between builds.
- **Pinned-component versions.** Firecracker `1.7.0`, LOKI-RS `2.10.0`, CoreOS `1.5.0`, Debian `trixie`, etc. These mirror values in `config/versions.env` and currently must be updated in two places.
- **Floating-component placeholders.** ClamAV `"version": "latest"`, Butane `"version": "latest"`, coreos-installer `"version": "release"`, ClamAV signatures `"version": "dynamic"`, YARA Forge rules `"version": "dynamic"`. These are placeholders for components whose exact version is resolved at build time but not currently captured.

The drift problem is acute for the second category: if `FC_VERSION` in `versions.env` is bumped to `v1.8.0` and the SBOM is not updated to match, the project ships a build that does not match its own bill of materials.

## What automation looks like

A script — call it `scripts/generate-sbom.sh` — that reads from authoritative sources and emits `SBOM.json`. The authoritative sources are:

- `config/versions.env` for pinned versions (FC_VERSION, LOKI_VERSION, DEBIAN_RELEASE, etc.) and for the documented categories (PINNED, FLOATING, DERIVED).
- The build-station state at `/var/lib/troskel/` for resolved-at-build-time versions: the actual kernel filename resolved by `download-kernel.sh`, the signature freshness dates, the actual Butane release tag resolved when `BUTANE_VERSION="latest"`.
- A small static block within the script for project metadata (name, licence, suppliers, architectural properties) that genuinely does not vary.

The script emits a fresh `SBOM.json` to stdout (or to a path given as an argument). It does not edit the existing file in place — that would lose the audit trail of "what changed when". `run-update.sh` calls it as a final step after the build artefacts are ready, so the SBOM is always regenerated alongside a fresh data USB.

## Coupling with `checksum-verification.md`

This task is closely coupled with `checksum-verification.md`. That roadmap document already prescribes SBOM changes as part of its scope:

> Update `SBOM.json`: replace `latest` and `release` placeholders with concrete versions for the now-pinned components, and add a `hashes` block to each component carrying the SHA-256.

In the manual-SBOM world, those changes would have been edited in by hand. With SBOM automation in place, the same outcomes happen via the generator: it reads the recorded SHA-256s from `versions.env` (which `checksum-verification.md` introduces) and emits them as `hashes` blocks per component.

The two tasks therefore split cleanly:
- `checksum-verification.md` is responsible for *recording* the checksums and concrete versions in `versions.env`.
- This task is responsible for *materialising* those records as a regenerated SBOM.

Land them together. Either one alone is incomplete: checksum verification without SBOM automation leaves the SBOM update as manual catch-up work; SBOM automation without checksum verification has nothing useful to emit beyond what is in the file today.

## What the generator looks like

A reasonable shape, in pseudocode:

```bash
#!/usr/bin/env bash
# scripts/generate-sbom.sh
# Regenerates SBOM.json from authoritative sources. Run as the final
# step of run-update.sh, after all download and build scripts have
# populated /var/lib/troskel/.
set -euo pipefail

source config/versions.env

# Resolve floating versions to concrete tags by inspecting the
# build-station state.
BUTANE_RESOLVED="$(/usr/local/bin/butane --version | awk '{print $NF}')"
KERNEL_VERSION="$(basename $(readlink -f /var/lib/troskel/vmlinux) \
                  | grep -oP 'vmlinux-\K[0-9]+\.[0-9]+\.[0-9]+')"
SIG_DATE="$(cat /var/lib/troskel/signature-date)"
YARA_DATE="$(cat /var/lib/troskel/yara-rules-date)"

# Emit the SBOM. The structure is a heredoc rather than a templating
# engine to keep the dependency footprint at zero.
cat <<JSON
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  ...
}
JSON
```

The use of a heredoc rather than `jq` or a Python templating engine is deliberate: the SBOM generator should have no dependencies the rest of the build pipeline does not already require, and a shell heredoc with substituted variables is auditable at a glance. If the structure becomes unwieldy enough that the heredoc is unreadable, the right next step is to split it into per-component partials assembled by `cat`, not to introduce a templating engine.

The CycloneDX serial number is regenerated per run (`urn:uuid:$(uuidgen)`) so each SBOM is uniquely identifiable. The timestamp uses the same `date -u --iso-8601=seconds` the rest of the project uses.

## Where it runs

`run-update.sh` gains a final step:

```bash
echo "[5/5] Regenerating SBOM..."
bash "${SCRIPTS}/generate-sbom.sh" > "${PROJECT_ROOT}/SBOM.json"
```

Note the numbering: this becomes step 5 of 5, after the scanner image build. The SBOM is generated after the things it describes, so it reflects what was actually built rather than what was intended.

A CI check can compare the committed `SBOM.json` against a fresh regeneration. If they differ, either a version was bumped without regenerating the SBOM, or someone edited the SBOM by hand. Either case is worth catching.

## Side effects

- `tests/test-validate.sh` gains a fourth check: regenerate the SBOM into a temp file and `diff` it against the committed copy. Drift fails the validation tier. This is the mechanism that makes the automation actually self-enforcing — without the diff check, the generator can be silently bypassed.
- `CONTRIBUTING.md` should note that `SBOM.json` is generated, not hand-edited. Bumping a version in `versions.env` is enough; running `make validate` afterwards regenerates and verifies.
- The `serialNumber` and `timestamp` fields churn every regeneration, so the diff will show non-empty noise even when versions have not changed. Acceptable: those fields are *supposed* to change per regeneration. The CI check should compare modulo those two fields, or accept the churn explicitly and require committing the regenerated SBOM with every meaningful change.

## Estimated effort

Half a day for the generator script itself; another quarter day for the validation check; another quarter day for the CONTRIBUTING.md note and CI integration. Counting one full day allows for the inevitable "the SBOM now reproduces a field exactly except for one comma" kind of polish.

## Sequencing

Depends on `checksum-verification.md` being implemented at the same time, for the reason given above: the checksum work introduces the recorded values that the generator emits as `hashes` blocks. Either land them in a single change, or land checksum verification first with a placeholder hand-edit to the SBOM and follow up immediately with the generator.

Target `1.0.0`. The coupling with `checksum-verification.md` makes this a `1.0.0` item by inheritance: shipping `1.0.0` with checksums recorded in `versions.env` but the SBOM still hand-maintained gives auditors exactly the kind of inconsistency that prompted the work in the first place.

## Open questions

- **Should the generator be a shell script or written in something else?** Shell keeps the dependency surface minimal, which matters for a security-tool build chain. Python would be easier to maintain as the SBOM grows but adds an interpreter to the build station's required-tools list. Lean toward shell.
- **Should the SBOM live at the project root or under `build/` once generated?** The current convention is the root, which matches what auditors expect. Moving it under `build/` would mark it as generated more visibly but creates discovery friction. Keep at root and document its generated status in the file itself (a leading comment field, if CycloneDX permits, or via the `tools` metadata block).
- **Should we generate a fresh SBOM per scan session, embedded on the data USB?** Useful for auditing: the operator's data USB carries a record of what scanned the file USB. Probably yes, but a separate step from automation itself — it can ride along once the generator exists. Add to the `output-usb.md` follow-on rather than scoping it here.