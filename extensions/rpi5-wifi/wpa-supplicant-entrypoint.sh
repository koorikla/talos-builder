#!/bin/sh
# Runs wpa_supplicant in the foreground on the first wireless interface
# (or $WIFI_INTERFACE), waiting for brcmfmac to create it if necessary.
set -eu

CONFIG=/etc/wpa_supplicant/wpa_supplicant.conf

if [ ! -s "$CONFIG" ]; then
    echo "missing $CONFIG: provide it with an ExtensionServiceConfig named wpa-supplicant" >&2
    exit 1
fi

iface="${WIFI_INTERFACE:-}"

while [ -z "$iface" ]; do
    for phy in /sys/class/net/*/phy80211; do
        if [ -e "$phy" ]; then
            iface=$(basename "$(dirname "$phy")")
            break
        fi
    done

    if [ -z "$iface" ]; then
        echo "waiting for a wireless interface to appear"
        sleep 2
    fi
done

echo "starting wpa_supplicant on $iface"

# WPA_SUPPLICANT_ARGS (e.g. "-d") is split into separate arguments on purpose.
# shellcheck disable=SC2086
exec /sbin/wpa_supplicant -D nl80211 -i "$iface" -c "$CONFIG" ${WPA_SUPPLICANT_ARGS:-}
