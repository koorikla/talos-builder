# Talos Linux for Raspberry Pi 5 with WiFi

Talos boots the Pi 5 upstream, but it has no WiFi. This repo adds it:

- a Talos kernel with the Pi 5 WiFi driver (`brcmfmac`),
- a `rpi5-wifi` system extension with firmware and `wpa_supplicant`.

Everything else is stock Talos with the official `rpi_5` overlay.

> **Status:** not yet tested on hardware. Keep an Ethernet cable handy for the first boot.

## Quick start

Needs Docker and `talosctl`. CI builds and publishes the images, so you only
build the SD card image locally.

### 1. Add your WiFi credentials

```sh
cp config-patches/wifi.yaml.example config-patches/wifi.yaml
```

Edit `config-patches/wifi.yaml` and set your country code, SSID and passphrase:

```yaml
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: wpa-supplicant
configFiles:
  - mountPath: /etc/wpa_supplicant/wpa_supplicant.conf
    content: |
      country=EE
      network={
          ssid="MyNetwork"
          psk="MyPassphrase"
      }
```

The content is a regular `wpa_supplicant.conf`. `wifi.yaml` is gitignored, so
it is never committed.

### 2. Build and flash the image

```sh
make image EMBED_CONFIG=config-patches/wifi.yaml   # -> _out/metal-arm64.raw.zst
make flash DISK=/dev/sdX                           # double-check the device!
```

The image now contains your WiFi password. Don't share it.

### 3. Boot and configure

The Pi joins WiFi, gets an IP over DHCP and waits in maintenance mode. Find its
IP in your router's DHCP leases, then:

```sh
INSTALLER=$(make -s tags | awk '/^installer:/ {print $2}')

talosctl gen config my-cluster https://<pi-ip>:6443 \
  --config-patch @config-patches/wifi.yaml \
  --install-image "$INSTALLER"

talosctl apply-config --insecure -n <pi-ip> -f controlplane.yaml
```

> Always include `--config-patch @config-patches/wifi.yaml`. The applied config
> replaces the embedded one, and without the WiFi part the Pi goes offline.

Bootstrap the cluster as usual (`talosctl bootstrap ...`).

## WiFi config recipes

All of these go in the `content:` block of `wifi.yaml`.

**Several networks**: the higher `priority` is tried first.

```
network={
    ssid="Home"
    psk="..."
    priority=10
}
network={
    ssid="Phone-Hotspot"
    psk="..."
    priority=1
}
```

**Hidden network**: add `scan_ssid=1` to the `network={...}` block.

**Don't store the passphrase in plain text**: run `wpa_passphrase MyNetwork MyPassphrase`
and use the `psk=<64 hex chars>` line it prints (no quotes).

**Static IP**: add the usual Talos `LinkConfig` documents. By default Talos
uses DHCP on the WiFi interface.

**Change WiFi on a running node**: edit `wifi.yaml`, then:

```sh
talosctl patch mc -n <pi-ip> --patch @config-patches/wifi.yaml
```

The service restarts with the new settings. If the Pi moves to a network it
can't reach you through, it disappears, so plan the switch.

## Upgrading

```sh
talosctl upgrade -n <pi-ip> --image ghcr.io/koorikla/talos-builder/installer:<tag>
```

Use only installers from this repo. Upstream Talos installers have no WiFi
driver, so the Pi would lose its network.

`<tag>` looks like `v1.14.5-wifi.94f26479`. `make tags` prints the exact
image references.

## Troubleshooting

```sh
talosctl -n <ip> service ext-wpa-supplicant   # is it running?
talosctl -n <ip> logs ext-wpa-supplicant      # authentication errors show up here
talosctl -n <ip> get links                    # wlan0 should be "up"
talosctl -n <ip> dmesg | grep -i brcmf        # driver/firmware problems
```

- **Service "waiting"**: the `wpa-supplicant` config document is missing.
- **No `wlan0`**: the driver didn't load. Check `dmesg`.
- **Joins WiFi but no IP**: check the DHCP server and the country code.

## Building it yourself

CI (`.github/workflows/build.yml`) does this on GitHub's arm64 runners. To build
locally you need an arm64 Linux host. Under x86 emulation the kernel build
takes hours.

```sh
make checkouts patches   # fetch Talos + pkgs sources, apply the kernel patch
make kernel              # slow
make talos               # installer-base + imager
make extension
make installer           # needs crane
make image
```

Useful variables: `REGISTRY`, `USERNAME`, `EXTRA_EXTENSIONS` (more system
extensions, e.g. `ghcr.io/siderolabs/cloudflared:<version>`),
`EXTRA_KERNEL_ARGS`. To move to a new Talos release, see [UPGRADING.md](UPGRADING.md).

## How it works

- `patches/pkgs/` enables `cfg80211` + `brcmfmac` in the Talos kernel. It also
  adds a one-line driver fix so Talos sees the WiFi link as up. A new kernel is
  required because Talos only loads modules signed by its own build.
- Talos itself is unmodified, just rebuilt against that kernel.
- `extensions/rpi5-wifi/` ships the WiFi modules, firmware from Raspberry Pi
  OS, `regulatory.db`, and a `wpa_supplicant` service. The service waits for its
  config, then runs on the first wireless interface.

Credits: [talos-rpi5/talos-builder](https://github.com/talos-rpi5/talos-builder)
(the original fork), [notniknot/talos-pi5-wifi](https://github.com/notniknot/talos-pi5-wifi)
and [dot8development/talos-wifi](https://github.com/dot8development/talos-wifi)
(prior Talos WiFi work).
