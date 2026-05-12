# SBOM automation

The CycloneDX SBOM at `SBOM.json` is currently hand-maintained: when a version pin changes in `config/versions.env`, someone has to remember to update the corresponding component entry in the SBOM. This is fragile, easy to miss, and the symptom of the gap is exactly the kind of detail an external auditor looks for. Automate the SBOM so that it is generated from `versions.env` (and the other authoritative sources) rather than copied alongside them.

## What is currently in the SBOM

`SBOM.json` is a CycloneDX 1.6 document with three rough categories of content:

- **Static facts.** Project metadata (name, version, licence, supplier), architectural properties (`detection-engines`, `virtualization`, `persistence`), the SBOM serial number. These do not change between builds.
- **Pinned-component versions.** Firecracker `v1.7.0`, LOKI-RS `v2.10.0`, Butane `v0.27.0`, Debian `trixie`, etc. These mirror values in `config/versions.env` and currently must be updated in two places.
- **Floating-component placeholders.** ClamAV signatures `"version": "dynamic"`, YARA Forge rules `"version": "dynamic"`, the coreos-installer container `"version": "release"`, the CoreOS stream `"version": "stable-stream"`. These are placeholders for components whose exact version is resolved at build time but not currently captured in the committed SBOM.

The drift problem is acute for the second category: if `FC_VERSION` in `versions.env` is bumped to `v1.8.0` and the SBOM is not updated to match, the project ships a build that does not match its own bill of materials. The upstream-artefact integrity verification work that landed earlier brought the committed SBOM back into sync as a one-time edit, but the underlying drift risk remains until the SBOM is regenerated from a single source.

## What automation looks like

A script — `scripts/generate-build-records.sh` — that reads from authoritative sources and emits both `SBOM.json` and the per-build manifest (`build-manifest.md` documents the manifest side; the two outputs share a generator because they read the same state). The authoritative sources are:

- `config/versions.env` for pinned versions (FC_VERSION, LOKI_VERSION, BUTANE_VERSION, KERNEL_RESOLVED, etc.) and their recorded SHA-256s.
- The build-station state at `/var/lib/troskel/` for resolved-at-build-time values: the signature freshness dates, the resolved YARA Forge release tag, the ClamAV `.cvd` versions extracted via `sigtool --info`.
- The CoreOS resolved version captured by `coreos-installer` during ISO extraction.
- A small static block within the script for project metadata (name, licence, suppliers, architectural properties) that genuinely does not vary.

The script emits a fresh `SBOM.json` to stdout (or to a path given as an argument). It does not edit the existing file in place — that would lose the audit trail of "what changed when". `run-update.sh` calls the generator as a final step after the build artefacts are ready, so the SBOM is always regenerated alongside a fresh data USB.

## Relationship with the upstream-artefact integrity verification work

The earlier integrity-verification work (which recorded SHA-256s in `versions.env` and put them under verification at download time) is the data source the generator reads from. With those values in place, the generator can populate the `hashes` block of each pinned component without further work — the integrity-verification work did the recording, the automation does the materialisation.

The reverse coupling also matters: the committed SBOM was edited by hand during the integrity-verification work to replace placeholders like `"version": "latest"` with concrete pins. Without automation, the next version bump risks reintroducing exactly that drift. The generator closes the loop.

## What the generator looks like

A reasonable shape, in pseudocode:

```bash
#!/usr/bin/env bash
# scripts/generate-build-records.sh
# Regenerates SBOM.json and the per-build manifest from authoritative
# sources. Run as the final step of run-update.sh, after all download
# and build scripts have populated /var/lib/troskel/.
set -euo pipefail

source config/versions.env

# Resolve runtime-only values by inspecting the build-station state.
KERNEL_FILENAME="$KERNEL_RESOLVED"   # recorded at first download
SIG_DATE="$(cat /var/lib/troskel/signature-date)"
YARA_DATE="$(cat /var/lib/troskel/yara-rules-date)"
YARA_FORGE_TAG="$(cat /var/lib/troskel/yara-forge-resolved-tag 2>/dev/null || echo unknown)"
COREOS_VERSION="$(coreos-installer iso info ... | grep version | awk '{print $NF}')"
TROSKEL_COMMIT="$(git rev-parse HEAD)"

# Emit the SBOM. The structure is a heredoc rather than a templating
# engine to keep the dependency footprint at zero.
cat > SBOM.json <<JSON
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  ...
}
JSON

# Emit the per-build manifest. Same data, different shape.
cat > /var/lib/troskel/build-manifest.json <<JSON
{
  "manifest_version": "1",
  ...
}
JSON
```

The use of a heredoc rather than `jq` or a Python templating engine is deliberate: the generator should have no dependencies the rest of the build pipeline does not already require, and a shell heredoc with substituted variables is auditable at a glance. If the structure becomes unwieldy enough that the heredoc is unreadable, the right next step is to split it into per-component partials assembled by `cat`, not to introduce a templating engine.

The CycloneDX serial number is regenerated per run (`urn:uuid:$(uuidgen)`) so each SBOM is uniquely identifiable. The timestamp uses the same `date -u --iso-8601=seconds` the rest of the project uses.

## Where it runs

`run-update.sh` gains a final step:

```bash
echo "[5/5] Regenerating build records..."
bash "${SCRIPTS}/generate-build-records.sh"
```

The script writes both files itself — `SBOM.json` to the project root, the manifest to `/var/lib/troskel/`. The SBOM is generated after the things it describes, so it reflects what was actually built rather than what was intended.

A CI check can compare the committed `SBOM.json` against a fresh regeneration. If they differ, either a version was bumped without regenerating the SBOM, or someone edited the SBOM by hand. Either case is worth catching.

## Side effects

- `tests/test-validate.sh` gains a check: regenerate the SBOM into a temp file and `diff` it against the committed copy. Drift fails the validation tier. This is the mechanism that makes the automation actually self-enforcing — without the diff check, the generator can be silently bypassed.
- `CONTRIBUTING.md` should note that `SBOM.json` is generated, not hand-edited. Bumping a version in `versions.env` is enough; running `make validate` afterwards regenerates and verifies.
- The `serialNumber` and `timestamp` fields churn every regeneration, so the diff will show non-empty noise even when versions have not changed. Acceptable: those fields are *supposed* to change per regeneration. The CI check should compare modulo those two fields, or accept the churn explicitly and require committing the regenerated SBOM with every meaningful change.

## Estimated effort

Half a day for the generator script itself; another quarter day for the validation check; another quarter day for the CONTRIBUTING.md note and CI integration. Counting one full day allows for the inevitable "the SBOM now reproduces a field exactly except for one comma" kind of polish.

## Sequencing

No outstanding dependencies. The upstream-artefact integrity verification work (formerly tracked as `checksum-verification.md`) has landed; the recorded SHA-256s the generator emits as `hashes` blocks are already in `versions.env`.

Closely coupled with `build-manifest.md` — both outputs are produced by the same generator. Land them in a single commit, with one script writing both files.

Target `1.0.0`. Shipping `1.0.0` with checksums recorded in `versions.env` but the SBOM still hand-maintained gives auditors exactly the kind of inconsistency that prompted the integrity-verification work in the first place. Automation closes the loop.

## Open questions

- **Should the generator be a shell script or written in something else?** Shell keeps the dependency surface minimal, which matters for a security-tool build chain. Python would be easier to maintain as the SBOM grows but adds an interpreter to the build station's required-tools list. Lean toward shell.
- **Should the SBOM live at the project root or under `build/` once generated?** The current convention is the root, which matches what auditors expect. Moving it under `build/` would mark it as generated more visibly but creates discovery friction. Keep at root and document its generated status in the file itself (via the `tools` metadata block, which already mentions the generator script).
- **Should we generate a fresh SBOM per scan session, embedded on the data USB?** Useful for auditing: the operator's data USB carries a record of what scanned the file USB. The per-build manifest covers this purpose; the SBOM stays a project-level artefact. No additional work needed here.