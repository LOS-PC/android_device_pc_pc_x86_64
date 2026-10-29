#!/vendor/bin/sh
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Looks for a Bluetooth adapter and sets vendor.pc.sku to "bluetooth" or "nobluetooth".
# init.pc.rc turns that into ro.boot.product.vendor.sku before system_server starts, and
# SystemConfig then reads /vendor/etc/permissions/sku_nobluetooth/, which marks the
# Bluetooth features unavailable: no Bluetooth service, settings or quick settings tile.
#
# $1: ro.boot.bluetooth (androidboot.bluetooth=1 / 0), or "auto" to detect

# Wait for USB devices to show up for at most MAX_WAIT seconds, stopping once the list
# hasn't changed for SETTLE seconds
MAX_WAIT=6
SETTLE=2

# Once an adapter was found, this PC is known to have one: later boots wait up to SEEN_WAIT
# seconds for it whether or not the USB list settles. Internal adapters (USB, on the Wi-Fi
# card) can show up late, e.g. when booting from a USB drive keeps the bus busy, and missing
# one hides Bluetooth for the whole boot.
SEEN_MARKER=/mnt/vendor/persist/pc_bluetooth_seen
SEEN_WAIT=12

log() {
    echo "<6>pc_bt_detect: $*" > /dev/kmsg
}

# A Bluetooth controller (HCI) the kernel already knows, or a USB interface of the
# Bluetooth class (wireless controller e0, RF 01, Bluetooth 01), even if btusb isn't
# bound to it (yet)
has_bluetooth() {
    for hci in /sys/class/bluetooth/hci*; do
        [ -e "$hci" ] && return 0
    done
    for intf in /sys/bus/usb/devices/*:*; do
        [ "$(cat $intf/bInterfaceClass 2>/dev/null)" = e0 ] &&
            [ "$(cat $intf/bInterfaceSubClass 2>/dev/null)" = 01 ] &&
            [ "$(cat $intf/bInterfaceProtocol 2>/dev/null)" = 01 ] && return 0
    done
    return 1
}

usb_devices() {
    ls /sys/bus/usb/devices 2>/dev/null | tr '\n' ' '
}

case "$1" in
    1|true)
        found=1
        log "Bluetooth forced on (androidboot.bluetooth)"
        ;;
    0|false)
        found=0
        log "Bluetooth forced off (androidboot.bluetooth)"
        ;;
    *)
        found=0
        waited=0
        stable=0
        last=$(usb_devices)
        seen=0
        [ -e $SEEN_MARKER ] && seen=1
        while ! has_bluetooth; do
            if [ $seen = 1 ]; then
                [ $waited -ge $((SEEN_WAIT * 4)) ] && break
            else
                [ $stable -ge $((SETTLE * 4)) ] || [ $waited -ge $((MAX_WAIT * 4)) ] && break
            fi
            sleep 0.25
            waited=$((waited + 1))
            now=$(usb_devices)
            if [ "$now" = "$last" ]; then
                stable=$((stable + 1))
            else
                stable=0
                last=$now
            fi
        done
        has_bluetooth && found=1
        log "Bluetooth adapter $([ $found = 1 ] && echo found || echo "not found") after $((waited * 250)) ms$([ $seen = 1 ] && echo ", found on an earlier boot")"
        if [ $found = 1 ] && [ $seen = 0 ]; then
            touch $SEEN_MARKER || log "could not write $SEEN_MARKER"
        fi
        ;;
esac

if [ $found = 1 ]; then
    setprop vendor.pc.sku bluetooth
else
    setprop vendor.pc.sku nobluetooth
fi
