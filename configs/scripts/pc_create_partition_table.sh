# Do not set interpreter, this script is executed by init in android recovery
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Gives the disk chosen in pc_install_disk_select the LineageOS partition layout.
#
# $1: sgdisk executable
# $2: disk name (e.g. nvme0n1, sda, mmcblk0)
# $3: 1 to erase the disk, 0 to keep an existing LineageOS layout and its data
# $4: ro.build.ab_update
#
# The partition numbers match virt-common's A/B layout (partitions 1-11, which GRUB and the
# fstab rely on) plus userdata as partition 12, which takes the rest of the disk.
# SUPER_SIZE must match BOARD_SUPER_PARTITION_SIZE in BoardConfig.mk.

SGDISK_EXEC=$1
DISK_NAME=$2
ERASE=$3
AB_OTA_UPDATER=$4

EFI_SIZE=256M
SUPER_SIZE=4G

# 12 GB in 512-byte sectors (pc_install_disk_select's kMinDiskBytes)
MIN_DISK_SECTORS=23437500

# Level 6 stays off the screen (loglevel=3 on the kernel command line), level 2 shows up
log() {
    echo "<6>pc_install: $*" > /dev/kmsg
    echo "pc_install: $*"
}

log_error() {
    echo "<2>pc_install: $*" > /dev/kmsg
    echo "pc_install: $*"
}

fail() {
    log_error "ERROR: $*"
    log_error "Installation stopped."
    exit 1
}

has_lineage_layout() { # disk
    $SGDISK_EXEC -i 2 /dev/block/$1 2>/dev/null | grep -q "Partition name: 'super'" &&
        $SGDISK_EXEC -i 12 /dev/block/$1 2>/dev/null | grep -q "Partition name: 'userdata'"
}

[ -x "$SGDISK_EXEC" ] || fail "sgdisk not found"
[ "$AB_OTA_UPDATER" = "true" ] || fail "only A/B builds are supported"

[ -n "$DISK_NAME" ] || fail "no install disk chosen"

TARGET=/dev/block/$DISK_NAME
[ -w "$TARGET" ] || fail "cannot open $TARGET"
[ "$(cat /sys/block/$DISK_NAME/size)" -ge "$MIN_DISK_SECTORS" ] || fail "$DISK_NAME is smaller than 12 GB"
log "install disk: $DISK_NAME ($(( $(cat /sys/block/$DISK_NAME/size) / 2097152 )) GiB)"

# vendor.create_partition_table.start is left unset: in init.recovery.virt.rc it starts
# preinstall_check, which only knows the VM disk and GPU layout.

if [ "$ERASE" = "1" ]; then
    log "erasing $DISK_NAME"
    $SGDISK_EXEC --zap-all $TARGET
    $SGDISK_EXEC --new=1:0:+$EFI_SIZE --typecode=1:ef00 --change-name=1:EFI $TARGET
    $SGDISK_EXEC --new=2:0:+$SUPER_SIZE --change-name=2:super $TARGET
    $SGDISK_EXEC --new=3:0:+1M --change-name=3:misc $TARGET
    $SGDISK_EXEC --new=4:0:+16M --change-name=4:persist $TARGET
    $SGDISK_EXEC --new=5:0:+32M --change-name=5:metadata $TARGET
    $SGDISK_EXEC --new=6:0:+128M --change-name=6:firmware $TARGET
    $SGDISK_EXEC --new=7:0:+100M --change-name=7:vendor_boot_a $TARGET
    $SGDISK_EXEC --new=8:0:+100M --change-name=8:vendor_boot_b $TARGET
    $SGDISK_EXEC --new=9:0:+80M --change-name=9:boot_a $TARGET
    $SGDISK_EXEC --new=10:0:+80M --change-name=10:boot_b $TARGET
    $SGDISK_EXEC --new=11:0:+4M --typecode=11:ef02 --change-name=11:BIOS $TARGET
    # FAT partition for pc_save_logs.sh, readable from any OS; created before userdata,
    # which takes the rest of the disk
    $SGDISK_EXEC --new=13:0:+8M --typecode=13:0700 --change-name=13:pc_logs $TARGET
    $SGDISK_EXEC --new=12:0:0 --change-name=12:userdata $TARGET
elif has_lineage_layout $DISK_NAME; then
    # super_empty_raw.img and OTAs expect super to be exactly SUPER_SIZE
    super_sectors=$($SGDISK_EXEC -i 2 $TARGET | sed -n 's/^Partition size: \([0-9]*\) sectors.*/\1/p')
    [ "$super_sectors" = "$(( ${SUPER_SIZE%G} * 2097152 ))" ] ||
        fail "$DISK_NAME has an older LineageOS layout; choose the erase option to install on it"
    log "$DISK_NAME already has the LineageOS layout, keeping it and its data"
    $SGDISK_EXEC --change-name=7:vendor_boot_a $TARGET
    $SGDISK_EXEC --change-name=8:vendor_boot_b $TARGET
else
    fail "$DISK_NAME has no LineageOS layout to keep; choose the erase option to install on it"
fi

# Wait for ueventd to create the by-name links for the (new) partitions
for i in $(seq 1 50); do
    [ -e /dev/block/by-name/persist ] && [ -e /dev/block/by-name/userdata ] && break
    sleep 0.2
done
[ -e /dev/block/by-name/userdata ] || fail "partitions on $DISK_NAME did not show up"

if [ "$ERASE" = "1" ]; then
    # Clear the start of metadata and userdata so Android formats them on first boot. Only a
    # few domains may write metadata, so pc_clear_partitions.sh does it as recovery
    # (init.recovery.pc.rc).
    for part in metadata userdata; do
        for i in $(seq 1 25); do
            [ -e /dev/block/by-name/$part ] && break
            sleep 0.2
        done
    done
    setprop vendor.pc_install.clear_partitions 1
    for i in $(seq 1 100); do
        [ -n "$(getprop vendor.pc_install.partitions_cleared)" ] && break
        sleep 0.2
    done
    [ "$(getprop vendor.pc_install.partitions_cleared)" = "1" ] ||
        fail "could not clear the metadata and userdata partitions"
fi

if [ "$ERASE" = "1" ] && [ -f /system/etc/pc_logs.img.gz ]; then
    for i in $(seq 1 25); do
        [ -e /dev/block/by-name/pc_logs ] && break
        sleep 0.2
    done
    zcat /system/etc/pc_logs.img.gz | dd of=/dev/block/by-name/pc_logs bs=1M ||
        log "could not format the pc_logs partition, logs will go to the USB stick only"
fi

if [ -f "/system/etc/MBR.img" ]; then
    dd if=/system/etc/MBR.img of=$TARGET bs=446 count=1
fi

if [ -f "/system/etc/super_empty_raw.img" ] && ! dd if=/dev/block/by-name/super bs=256k count=1|strings|grep virt_dynamic_partitions > /dev/null; then
    dd if=/system/etc/super_empty_raw.img of=/dev/block/by-name/super
fi

log "partition table on $DISK_NAME is ready"
setprop vendor.create_partition_table.finish 1
# virt-common's preinstall_check only knows the VM disk layout; the checks above replace it.
setprop vendor.preinstall_check.success 1

exit 0
