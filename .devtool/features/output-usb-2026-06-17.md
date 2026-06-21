---
id: "output-usb-2026-06-17"
status: "todo"
priority: "medium"
assignee: "k"
epic: "tier-2-remediation-plan-2026-06-17"
dueDate: null
created: "2026-06-17T18:50:48.769Z"
modified: "2026-06-21T20:46:38.012Z"
completedAt: null
labels: ["feature", "security"]
order: "a5"
---
# Output USB with signed scan certificates

The scanning host currently emits the scan verdict on-screen only.
A photograph or hand-transcription is the only way to carry the
verdict out of the air-gapped room. For regulated-environment
deployment, this is not auditable.

The output USB feature adds a third USB role (TROSKEL-OUTPUT) that
receives a signed scan certificate after each scan. The certificate
binds the file-USB content hashes to the verdict and the
detection-versions in a signed artefact that survives the air-gapped
session.

Roadmap doc: `docs/roadmap/output-usb.md`.

## Why it matters

Two to three days of work; lands the project against the
README's "not suitable for any setting requiring a signed,
attestable scan certificate" exclusion. After this, the
exclusion narrows to deployments needing a specific certificate
authority chain or HSM-backed signing, which is post-1.1.0
work.

## Acceptance criteria

See the roadmap doc. Includes a key-pair scheme for the scanning
host's signing key, certificate format, and operator workflow
updates for the third USB.

## Sequencing

1.1.0 cluster. Depends on verdict-grammar landing first if the
certificate format references the structured verdict grammar
(check the roadmap doc); otherwise standalone.