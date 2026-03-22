# syntax=docker/dockerfile:1

# Stage 1: extract and decompress Broadcom firmware.
# Run on linux/amd64 (native, no QEMU) — firmware blobs are arch-independent.
# Files are at /lib/firmware/brcm/ (symlinks → /lib/firmware/cypress/*.zst).
# Use zstdcat (follows symlinks) rather than zstd -d (which ignores symlinks).
# hadolint ignore=DL3029
FROM --platform=linux/amd64 alpine:3.21 AS firmware
RUN apk add --no-cache linux-firmware-brcm zstd
RUN cd /lib/firmware/brcm && \
    zstdcat brcmfmac43455-sdio.bin.zst                             > brcmfmac43455-sdio.bin && \
    zstdcat brcmfmac43455-sdio.clm_blob.zst                        > brcmfmac43455-sdio.clm_blob && \
    zstdcat brcmfmac43455-sdio.txt.zst                             > brcmfmac43455-sdio.txt && \
    zstdcat brcmfmac43455-sdio.raspberrypi,5-model-b.bin.zst      > "brcmfmac43455-sdio.raspberrypi,5-model-b.bin" && \
    zstdcat brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob.zst > "brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob" && \
    zstdcat brcmfmac43455-sdio.raspberrypi,5-model-b.txt.zst      > "brcmfmac43455-sdio.raspberrypi,5-model-b.txt"

# Stage 2: wpa_supplicant binary
FROM --platform=linux/arm64 alpine:3.21 AS wpa
RUN apk add --no-cache wpa_supplicant

# Stage 3: assemble extension image
FROM scratch AS extension
COPY manifest.yaml /manifest.yaml

# Generic fallback firmware
COPY --from=firmware /lib/firmware/brcm/brcmfmac43455-sdio.bin \
     /rootfs/lib/firmware/brcm/brcmfmac43455-sdio.bin
COPY --from=firmware /lib/firmware/brcm/brcmfmac43455-sdio.clm_blob \
     /rootfs/lib/firmware/brcm/brcmfmac43455-sdio.clm_blob
COPY --from=firmware /lib/firmware/brcm/brcmfmac43455-sdio.txt \
     /rootfs/lib/firmware/brcm/brcmfmac43455-sdio.txt

# RPi5 board-specific firmware
COPY --from=firmware /lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.bin \
     "/rootfs/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.bin"
COPY --from=firmware /lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob \
     "/rootfs/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob"
COPY --from=firmware /lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.txt \
     "/rootfs/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.txt"

# wpa_supplicant binaries
COPY --from=wpa /sbin/wpa_supplicant /rootfs/usr/local/sbin/wpa_supplicant
COPY --from=wpa /sbin/wpa_cli        /rootfs/usr/local/sbin/wpa_cli

# Extension service definition
COPY wpa_supplicant.service /rootfs/etc/extension-services/wpa_supplicant.yaml

LABEL org.opencontainers.image.title="sys-kernel-wifi"
LABEL org.opencontainers.image.description="WiFi firmware + wpa_supplicant for RPi5 on Talos Linux"
LABEL org.opencontainers.image.source="https://github.com/koorikla/talos-builder"
LABEL org.opencontainers.image.licenses="GPL-2.0-only"
