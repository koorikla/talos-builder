TALOS_VERSION ?= v1.14.5
# Official Raspberry Pi overlay (supports the Pi 5 since v0.2.x).
SBC_RPI_IMAGE ?= ghcr.io/siderolabs/sbc-raspberrypi:v0.2.2
OVERLAY_NAME ?= rpi_5

REGISTRY ?= ghcr.io
USERNAME ?= koorikla/talos-builder
PUSH ?= true
# Repository the published images are linked to on GHCR.
SOURCE_URL ?= https://github.com/koorikla/talos-builder

# Additional system extensions (full image references) to bake into the image and installer,
# e.g. EXTRA_EXTENSIONS="ghcr.io/siderolabs/cloudflared:<version>@sha256:..."
EXTRA_EXTENSIONS ?=
# Extra kernel arguments for the image and installer.
EXTRA_KERNEL_ARGS ?=
# Machine config (full or partial, e.g. config-patches/wifi.yaml) to embed into the disk image.
EMBED_CONFIG ?=

CRANE ?= crane

CHECKOUTS_DIRECTORY := $(CURDIR)/checkouts
PATCHES_DIRECTORY := $(CURDIR)/patches
OUT_DIR := $(CURDIR)/_out

TALOS_REPOSITORY = https://github.com/siderolabs/talos.git
PKGS_REPOSITORY = https://github.com/siderolabs/pkgs.git

# pkgs revision pinned by the selected Talos release, e.g. v1.14.0-48-gf4bda77.
PKGS_VERSION = $(shell sed -n 's/^PKGS ?= //p' "$(CHECKOUTS_DIRECTORY)/talos/Makefile")
# Content hash of our kernel patches, so a changed patch yields a new kernel/imager tag.
PATCHES_HASH = $(shell cat $(PATCHES_DIRECTORY)/pkgs/*.patch | sha256sum | cut -c1-8)

KERNEL_TAG = $(PKGS_VERSION)-wifi.$(PATCHES_HASH)
IMAGE_TAG = $(TALOS_VERSION)-wifi.$(PATCHES_HASH)

KERNEL_IMAGE = $(REGISTRY)/$(USERNAME)/kernel:$(KERNEL_TAG)
INSTALLER_BASE_IMAGE = $(REGISTRY)/$(USERNAME)/installer-base:$(IMAGE_TAG)
IMAGER_IMAGE = $(REGISTRY)/$(USERNAME)/imager:$(IMAGE_TAG)
EXTENSION_IMAGE = $(REGISTRY)/$(USERNAME)/rpi5-wifi:$(IMAGE_TAG)
INSTALLER_IMAGE = $(REGISTRY)/$(USERNAME)/installer:$(IMAGE_TAG)

IMAGER_ARGS = \
	--arch arm64 \
	--base-installer-image "$(INSTALLER_BASE_IMAGE)" \
	--overlay-image "$(SBC_RPI_IMAGE)" \
	--overlay-name "$(OVERLAY_NAME)" \
	--system-extension-image "$(EXTENSION_IMAGE)" \
	$(foreach ext,$(EXTRA_EXTENSIONS),--system-extension-image "$(ext)") \
	$(foreach arg,$(EXTRA_KERNEL_ARGS),--extra-kernel-arg "$(arg)")

# The imager pulls images itself; hand it the local registry credentials.
DOCKER_CONFIG_DIR ?= $(or $(DOCKER_CONFIG),$(HOME)/.docker)
IMAGER_RUN = docker run --rm --privileged --platform linux/arm64 \
	-v /dev:/dev \
	-v "$(OUT_DIR):/out" \
	$(if $(wildcard $(DOCKER_CONFIG_DIR)/config.json),-v "$(DOCKER_CONFIG_DIR)/config.json:/root/.docker/config.json:ro") \
	$(if $(EMBED_CONFIG),-v "$(abspath $(EMBED_CONFIG)):/embed/config.yaml:ro") \
	"$(IMAGER_IMAGE)"

.PHONY: help
help: ## Show this help.
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "%-16s %s\n", $$1, $$2}'

.PHONY: checkouts
checkouts: ## Clone siderolabs/talos at TALOS_VERSION and siderolabs/pkgs at the revision it pins.
	@if [ ! -d "$(CHECKOUTS_DIRECTORY)/talos" ]; then \
		git clone -c advice.detachedHead=false --depth 1 --branch "$(TALOS_VERSION)" "$(TALOS_REPOSITORY)" "$(CHECKOUTS_DIRECTORY)/talos"; \
	fi
	@if [ ! -d "$(CHECKOUTS_DIRECTORY)/pkgs" ]; then \
		pkgs_version=$$(sed -n 's/^PKGS ?= //p' "$(CHECKOUTS_DIRECTORY)/talos/Makefile"); \
		git clone --filter=blob:none "$(PKGS_REPOSITORY)" "$(CHECKOUTS_DIRECTORY)/pkgs" && \
		git -C "$(CHECKOUTS_DIRECTORY)/pkgs" -c advice.detachedHead=false checkout "$${pkgs_version##*-g}"; \
	fi

.PHONY: patches
patches: ## Apply patches/pkgs/*.patch to the pkgs checkout.
	cd "$(CHECKOUTS_DIRECTORY)/pkgs" && git apply --index $(PATCHES_DIRECTORY)/pkgs/*.patch

.PHONY: kernel
kernel: ## Build and push the WiFi-enabled arm64 kernel (slow: build on an arm64 host).
	$(MAKE) -C "$(CHECKOUTS_DIRECTORY)/pkgs" kernel \
		PLATFORM=linux/arm64 \
		REGISTRY=$(REGISTRY) USERNAME=$(USERNAME) PUSH=$(PUSH) \
		TAG=$(KERNEL_TAG)

.PHONY: talos
talos: ## Build and push installer-base and imager images using the custom kernel.
	$(MAKE) -C "$(CHECKOUTS_DIRECTORY)/talos" installer-base imager \
		PLATFORM=linux/arm64 INSTALLER_ARCH=targetarch \
		REGISTRY=$(REGISTRY) USERNAME=$(USERNAME) PUSH=$(PUSH) \
		TAG=$(TALOS_VERSION) IMAGE_TAG_OUT=$(IMAGE_TAG) \
		PKG_KERNEL=$(KERNEL_IMAGE)

.PHONY: extension
extension: ## Build and push the rpi5-wifi system extension.
	docker buildx build \
		--platform linux/arm64 \
		--build-arg PKG_KERNEL=$(KERNEL_IMAGE) \
		--build-arg VERSION=$(IMAGE_TAG) \
		--label org.opencontainers.image.source=$(SOURCE_URL) \
		--tag $(EXTENSION_IMAGE) \
		$(if $(filter true,$(PUSH)),--push) \
		extensions/rpi5-wifi

.PHONY: installer
installer: ## Build and push the installer image (used for `talosctl upgrade`).
	@mkdir -p "$(OUT_DIR)"
	$(IMAGER_RUN) installer $(IMAGER_ARGS)
ifeq ($(PUSH),true)
	$(CRANE) push "$(OUT_DIR)/installer-arm64.tar" "$(INSTALLER_IMAGE)"
	$(CRANE) mutate --label org.opencontainers.image.source=$(SOURCE_URL) "$(INSTALLER_IMAGE)"
endif

.PHONY: image
image: ## Build _out/metal-arm64.raw.zst for flashing (set EMBED_CONFIG to embed a machine config).
	@mkdir -p "$(OUT_DIR)"
	$(IMAGER_RUN) metal $(IMAGER_ARGS) $(if $(EMBED_CONFIG),--embedded-config-path /embed/config.yaml)

.PHONY: all
all: checkouts patches kernel talos extension installer image ## Run the whole pipeline.

.PHONY: tags
tags: ## Print the image references this checkout builds.
	@echo "kernel:         $(KERNEL_IMAGE)"
	@echo "installer-base: $(INSTALLER_BASE_IMAGE)"
	@echo "imager:         $(IMAGER_IMAGE)"
	@echo "extension:      $(EXTENSION_IMAGE)"
	@echo "installer:      $(INSTALLER_IMAGE)"

.PHONY: flash
flash: ## Write _out/metal-arm64.raw.zst to DISK (e.g. DISK=/dev/sdX).
	@test -n "$(DISK)" || { echo "usage: make flash DISK=/dev/sdX"; exit 1; }
	zstd -dc "$(OUT_DIR)/metal-arm64.raw.zst" | sudo dd of="$(DISK)" bs=4M conv=fsync status=progress

.PHONY: clean
clean: ## Remove checkouts and build output.
	rm -rf "$(CHECKOUTS_DIRECTORY)/talos" "$(CHECKOUTS_DIRECTORY)/pkgs" "$(OUT_DIR)"
