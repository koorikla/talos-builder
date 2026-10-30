# Talos Linux for Raspberry Pi 5 with WiFi

Builds a Talos Linux image for the Raspberry Pi 5 that can use the onboard WiFi
(Infineon CYW43455 over SDIO, `brcmfmac` driver).

Upstream Talos boots the Pi 5 through the official
[`sbc-raspberrypi`](https://github.com/siderolabs/sbc-raspberrypi) overlay
(`rpi_5`), but its kernel has no wireless stack and Talos ships no WiFi
firmware or supplicant. This repo adds only what is missing:

| Piece | Where | Why it can't come from upstream |
| --- | --- | --- |
| Kernel with `cfg80211` + `brcmfmac` as modules | `patches/pkgs/` applied to [siderolabs/pkgs](https://github.com/siderolabs/pkgs) | Talos enforces module signatures, and the signing key is thrown away after each kernel build. New modules mean a new kernel. |
| `installer-base` + `imager` built against that kernel | unmodified [siderolabs/talos](https://github.com/siderolabs/talos) | The initramfs carries the kernel and its signed modules. |
| `rpi5-wifi` system extension | `extensions/rpi5-wifi/` | Ships the WiFi modules, firmware (from Raspberry Pi OS), `regulatory.db` and a `wpa_supplicant` extension service. |

Talos itself is not patched. The kernel gets one small fix: `brcmfmac` now
reports carrier through ethtool. Without it, Talos considers the link down and
never uses the WiFi address as a node address.

> **Status:** builds are automated, but this has not yet been validated on
> hardware. Ethernet keeps working as usual, so test with a cable plugged in
> the first time.

## Getting an image

CI (`.github/workflows/build.yml`, native arm64 runners) publishes:

| Image | Purpose |
| --- | --- |
| `ghcr.io/koorikla/talos-builder/installer:<tag>` | `talosctl upgrade --image ...` |
| `ghcr.io/koorikla/talos-builder/imager:<tag>` | builds disk images locally (below) |
| `ghcr.io/koorikla/talos-builder/rpi5-wifi:<tag>` | the system extension |
| workflow artifact / release asset `metal-arm64.raw.zst` | generic disk image, no WiFi credentials |

`<tag>` is `<talos version>-wifi.<hash of patches/pkgs>`, e.g.
`v1.14.5-wifi.c0f0c4cd`. `make tags` prints the exact references for the
current checkout.

### A disk image with your WiFi credentials

A Pi with no Ethernet cable needs its WiFi credentials before it can be
configured, so they are embedded into the image. Only the imager runs locally;
under QEMU on x86 this takes a few minutes.

```sh
cp config-patches/wifi.yaml.example config-patches/wifi.yaml   # set country, SSID, passphrase
make checkouts                                                 # resolves the image tags
make image EMBED_CONFIG=config-patches/wifi.yaml
make flash DISK=/dev/sdX
```

On first boot the Pi joins the network over DHCP and waits in maintenance
mode. Find its address (router leases or HDMI console), then apply a full
machine config **that also contains the WiFi document**. Applying a config
replaces the embedded one, and without the WiFi document the connection drops:

```sh
talosctl gen config my-cluster https://<pi-ip>:6443 \
  --config-patch @config-patches/wifi.yaml \
  --install-image "$(make -s tags | awk '$1 == "installer:" {print $2}')"
talosctl apply-config --insecure -n <pi-ip> -f controlplane.yaml
```

You can also embed the full `controlplane.yaml` instead of `wifi.yaml`, and
the Pi boots straight into the cluster.

Treat an image with embedded credentials as a secret. Never upload one as a
CI artifact.

### Upgrades

```sh
talosctl upgrade -n <pi-ip> --image ghcr.io/koorikla/talos-builder/installer:<tag>
```

The installer includes the overlay and the `rpi5-wifi` extension. Don't use
upstream Talos installers on this node: their kernel can't load these modules.

## Configuration

WiFi is configured entirely through the `wpa-supplicant`
[`ExtensionServiceConfig`](config-patches/wifi.yaml.example). It contains a
plain `wpa_supplicant.conf`, so multiple networks, priorities and hidden SSIDs
work as usual. The service:

- starts only once that document exists,
- uses the first wireless interface, unless `WIFI_INTERFACE` is set,
- logs to `talosctl logs ext-wpa-supplicant`.

Talos runs DHCP on the interface by default. Use the usual
`LinkConfig`/`DHCPv4Config` documents for static addressing. WiFi power saving
is off by default (`CFG80211_DEFAULT_PS=n`), because it is a common source of
dropouts on Pi boards.

Useful checks:

```sh
talosctl -n <ip> service ext-wpa-supplicant
talosctl -n <ip> logs ext-wpa-supplicant
talosctl -n <ip> get links            # wlan0 should be up
talosctl -n <ip> dmesg | grep -i brcmf
```

## Building everything yourself

Building the kernel needs an arm64 Linux host with Docker Buildx. Under QEMU
it takes many hours. Push access to `REGISTRY/USERNAME` is required.

```sh
make checkouts patches   # siderolabs/talos @ TALOS_VERSION, siderolabs/pkgs @ the revision it pins
make kernel              # the slow step (about an hour on a GitHub arm64 runner)
make talos               # installer-base + imager
make extension
make installer           # needs crane
make image
```

Override `REGISTRY`, `USERNAME` and `SOURCE_URL` to publish elsewhere.
`EXTRA_EXTENSIONS` adds more system extensions, e.g. official ones such as
`ghcr.io/siderolabs/cloudflared:<version>`. `EXTRA_KERNEL_ARGS` adds kernel
arguments.

See [UPGRADING.md](UPGRADING.md) for moving to a new Talos release.

## Known limitations

- Pi 5 onboard WiFi only. No other wireless drivers are enabled, and there is no `mac80211`.
- Client mode with `wpa_supplicant` only (no AP mode). Enterprise WiFi depends on what Alpine's `wpa_supplicant` supports.
- SecureBoot images are not built.
- WiFi on a cluster node is less reliable than Ethernet. Use Ethernet when you can.

## Prior art

- [notniknot/talos-pi5-wifi](https://github.com/notniknot/talos-pi5-wifi) is a hardware-validated, much larger Talos fork with native WiFi config documents. It inspired the `brcmfmac` carrier fix.
- [dot8development/talos-wifi](https://github.com/dot8development/talos-wifi) is the Talos WiFi fork it builds on.
- [talos-rpi5/talos-builder](https://github.com/talos-rpi5/talos-builder) is the original Pi 5 builder this repo was forked from, from before upstream Pi 5 support existed.
