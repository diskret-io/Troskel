# Makefile
# Developer workflow for Troskel. Wraps container invocations so contributors
# do not need to remember --privileged / --device /dev/kvm incantations.
#
# Targets:
#   make image       Build the troskel-build container image.
#   make validate    Tier 1: Butane + shellcheck. No privileges.
#   make test-build  Tier 2: Full build pipeline. Needs --privileged.
#   make test-scan   Tier 3: Firecracker scan test. Needs --privileged + /dev/kvm.
#   make test        Validate + test-build + test-scan in sequence.
#   make update      Refresh signatures and rebuild the scanner image.
#   make clean       Remove the container image and build artefact volume.
#
# Deprecated aliases (build, scan, all) are retained as targets only to
# emit a rename pointer and fail; see the bottom of this file.
#
# Runtime:
#   Docker is required.
#
# Privileges:
#   Tier 2 (test-build) needs --privileged for debootstrap and mkfs.ext4.
#   Tier 3 (test-scan)  needs --privileged and /dev/kvm for Firecracker.
#   Docker runs containers as root via its daemon, plain --privileged is
#   sufficient.
#
# Artefact persistence:
#   Build artefacts (rootfs, signatures, kernel) are stored in a named
#   volume (troskel-artefacts) so they persist between make test-build
#   and make test-scan. make clean removes the volume along with the
#   image.

IMAGE_NAME   := troskel-build
VOLUME_NAME  := troskel-artefacts
VERSIONS     := config/versions.env

# Source version pins from config/versions.env so --build-arg values are
# always in sync with what the scripts use.
FC_VERSION           := $(shell . $(VERSIONS) && echo $$FC_VERSION)
BUTANE_VERSION       := $(shell . $(VERSIONS) && echo $$BUTANE_VERSION)
LOKI_VERSION         := $(shell . $(VERSIONS) && echo $$LOKI_VERSION)
COREOS_INSTALLER_TAG := $(shell . $(VERSIONS) && echo $$COREOS_INSTALLER_TAG)

TROSKEL_VERSION := $(shell . $(VERSIONS) && echo $$TROSKEL_VERSION)
ifeq ($(strip $(TROSKEL_VERSION)),)
  $(error TROSKEL_VERSION empty: config/versions.env missing or unreadable)
endif

# Docker is required.
RUNTIME := $(shell command -v docker 2>/dev/null)
ifeq ($(RUNTIME),)
  $(error Docker not found. Install Docker: https://docs.docker.com/engine/install/)
endif

# Docker runs containers as root via its daemon, plain --privileged is
# sufficient for debootstrap and mkfs.ext4 inside the container.
PRIV_FLAGS := --privileged

# Common run flags. IMAGE_NAME must come last, everything after it is
# treated as the command to run inside the container.
RUN_FLAGS_BASE := run --rm \
    --volume "$(CURDIR):/troskel:z" \
    --volume "/var/lib/troskel:/var/lib/troskel:z" \
    --workdir /troskel

RUN_BASE           := $(RUNTIME) $(RUN_FLAGS_BASE) $(IMAGE_NAME)
RUN_PRIVILEGED     := $(RUNTIME) $(RUN_FLAGS_BASE) $(PRIV_FLAGS) $(IMAGE_NAME)
RUN_PRIVILEGED_KVM := $(RUNTIME) $(RUN_FLAGS_BASE) $(PRIV_FLAGS) --device /dev/kvm $(IMAGE_NAME)

.PHONY: image validate test-build test-scan test update clean check-kvm check-priv \
        build scan all

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
# operations the build pipeline needs (mknod, required by debootstrap
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
	$(RUNTIME) build  --load \
	    --build-arg FC_VERSION=$(FC_VERSION) \
	    --build-arg BUTANE_VERSION=$(BUTANE_VERSION) \
	    --build-arg LOKI_VERSION=$(LOKI_VERSION) \
	    --build-arg COREOS_INSTALLER_TAG=$(COREOS_INSTALLER_TAG) \
	    --tag $(IMAGE_NAME) \
	    .

## Update scanning files
update: image
	$(RUN_PRIVILEGED) bash scripts/run-update.sh

## Tier 1: Butane validation + shellcheck. No privileges needed.
validate: image
	$(RUN_BASE) bash tests/test-validate.sh

## Tier 2: Full build pipeline (debootstrap, image build). Needs --privileged.
test-build: image check-priv
	$(RUNTIME) volume create $(VOLUME_NAME) 2>/dev/null || true
	$(RUN_PRIVILEGED) bash tests/test-build.sh

## Tier 3: Firecracker scan test. Needs --privileged + /dev/kvm.
test-scan: image check-kvm check-priv
	$(RUN_PRIVILEGED_KVM) bash tests/test-scan.sh

## Run validate, test-build, and test-scan in sequence.
test: validate test-build test-scan

## Remove the container image and the build artefact volume.
clean:
	$(RUNTIME) rmi $(IMAGE_NAME) 2>/dev/null || true
	$(RUNTIME) volume rm $(VOLUME_NAME) 2>/dev/null || true

# ── Deprecated aliases ────────────────────────────────────────────────────────
# build, scan, and all were renamed (build/scan folded into the tiered
# test-* targets and update; all dropped). They remain declared so that
# invoking them gives an actionable rename pointer rather than make's bare
# "No rule to make target", which reads as a broken checkout. Each fails
# (exit 2) so a stale script or CI step calling the old name surfaces the
# breakage loudly instead of silently doing nothing. Remove these once no
# caller references the old names.
#
# Why a recipe and not just a .PHONY entry: a name in .PHONY with no recipe
# is still "No rule to make target". The pointer only appears if there is a
# recipe to run. tests/test-validate.sh asserts each of these prints the
# pointer and exits non-zero, and that .PHONY contains no name lacking a
# recipe.
build:
	@echo "[!] 'make build' was removed. Use 'make test-build' (Tier 2 build"
	@echo "    pipeline) or 'make update' (refresh signatures + scanner image)."
	@exit 2

scan:
	@echo "[!] 'make scan' was removed. Use 'make test-scan' (Tier 3 Firecracker"
	@echo "    scan test)."
	@exit 2

all:
	@echo "[!] 'make all' was removed. Use 'make test' (validate + build + scan)."
	@exit 2