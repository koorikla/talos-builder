# Moving to a new Talos release

1. Bump `TALOS_VERSION` in the `Makefile`. Check whether a newer
   [`sbc-raspberrypi`](https://github.com/siderolabs/sbc-raspberrypi/releases)
   release supports it, and bump `SBC_RPI_IMAGE` if so.
2. Start from fresh checkouts. `siderolabs/pkgs` is checked out at the revision
   the Talos release pins (`PKGS ?=` in Talos' `Makefile`).
   ```sh
   make clean checkouts
   ```
3. Apply the patches:
   ```sh
   make patches
   ```
   If `kernel/build/config-arm64` no longer applies, regenerate the config hunk.
   Add these options to the new `config-arm64` and run `olddefconfig`. The
   pkgs `kernel-olddefconfig` target does this in a container:
   ```
   CONFIG_CFG80211=m
   # CONFIG_CFG80211_DEFAULT_PS is not set
   CONFIG_WLAN=y
   CONFIG_WLAN_VENDOR_BROADCOM=y
   CONFIG_BRCMFMAC=m
   CONFIG_BRCMFMAC_SDIO=y
   ```
   Stage the result in `checkouts/pkgs` and regenerate the patch:
   ```sh
   git -C checkouts/pkgs diff --cached > patches/pkgs/0001-kernel-arm64-enable-brcmfmac-wifi.patch
   ```
   The `brcmfmac` carrier patch can be dropped once upstream Linux reports
   carrier through ethtool.
4. Check the extension pins in `extensions/rpi5-wifi/Dockerfile`: Alpine,
   firmware-nonfree, wireless-regdb.
5. Commit and push to `main`. CI rebuilds the kernel and Talos images, because
   their tags change with `TALOS_VERSION` and the patch hash.
6. Tag a release (e.g. `v1.14.5-wifi.1`) to attach the generic disk image.
