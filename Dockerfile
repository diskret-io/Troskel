# Dockerfile
# Troskel build and test environment.
#
# Provides all build-station tooling in a container so the host OS is
# irrelevant. Works with Docker or Podman interchangeably.
#
# Usage (via Makefile targets, preferred):
#   make image          # build this image
#   make validate       # Tier 1: Butane + shellcheck, no privileges needed
#   make test-build     # Tier 2: full image build, needs --privileged
#   make test-scan      # Tier 3: Firecracker scan test, needs --privileged + /dev/kvm
#
# Direct usage:
#   docker build -t troskel-build .
#   docker run --rm troskel-build bash tests/test-validate.sh
#
# NOTE: this image bakes in build tooling, not scan signatures or YARA
# rules. Those are downloaded at runtime by the test scripts, which
# require internet access during test-build.sh (Tier 2) and test-scan.sh
# (Tier 3).
#
# NOTE: the image does not embed the EFF wordlist (needed by
# prepare-boot-usb.sh for passphrase generation). That script is not part
# of the test pipeline and is intentionally left for real-world use only.

FROM debian:trixie-slim

# Install system packages. These mirror what prepare-build-machine.sh
# installs on a real build station; keeping them in sync is intentional.
# shellcheck is added here for Tier 1 validation — it is not installed
# by prepare-build-machine.sh because it is not needed on a real build
# station at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        clamav \
        clamav-freshclam \
        coreutils \
        curl \
        debootstrap \
        e2fsprogs \
        gnupg \
        iproute2 \
        openssl \
        parted \
        shellcheck \
        unzip \
        util-linux \
        uuid-runtime \
        wget \
        xorriso \
    && rm -rf /var/lib/apt/lists/*

# Load version pins. ARG is used so the values are visible in `docker
# inspect` and CI logs without needing to source a file at runtime.
# These must match config/versions.env, the Makefile enforces this by
# passing them as --build-arg at image-build time rather than hardcoding.
ARG FC_VERSION
ARG BUTANE_VERSION
ARG LOKI_VERSION
ARG COREOS_INSTALLER_TAG

# Firecracker
RUN set -eu; \
    curl -fsSL \
        "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-x86_64.tgz" \
        | tar --no-same-owner -xz -C /tmp/ \
    && cp "/tmp/release-${FC_VERSION}-x86_64/firecracker-${FC_VERSION}-x86_64" \
           /usr/local/bin/firecracker \
    && chmod +x /usr/local/bin/firecracker \
    && firecracker --version

# Butane
# Resolve "latest" to a concrete tag. Using curl's redirect-following to
# find the release tag without jq or Python.
RUN set -eu; \
    if [ "$BUTANE_VERSION" = "latest" ]; then \
        BUTANE_TAG="$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            'https://github.com/coreos/butane/releases/latest')")"; \
    else \
        BUTANE_TAG="$BUTANE_VERSION"; \
    fi; \
    curl -fsSL \
        "https://github.com/coreos/butane/releases/download/${BUTANE_TAG}/butane-x86_64-unknown-linux-gnu" \
        -o /usr/local/bin/butane \
    && chmod +x /usr/local/bin/butane \
    && butane --version

# LOKI-RS
RUN set -eu; \
    LOKI_DIR="/opt/loki-rs"; \
    TMPDIR_LOKI="$(mktemp -d)"; \
    curl -fsSL \
        "https://github.com/Neo23x0/Loki-RS/releases/download/${LOKI_VERSION}/loki-linux-x86_64-${LOKI_VERSION}.tar.gz" \
        -o "${TMPDIR_LOKI}/loki.tar.gz" \
    && tar --no-same-owner -xzf "${TMPDIR_LOKI}/loki.tar.gz" -C "$TMPDIR_LOKI" \
    && rm "${TMPDIR_LOKI}/loki.tar.gz" \
    && LOKI_BIN="$(find "$TMPDIR_LOKI" -type f -name loki | head -1)" \
    && mkdir -p "$LOKI_DIR" \
    && cp -r "$(dirname "$LOKI_BIN")/." "$LOKI_DIR/" \
    && chmod +x "${LOKI_DIR}/loki" \
    && [ -f "${LOKI_DIR}/loki-util" ] && chmod +x "${LOKI_DIR}/loki-util" || true \
    && "${LOKI_DIR}/loki" --version \
    && rm -rf "$TMPDIR_LOKI"

# Create the working directories expected by the test scripts.
RUN mkdir -p /var/lib/troskel/clamav-db /var/lib/troskel/yara-rules /var/lib/troskel/logs

# Container sentinel.
# /.troskel-container is an empty marker file used by the test scripts to
# verify they are running inside the troskel-build container rather than
# directly on a developer's host. See docs/DEVELOPER.md, the rationalised
# contract is "test scripts run inside the container, period". The
# host-direct path was a source of environment-dependent bugs (the
# freshclam clamav-user issue, the chown-as-root issue) that go away when
# the test environment is uniformly Debian-the-container.
#
# A developer who genuinely needs the fast-iteration loop on a single
# script can still invoke the container directly:
#   docker run --rm --privileged \
#       --volume "$PWD:/troskel" --workdir /troskel \
#       troskel-build bash scripts/download-loki-yara-rules.sh
# This costs one container start per iteration (a few seconds) but
# guarantees the script runs in the same environment as the test suite.
RUN touch /.troskel-container

# The project is bind-mounted at /troskel at container run time, not
# COPYed, so changes to the repo are reflected immediately without
# rebuilding the image. WORKDIR sets the default so `docker run --rm
# troskel-build bash tests/test-validate.sh` just works.
WORKDIR /troskel