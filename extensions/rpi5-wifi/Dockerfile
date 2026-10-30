# syntax=docker/dockerfile:1

# Talos system extension: Raspberry Pi 5 onboard WiFi (CYW43455 / brcmfmac).
#
# Ships:
#   - cfg80211 + brcmfmac kernel modules, taken from the custom kernel build so
#     they are signed with the same (ephemeral) key as the kernel itself
#   - CYW43455 firmware + NVRAM + CLM blob from Raspberry Pi OS (firmware-nonfree)
#   - wireless-regdb (regulatory.db is verified by cfg80211 against built-in keys)
#   - wpa_supplicant as an extension service, configured via ExtensionServiceConfig

# Kernel image produced by `make kernel` (ghcr.io/<user>/kernel:<tag>).
ARG PKG_KERNEL
# Extension version, written into manifest.yaml.
ARG VERSION=dev

ARG ALPINE_IMAGE=alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f

# https://github.com/RPi-Distro/firmware-nonfree (branch trixie)
ARG RPI_FIRMWARE_REF=3bab0f823f5b53150b76aab77093adef6655b920
ARG RPI_FIRMWARE_SHA256=8ecd0b46fbbc6921ae1d60faea9848516b193cc773ba6f1c9969eccebe6947fd

# https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git
ARG REGDB_VERSION=2026.09.03
ARG REGDB_SHA256=b22e0901227b820cd1c280abe681a15b773a5103a5e10dc442e94ebb34cbf58d

FROM ${PKG_KERNEL} AS kernel

FROM --platform=$BUILDPLATFORM ${ALPINE_IMAGE} AS modules
COPY --from=kernel /usr/lib/modules /kernel-modules
RUN set -eu; \
    kver=$(ls /kernel-modules); \
    src=/kernel-modules/${kver}/kernel; \
    dst=/rootfs/usr/lib/modules/${kver}/kernel; \
    test -f "${src}/net/wireless/cfg80211.ko"; \
    test -f "${src}/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko"; \
    mkdir -p "${dst}/net" "${dst}/drivers/net"; \
    cp -a "${src}/net/wireless" "${dst}/net/"; \
    cp -a "${src}/drivers/net/wireless" "${dst}/drivers/net/"; \
    find /rootfs -name '*.ko' | sort

FROM --platform=$BUILDPLATFORM ${ALPINE_IMAGE} AS firmware
ARG RPI_FIRMWARE_REF
ARG RPI_FIRMWARE_SHA256
ARG REGDB_VERSION
ARG REGDB_SHA256
ADD --checksum=sha256:${RPI_FIRMWARE_SHA256} \
    https://github.com/RPi-Distro/firmware-nonfree/archive/${RPI_FIRMWARE_REF}.tar.gz /tmp/firmware-nonfree.tar.gz
ADD --checksum=sha256:${REGDB_SHA256} \
    https://mirrors.edge.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-${REGDB_VERSION}.tar.xz /tmp/regdb.tar.xz
RUN set -eu; \
    mkdir -p /src/fw /src/regdb /rootfs/usr/lib/firmware/brcm; \
    tar -xzf /tmp/firmware-nonfree.tar.gz -C /src/fw --strip-components=1; \
    tar -xJf /tmp/regdb.tar.xz -C /src/regdb --strip-components=1; \
    fw=/src/fw/debian/added-firmware; \
    out=/rootfs/usr/lib/firmware/brcm; \
    # Raspberry Pi OS selects the "standard" firmware variant via alternatives.
    cp "${fw}/cypress/cyfmac43455-sdio-standard.bin" "${out}/brcmfmac43455-sdio.bin"; \
    cp "${fw}/cypress/cyfmac43455-sdio.clm_blob" "${out}/brcmfmac43455-sdio.clm_blob"; \
    cp "${fw}/brcm/brcmfmac43455-sdio.txt" "${out}/brcmfmac43455-sdio.txt"; \
    # brcmfmac tries board-specific names (from the DT compatible) first.
    for board in raspberrypi,5-model-b raspberrypi,5-compute-module raspberrypi,500; do \
        for ext in bin clm_blob txt; do \
            ln -s "brcmfmac43455-sdio.${ext}" "${out}/brcmfmac43455-sdio.${board}.${ext}"; \
        done; \
    done; \
    cp /src/fw/debian/copyright "${out}/LICENSE.firmware-nonfree"; \
    cp /src/regdb/regulatory.db /src/regdb/regulatory.db.p7s /rootfs/usr/lib/firmware/; \
    cp /src/regdb/LICENSE /rootfs/usr/lib/firmware/LICENSE.wireless-regdb; \
    ls -lR /rootfs

# Root filesystem of the wpa-supplicant extension service container.
FROM ${ALPINE_IMAGE} AS wpa-supplicant
RUN apk add --no-cache wpa_supplicant \
    && rm -rf /var/cache/apk/* \
    && chmod 0755 /tmp /var/tmp
COPY --chmod=0755 wpa-supplicant-entrypoint.sh /usr/local/bin/wpa-supplicant-entrypoint.sh

FROM --platform=$BUILDPLATFORM ${ALPINE_IMAGE} AS manifest
ARG VERSION
COPY manifest.yaml /manifest.yaml.in
RUN sed "s|\$VERSION|${VERSION}|" /manifest.yaml.in > /manifest.yaml

FROM scratch
COPY --from=manifest /manifest.yaml /manifest.yaml
COPY --from=modules /rootfs /rootfs
COPY --from=firmware /rootfs /rootfs
COPY --from=wpa-supplicant / /rootfs/usr/local/lib/containers/wpa-supplicant/
COPY wpa-supplicant.yaml /rootfs/usr/local/etc/containers/wpa-supplicant.yaml
