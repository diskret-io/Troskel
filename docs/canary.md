# Upstream canary

A scheduled job that catches upstream breakage before users do.

Troskel's build pulls artefacts from a substantial number of external sources: Firecracker, the matched CI kernel from S3, LOKI-RS, Butane, ClamAV signatures, YARA Forge rules via `loki-util`, the EFF wordlist, the CoreOS stable stream, the `coreos-installer` container image, and a Debian `${DEBIAN_RELEASE}` debootstrap. 

Several of these float by design (Butane `latest`, CoreOS `stable`); the others are pinned but their *URLs* and *bucket layouts*. Therefore a silent upstream change can sit undetected between commits.

The canary makes that breakage visible quickly.

## How it runs

Defined in [`.github/workflows/upstream-canary.yml`](../.github/workflows/upstream-canary.yml). Two tiers:

| Tier            | Cadence          | Cost      | Catches                                                          |
|-----------------|------------------|-----------|------------------------------------------------------------------|
| `reachability`  | Daily, 06:17 UTC | ~20 sec   | URL moved, asset deleted, repo renamed, registry down            |
| `full-build`    | Weekly, Mon 07:13 UTC | ~15-20 min | Tarball broken, schema change, glibc bump, freshclam DB layout change |

Both are also triggerable manually from the **Actions** tab via "Run workflow". The full-build tier runs after the reachability tier on Mondays; if HEADs already 404, the slow tier doesn't waste runner minutes.

## What happens on failure

The workflow opens (or comments on) a GitHub issue labelled `canary` and `upstream`. The issue title is stable per tier, so consecutive failures comment on the same issue rather than spawning new ones. Closing the issue resets the dedup state. The next failure opens a new one.

Currently the owner, as watcher of the repo, gets a normal issue notification. So there should be no need to babysit the Actions tab.

## When the issue arrives

The body of the issue lists the most likely causes and points at `config/versions.env` and the relevant download script. In practice:

- **Reachability failure** is almost always a URL change or a floating tag that no longer resolves. The script's per-check failure line names the URL and the HTTP code returned.
- **Full-build failure with reachability passing** is almost always a content-level change: a new Butane release that broke the config compiler, a YARA Forge schema bump, a freshclam DB layout change, or a Firecracker kernel patch that broke virtio-mmio compatibility. The `make build` log identifies which step failed.

The conventional fix flow is: identify the cause, bump or pin the relevant version in `config/versions.env`, push the fix, then re-run the canary manually to confirm green before closing the issue.

## When *not* to make the canary "robust"

Resist the temptation to add fallbacks, retries, or "maybe the upstream meant this other URL" logic beyond simple network-flake handling. The canary's job is to fail when the world changes, so that we find out before users do. A canary that never fails has stopped breathing.

The one case where retry-on-failure is appropriate is genuine network flakiness: `quay.io` has rare 5xx blips, GitHub's API hits rate limits during high-traffic windows. If we start seeing weekly false-positive issues from transient failures, wrap the failing step in [`nick-fields/retry@v3`](https://github.com/nick-fields/retry) with a small backoff. Don't pre-emptively add it.
