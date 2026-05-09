# Makefile
# Developer workflow for Troskel. Wraps container invocations so contributors
# do not need to remember --privileged / --device /dev/kvm incantations.
#
# Targets:
#   make image      Build the troskel-build container image.
#   make validate   Tier 1: Butane + shellcheck. No privileges.
#   make build      Tier 2: Full image build (debootstrap etc). Needs --privileged.
#   make scan       Tier 3: Firecracker scan test. Needs --privileged + /dev/kvm.
#   make all        Tiers 1, 2, and 3 in sequence.
#   make clean      Remove the container image and build artefact volume.
#
# Runtime:
#   Docker is preferred; Podman is the fallback. Detected automatically.
#   Docker and Podman require slightly different flags for privileged containers;
#   the Makefile detects which is in use and sets flags accordingly.
#
# Privileges:
#   Tier 2 (build) needs --privileged for debootstrap and mkfs.ext4.
#   Tier 3 (scan)  needs --privileged and /dev/kvm for Firecracker.
#   With Docker:   runs as root via the daemon — no extra flags needed.

#
# Artefact persistence:
#   Build artefacts (rootfs, signatures, kernel) are stored in a named
#   volume (troskel-artefacts) so they persist between make build and
#   make scan. make clean removes the volume along with the image.

IMAGE_NAME   := troskel-build
VOLUME_NAME  := troskel-artefacts
VERSIONS     := config/versions.env

# Source version pins from config/versions.env so --build-arg values are
# always in sync with what the scripts use.
FC_VERSION           := $(shell . $(VERSIONS) && echo $$FC_VERSION)
BUTANE_VERSION       := $(shell . $(VERSIONS) && echo $$BUTANE_VERSION)
LOKI_VERSION         := $(shell . $(VERSIONS) && echo $$LOKI_VERSION)
COREOS_INSTALLER_TAG := $(shell . $(VERSIONS) && echo $$COREOS_INSTALLER_TAG)

# Docker is required.
RUNTIME := $(shell command -v docker 2>/dev/null)
ifeq ($(RUNTIME),)
  $(error Docker not found. Install Docker: https://docs.docker.com/engine/install/)
endif

# Docker runs containers as root via its daemon — plain --privileged is
# sufficient for debootstrap and mkfs.ext4 inside the container.
PRIV_FLAGS := --privileged

# Common run flags. IMAGE_NAME must come last — everything after it is
# treated as the command to run inside the container.
RUN_FLAGS_BASE := run --rm \
    --volume "$(CURDIR):/troskel:z" \
    --volume "$(VOLUME_NAME):/var/lib/troskel:z" \
    --workdir /troskel

RUN_BASE           := $(RUNTIME) $(RUN_FLAGS_BASE) $(IMAGE_NAME)
RUN_PRIVILEGED     := $(RUNTIME) $(RUN_FLAGS_BASE) $(PRIV_FLAGS) $(IMAGE_NAME)
RUN_PRIVILEGED_KVM := $(RUNTIME) $(RUN_FLAGS_BASE) $(PRIV_FLAGS) --device /dev/kvm $(IMAGE_NAME)

.PHONY: image validate build scan all clean check-kvm check-priv

# Internal target: verify /dev/kvm is present before starting a scan.
check-kvm:
	@if [ ! -e /dev/kvm ]; then \
	    echo ""; \
	    echo "[!] /dev/kvm not found."; \
	    echo "    Enable VT-x (Intel) or AMD-V (AMD) in BIOS and reboot,"; \
	    echo "    or run on a KVM-capable host."; \
	    echo ""; \
	    exit 1; \
	fi
	@echo "[+] /dev/kvm available."

# Internal target: verify that privileged containers can perform the
# operations the build pipeline needs (mknod — required by debootstrap
# and mkfs.ext4). A plain 'true' passes even when these are denied.
check-priv:
	@if ! $(RUNTIME) run --rm $(PRIV_FLAGS) $(IMAGE_NAME) \
	        sh -c 'mknod /tmp/test-blk b 8 0 2>/dev/null && rm /tmp/test-blk' 2>/dev/null; then \
	    echo ""; \
	    echo "[!] Privileged capability check failed."; \
	        echo "    Ensure your user is in the docker group:"; \
	        echo "      sudo usermod -aG docker $$USER && newgrp docker"; \
	    echo ""; \
	    exit 1; \
	fi
	@echo "[+] Privilege check passed."

## Build the troskel-build container image.
image: Dockerfile $(VERSIONS)
	$(RUNTIME) build \
	    --build-arg FC_VERSION=$(FC_VERSION) \
	    --build-arg BUTANE_VERSION=$(BUTANE_VERSION) \
	    --build-arg LOKI_VERSION=$(LOKI_VERSION) \
	    --build-arg COREOS_INSTALLER_TAG=$(COREOS_INSTALLER_TAG) \
	    --tag $(IMAGE_NAME) \
	    .

## Tier 1 — Butane validation + shellcheck. No privileges needed.
validate: image
	$(RUN_BASE) bash tests/test-validate.sh

## Tier 2 — Full build pipeline (debootstrap, image build). Needs --privileged.
build: image check-priv
	$(RUNTIME) volume create $(VOLUME_NAME) 2>/dev/null || true
	$(RUN_PRIVILEGED) bash tests/test-build.sh

## Tier 3 — Firecracker scan test. Needs --privileged + /dev/kvm.
scan: image check-kvm check-priv
	$(RUN_PRIVILEGED_KVM) bash tests/test-scan.sh

## Run all tiers in sequence.
all: validate build scan

## Remove the container image and the build artefact volume.
clean:
	$(RUNTIME) rmi $(IMAGE_NAME) 2>/dev/null || true
	$(RUNTIME) volume rm $(VOLUME_NAME) 2>/dev/null || true