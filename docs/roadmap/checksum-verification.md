# SHA-256 verification of upstream artefacts

`SECURITY.md` records the absence of checksum verification as a residual risk: TLS to the upstream host is currently the only thing standing between the build station and a tampered artefact. Probability is low, impact is high, and the fix is small. The central `config/versions.env` makes the change a single-file extension rather than a per-script edit.

## What is downloaded today, and from where

The build station fetches five upstream artefact families:

- **Firecracker** — GitHub release tarball at `firecracker-microvm/firecracker`. Pinned by `FC_VERSION`. GitHub publishes a `firecracker-${FC_VERSION}-x86_64.tgz.sha256.txt` sidecar alongside each release tarball.
- **Butane** — GitHub release binary at `coreos/butane`. `BUTANE_VERSION` floats to `latest`. Each release ships a `sha256sum.txt` manifest covering all platform binaries.
- **LOKI-RS** — GitHub release tarball at `Neo23x0/Loki-RS`. Pinned by `LOKI_VERSION`. Release assets include per-tarball SHA-256 sidecars.
- **Guest kernel (`vmlinux`)** — AWS S3 bucket `spec.ccfc.min`. The Firecracker CI publishes the kernel assets but does not publish per-asset checksums in the bucket. This is the awkward one (see below).
- **CoreOS ISO** — fetched via the `coreos-installer download` container. The installer already verifies signatures against the embedded Fedora signing key; no additional work needed here, just documentation that this path is already covered.
- **ClamAV signatures** — fetched via `freshclam`, which performs its own `.cvd` signature verification against the ClamAV signing keys embedded in the binary. Already covered; document and move on.
- **YARA Forge rules** — fetched via `loki-util update`. Upstream verification status is opaque; needs investigation before claiming coverage either way.

So the actionable scope is Firecracker, Butane, LOKI-RS, and the guest kernel. Three are straightforward; the kernel is the open question.

## What changes

Add a SHA-256 column to `config/versions.env` for each pinned download. Two reasonable shapes:

**Option A — inline pins.** A `*_SHA256` variable next to each `*_VERSION`:

```sh
FC_VERSION="v1.7.0"
FC_SHA256="abc123..."

LOKI_VERSION="v2.10.0"
LOKI_SHA256="def456..."
```

Simple, greppable, fits the existing file shape. Downside: bumping a version means bumping two lines, and the relationship between them is by-convention rather than enforced.

**Option B — a separate manifest.** `config/checksums.txt` in plain `sha256sum -c` format:

```
abc123...  firecracker-v1.7.0-x86_64.tgz
def456...  loki-linux-x86_64-v2.10.0.tar.gz
```

Verifiable directly with `sha256sum -c` rather than custom logic, and the file format is stable and well-known. Downside: two files to keep coupled.

I would lean Option A. The pins and their checksums *are* coupled (a checksum without its version is meaningless), so co-locating them in the file that already exists for "pinned upstream versions" is the more honest layout. Adding a second file purely for serialisation reasons accumulates incidental complexity. Option B's `sha256sum -c` argument is real but minor — wrapping `sha256sum -c <<< "$EXPECTED  $FILE"` is one line of bash.

For floating versions (`BUTANE_VERSION="latest"`), the checksum cannot be pinned at the same time as the version: by definition, the version resolves at install time. Two paths:

1. **Pin Butane.** Bump `BUTANE_VERSION` to a concrete tag, accept the small admin toil of bumping it occasionally, gain a checksum. This is the right answer if checksum verification is taken seriously: an unpinned-version-with-no-checksum is a worst-of-both-worlds posture. Document the decision in `SECURITY.md` and move Butane from FLOATING to PINNED in the `versions.env` comment block.
2. **Leave Butane floating, no checksum.** Document explicitly in `SECURITY.md` that Butane is the one component whose download integrity rests on TLS alone, and justify the asymmetry. Defensible but weaker.

Pinning is the recommended call. Butane's release cadence is slow enough (a few releases a year) that the admin toil is negligible.

The CoreOS installer container image (`coreos-installer:release`) is similar but resolves automatically: container runtimes verify image digests against the registry, and the floating tag could be replaced with a pinned digest (`coreos-installer@sha256:...`) for genuine integrity. This is a separate small change worth doing in the same patch.

## The kernel problem

The Firecracker CI bucket lists `vmlinux-${VERSION}` files but does not publish corresponding `.sha256` sidecars. Three options:

- **Pin a checksum computed at first download.** Honest about what's being verified: "this is the kernel we got the first time we downloaded it from this URL". Doesn't defend against a compromise that pre-dates the first download, but does defend against subsequent tampering. Document the limitation explicitly.
- **Skip checksum verification for the kernel and document the gap.** The kernel is downloaded from the same trust root (`spec.ccfc.min.s3.amazonaws.com`) that publishes Firecracker itself, and Firecracker's checksum *is* verifiable. Argue that compromising the bucket would compromise Firecracker too. Coherent but somewhat hand-wavy.
- **Build the kernel from source.** Solves the problem properly but adds substantial build-station complexity and a new upstream (the Linux kernel source itself, plus a kernel config). Out of scope for this task; possibly worth a separate roadmap item.

The first option is the pragmatic answer. The second is a defensible fallback if the first proves operationally awkward.

## Implementation outline

1. Add `*_SHA256` variables to `config/versions.env` for `FC`, `BUTANE` (after pinning it), and `LOKI`. Add `KERNEL_SHA256` recorded as "computed-at-download" with a comment explaining the limitation.
2. Add a small helper in each download script — or, better, a single `verify_sha256()` function in a shared `scripts/lib.sh` sourced by all of them. The function takes a file path and an expected hash, computes the actual hash, and exits non-zero on mismatch.
3. Wire the helper into `prepare-build-machine.sh` (Firecracker, Butane, LOKI-RS), `download-kernel.sh` (kernel), after each `curl`/`wget`/`tar` step. Verify *before* extracting tarballs — a hostile tarball can exploit `tar` itself.
4. For the kernel: on first download, compute and write the checksum to `versions.env` automatically if `KERNEL_SHA256` is empty, with a warning printed to the operator. On subsequent downloads, verify against the recorded value.
5. Pin the `coreos-installer` container image by digest rather than tag in `prepare-build-machine.sh` and `prepare-boot-usb.sh`.
6. Update `SECURITY.md`: move "Unpinned upstream artefacts" from open residual risk to "verified at download". Record the kernel limitation honestly under residual risks. Move Butane from FLOATING to PINNED in the categorisation block.
7. Update `SBOM.json`: replace `latest` and `release` placeholders with concrete versions for the now-pinned components, and add a `hashes` block to each component carrying the SHA-256.
8. Add a test in `tests/test-build.sh` that deliberately corrupts a downloaded artefact (e.g. `truncate` it) and confirms the build fails with a clear checksum-mismatch error.

## Estimated effort

One day. The script changes are mechanical; the bulk of the time goes into the kernel question (deciding which option, documenting the limitation), the SBOM update, and the test fixture. No architectural changes.

## Sequencing

Independent of the other roadmap items. Should land before 1.0.0 — `SECURITY.md` already calls this out as the planned next iteration, and shipping a security-tool 1.0.0 with this gap unaddressed is the kind of detail external auditors notice immediately.

## Open questions

- **Butane: pin or document the gap?** Recommended above to pin. Worth a sanity-check from anyone who has been bumping Butane in practice and has a sense of the cadence.
- **Kernel: record-at-first-download or build from source?** The pragmatic answer is record-at-first-download for now and consider building from source as a separate roadmap item. The latter is a substantially larger change.
- **YARA Forge upstream verification.** `loki-util update` fetches the rule corpus from YARA Forge; whether the corpus itself is signed or checksummed upstream is not currently documented in the project, and the answer determines whether YARA-rule integrity sits in the same bucket as ClamAV signatures (verified by the fetcher) or is an additional gap. Worth investigating as part of this task even if no code changes result.
- **Should the helper live in a shared `scripts/lib.sh`?** The project does not currently have one; introducing it for a single function feels heavyweight. But the pattern will recur (e.g. the `count_lines` helper in the guest entrypoint also belongs in a shared place). The decision belongs to whoever picks this task up; either inline the helper into each script or start the shared library now.