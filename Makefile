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
	@echo "checkouts : Clone repositories required for the build"
	@echo "patches   : Apply all patches"
	@echo "kernel    : Build kernel"
	@echo "overlay   : Build Raspberry Pi 5 overlay"
	@echo "installer : Build installer docker image and disk image"
	@echo "extensions : Build and push sys-kernel-wifi extension"
	@echo "image      : Assemble metal-arm64 disk image"
	@echo "all        : Run full pipeline (kernel + overlay + extensions + image)"
	@echo "release   : Use only when building the final release, this will tag relevant images with the current Git tag."
	@echo "clean     : Clean up any remains"



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
	docker run --rm \
		--privileged \
		-v /dev:/dev \
		-v $(OUT_DIR):/out \
		-e DOCKER_CONFIG=/docker-auth \
		-v $$AUTH_DIR:/docker-auth:ro \
		ghcr.io/siderolabs/imager:$(TALOS_VERSION) \
		metal \
		--arch arm64 \
		--base-installer-image "$(REGISTRY)/$(REGISTRY_USERNAME)/kernel:$(PKGS_TAG)" \
		--overlay-name rpi5 \
		--overlay-image "$(REGISTRY)/$(REGISTRY_USERNAME)/sbc-raspberrypi5:$(SBCOVERLAY_TAG)" \
		--system-extension-image "$(WIFI_EXTENSION_IMAGE)" \
		--system-extension-image "$(CLOUDFLARED_IMAGE)"



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
