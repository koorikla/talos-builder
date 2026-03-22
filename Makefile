PKG_VERSION = v1.12.0
TALOS_VERSION = v1.12.6

# siderolabs/pkgs and sbc-raspberrypi5 require GNU make.
# macOS ships BSD make; use gmake if available.
GMAKE := $(shell command -v gmake 2>/dev/null || command -v make)
ifeq ($(shell uname),Darwin)
  ifeq ($(shell command -v gmake 2>/dev/null),)
    $(error GNU make (gmake) is required on macOS. Install with: brew install make)
  endif
  GMAKE := gmake
endif
SBCOVERLAY_VERSION = main

REGISTRY ?= ghcr.io
REGISTRY_USERNAME ?= koorikla/talos-builder

TAG ?= $(shell git describe --tags --exact-match)

EXTENSIONS ?= ghcr.io/siderolabs/cloudflared:2026.3.0

WIFI_EXTENSION_IMAGE  = $(REGISTRY)/$(REGISTRY_USERNAME)/sys-kernel-wifi:$(TALOS_VERSION)
CLOUDFLARED_IMAGE     = ghcr.io/siderolabs/cloudflared:2026.3.0
OUT_DIR               = $(PWD)/_out

# Config patches: copy config-patches/*.yaml.example → *.yaml, fill in secrets.
# Any *.yaml found in config-patches/ is applied by gen-config and embedded by image.
CONFIG_PATCH_DIR   = $(PWD)/config-patches
CONFIG_PATCH_FILES = $(wildcard $(CONFIG_PATCH_DIR)/*.yaml)
CONFIG_PATCH_ARGS  = $(foreach f,$(CONFIG_PATCH_FILES),--config-patch @$(f))

# Cluster settings for gen-config (override on command line as needed)
CLUSTER_NAME ?= rpi5
ENDPOINT     ?= https://talos.local:6443

PKG_REPOSITORY = https://github.com/siderolabs/pkgs.git
TALOS_REPOSITORY = https://github.com/siderolabs/talos.git
SBCOVERLAY_REPOSITORY = https://github.com/talos-rpi5/sbc-raspberrypi5.git

CHECKOUTS_DIRECTORY := $(PWD)/checkouts
PATCHES_DIRECTORY := $(PWD)/patches

PKGS_TAG = $(shell cd $(CHECKOUTS_DIRECTORY)/pkgs && git describe --tag --always --dirty --match v[0-9]\*)
TALOS_TAG = $(shell cd $(CHECKOUTS_DIRECTORY)/talos && git describe --tag --always --dirty --match v[0-9]\*)
SBCOVERLAY_TAG = $(shell cd $(CHECKOUTS_DIRECTORY)/sbc-raspberrypi5 && git describe --tag --always --dirty)-$(PKGS_TAG)

#
# Help
#
.PHONY: help
help:
	@echo "checkouts  : Clone repositories required for the build"
	@echo "patches    : Apply all patches"
	@echo "kernel     : Build kernel"
	@echo "overlay    : Build Raspberry Pi 5 overlay"
	@echo "extensions : Build and push sys-kernel-wifi extension"
	@echo "gen-config : Generate _out/controlplane.yaml applying config-patches/*.yaml"
	@echo "image      : Assemble metal-arm64 disk image (embeds _out/controlplane.yaml if present)"
	@echo "all        : Run full pipeline (kernel + overlay + extensions + image)"
	@echo "release    : Tag and push installer image with current Git tag"
	@echo "clean      : Clean up checkouts and _out"
	@echo ""
	@echo "Config patches (copy .example → .yaml and fill in values):"
	@echo "  config-patches/wifi.yaml         WiFi SSID + PSK"
	@echo "  config-patches/cloudflared.yaml  Cloudflare tunnel token"



#
# Checkouts
#
.PHONY: checkouts checkouts-clean
checkouts:
	git clone -c advice.detachedHead=false --branch "$(PKG_VERSION)" "$(PKG_REPOSITORY)" "$(CHECKOUTS_DIRECTORY)/pkgs"
	git clone -c advice.detachedHead=false --branch "$(TALOS_VERSION)" "$(TALOS_REPOSITORY)" "$(CHECKOUTS_DIRECTORY)/talos"
	git clone -c advice.detachedHead=false --branch "$(SBCOVERLAY_VERSION)" "$(SBCOVERLAY_REPOSITORY)" "$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi5"

checkouts-clean:
	rm -rf "$(CHECKOUTS_DIRECTORY)/pkgs"
	rm -rf "$(CHECKOUTS_DIRECTORY)/talos"
	rm -rf "$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi5"



#
# Patches
#
.PHONY: patches-pkgs patches-talos patches
patches-pkgs:
	cd "$(CHECKOUTS_DIRECTORY)/pkgs" && \
		git am "$(PATCHES_DIRECTORY)/siderolabs/pkgs/0001-Patched-for-Raspberry-Pi-5.patch"
	cd "$(CHECKOUTS_DIRECTORY)/pkgs" && \
		git am "$(PATCHES_DIRECTORY)/siderolabs/pkgs/0002-WiFi-brcmfmac-config.patch"

patches-talos:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		git am "$(PATCHES_DIRECTORY)/siderolabs/talos/0001-Patched-for-Raspberry-Pi-5.patch"
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		git am "$(PATCHES_DIRECTORY)/siderolabs/talos/0002-WiFi-brcmfmac-modules.patch"

patches: patches-pkgs patches-talos



#
# Machine config generation
#
# Usage:
#   make gen-config                          # uses defaults (cluster=rpi5, endpoint=https://talos.local:6443)
#   make gen-config CLUSTER_NAME=mycluster ENDPOINT=https://192.168.1.50:6443
#
# Pre-requisite: copy config-patches/*.yaml.example → *.yaml and fill in values.
#
.PHONY: gen-config
gen-config:
	@command -v talosctl >/dev/null 2>&1 || { \
		echo "ERROR: talosctl not found."; \
		echo "Install: brew install siderolabs/tap/talosctl"; \
		exit 1; \
	}
	mkdir -p $(OUT_DIR)
	talosctl gen config \
		--output-types controlplane \
		--output $(OUT_DIR)/controlplane.yaml \
		--force \
		$(CONFIG_PATCH_ARGS) \
		$(CLUSTER_NAME) $(ENDPOINT)
	@echo ""
	@echo "==> Config written to _out/controlplane.yaml"
	@echo "    Run 'make image' to rebuild the disk image with this config embedded."
	@if [ -z "$(CONFIG_PATCH_FILES)" ]; then \
		echo ""; \
		echo "    NOTE: No config-patches/*.yaml files found — WiFi and cloudflared"; \
		echo "    not configured. Copy the .example files and re-run gen-config."; \
	fi



#
# Kernel
#
.PHONY: kernel
kernel:
	cd "$(CHECKOUTS_DIRECTORY)/pkgs" && \
		$(GMAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) PUSH=true \
			PLATFORM=linux/arm64 \
			kernel



#
# Overlay
#
.PHONY: overlay
overlay:
	@echo SBCOVERLAY_TAG = $(SBCOVERLAY_TAG)
	cd "$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi5" && \
		$(GMAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) IMAGE_TAG=$(SBCOVERLAY_TAG) PUSH=true \
			PKGS_PREFIX=$(REGISTRY)/$(REGISTRY_USERNAME) PKGS=$(PKGS_TAG) \
			INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 \
			sbc-raspberrypi5



#
# Extensions
#
.PHONY: extensions
extensions:
	docker buildx build \
		--platform linux/arm64 \
		--push \
		--tag $(WIFI_EXTENSION_IMAGE) \
		extensions/sys-kernel-wifi/



#
# Installer/Image
#
.PHONY: installer
installer:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		$(GMAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) PUSH=true \
			PKG_KERNEL=$(REGISTRY)/$(REGISTRY_USERNAME)/kernel:$(PKGS_TAG) \
			INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 \
			IMAGER_ARGS="--overlay-name=rpi5 --overlay-image=$(REGISTRY)/$(REGISTRY_USERNAME)/sbc-raspberrypi5:$(SBCOVERLAY_TAG) --system-extension-image=$(EXTENSIONS)" \
			kernel initramfs imager installer-base installer && \
		docker \
			run --rm -t -v ./_out:/out -v /dev:/dev --privileged $(REGISTRY)/$(REGISTRY_USERNAME)/imager:$(TALOS_TAG) \
			metal --arch arm64 \
			--base-installer-image="$(REGISTRY)/$(REGISTRY_USERNAME)/installer:$(TALOS_TAG)" \
			--overlay-name="rpi5" \
			--overlay-image="$(REGISTRY)/$(REGISTRY_USERNAME)/sbc-raspberrypi5:$(SBCOVERLAY_TAG)" \
			--system-extension-image="$(EXTENSIONS)"



#
# Image (metal ARM64 raw disk image)
#
.PHONY: image
image:
	mkdir -p $(OUT_DIR)
	@set -e; \
	GHCR_TOKEN=$$(gh auth token); \
	GHCR_AUTH=$$(printf 'koorikla:%s' "$$GHCR_TOKEN" | base64 | tr -d '\n'); \
	AUTH_DIR=$$(mktemp -d "$$HOME/.docker-auth-XXXXXX"); \
	trap "rm -rf $$AUTH_DIR" EXIT; \
	printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$$GHCR_AUTH" > "$$AUTH_DIR/config.json"; \
	CONFIG_MOUNT=""; CONFIG_ARG=""; \
	if [ -f "$(OUT_DIR)/controlplane.yaml" ]; then \
		CONFIG_MOUNT="-v $(OUT_DIR)/controlplane.yaml:/config/controlplane.yaml:ro"; \
		CONFIG_ARG="--embedded-config-path /config/controlplane.yaml"; \
		echo "==> Embedding machine config from _out/controlplane.yaml"; \
	else \
		echo "==> No _out/controlplane.yaml found — building unconfigured image."; \
		echo "    Run 'make gen-config' first to embed WiFi/cloudflared settings."; \
	fi; \
	docker run --rm \
		--privileged \
		-v /dev:/dev \
		-v $(OUT_DIR):/out \
		-e DOCKER_CONFIG=/docker-auth \
		-v $$AUTH_DIR:/docker-auth:ro \
		$$CONFIG_MOUNT \
		ghcr.io/siderolabs/imager:$(TALOS_VERSION) \
		metal \
		--arch arm64 \
		--base-installer-image "$(REGISTRY)/$(REGISTRY_USERNAME)/kernel:$(PKGS_TAG)" \
		--overlay-name rpi5 \
		--overlay-image "$(REGISTRY)/$(REGISTRY_USERNAME)/sbc-raspberrypi5:$(SBCOVERLAY_TAG)" \
		--system-extension-image "$(WIFI_EXTENSION_IMAGE)" \
		--system-extension-image "$(CLOUDFLARED_IMAGE)" \
		$$CONFIG_ARG



#
# Full pipeline
#
.PHONY: all
all: kernel overlay extensions image



#
# Release
#
.PHONY: release
release:
	docker pull $(REGISTRY)/$(REGISTRY_USERNAME)/installer:$(TALOS_TAG) && \
		docker tag $(REGISTRY)/$(REGISTRY_USERNAME)/installer:$(TALOS_TAG) $(REGISTRY)/$(REGISTRY_USERNAME)/installer:$(TAG) && \
		docker push $(REGISTRY)/$(REGISTRY_USERNAME)/installer:$(TAG)



#
# Clean
#
.PHONY: clean
clean: checkouts-clean
	rm -rf $(OUT_DIR)
