#!/vendor/bin/sh
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Saves the logs to pc_logs/<recovery|android>-<boot id>/ on the install disk's pc_logs
# partition (8 MB, FAT, created by pc_create_partition_table.sh):
# - recovery (/system/bin/pc_save_logs.sh, run with sh): the kernel log and the recovery
#   log, which recovery and update_engine_sideload write to. Falls back to the installer
#   USB stick when the disk has no pc_logs partition yet.
# - Android (/vendor/bin/pc_save_logs.sh): the kernel log, which pc_logcat (system_ext)
#   fills with logcat, split into dmesg.txt.gz (kernel) and logcat.txt.gz, plus
#   kernel-early.txt, the kernel's own messages a minute into the boot. init mounts the
#   partition at /mnt/vendor/pc_logs.
#
# save:  save the logs once (init runs this on shutdown, so every reboot saves them)
# watch: take over Ctrl+Alt+Del from the kernel, which would reboot right away; save the
#        logs, then reboot

# Only the recovery ramdisk has /system/bin/pc_save_logs.sh
if [ -e /system/bin/pc_save_logs.sh ]; then
    BOOT_KIND=recovery
else
    BOOT_KIND=android
    # Vendor code can't run /system binaries
    PATH=/vendor/bin
    ANDROID_MOUNTPOINT=/mnt/vendor/pc_logs
fi

MOUNTPOINT=/tmp/pc_logs_mnt
PC_LOGS_PARTITION=/dev/block/by-name/pc_logs
# Boots kept on the pc_logs partition, and the free space (KiB) left for the new one;
# older boots are dropped to keep both
KEEP_BOOTS=4
MIN_FREE_KB=4608
# A logcat line pc_logcat copied into the kernel log: "[  12.345678] MM-DD HH:MM:SS.mmm ..."
LOGCAT_LINE='^\[ *[0-9]+\.[0-9]+\] [0-9]{2}-[0-9]{2} [0-9:.]+ '
# Seconds after this script starts (at fs, a few seconds into the boot) to save kernel-early.txt
KERNEL_EARLY_DELAY=60

# Level 2 shows on screen (loglevel=3), level 6 only in dmesg
log() {
    echo "<2>pc_logs: $*" > /dev/kmsg
}

log_info() {
    echo "<6>pc_logs: $*" > /dev/kmsg
}

# The installer is a FAT32 "superfloppy" labelled "install", or a GPT disk with a partition
# named LINEAGE_INSTALL (scripts/make_usb_image.sh).
# Only sd* disks are checked: USB sticks are SCSI disks.
find_installer() {
    for sys in /sys/class/block/sd*; do
        name=${sys##*/}
        if grep -q "^PARTNAME=LINEAGE_INSTALL$" $sys/uevent 2>/dev/null; then
            echo $name
            return 0
        fi
        [ -e $sys/partition ] && continue
        if [ "$(dd if=/dev/block/$name bs=1 skip=82 count=5 2>/dev/null)" = "FAT32" ] &&
                [ "$(dd if=/dev/block/$name bs=1 skip=71 count=7 2>/dev/null)" = "install" ]; then
            echo $name
            return 0
        fi
    done
    return 1
}

# Prints the mountpoint of the installer stick (recovery's own mount of it if it has one),
# mounting it if needed
mount_installer() {
    disk=$(find_installer) || { log "installer USB stick not found, logs not saved"; return 1; }

    # Recovery mounts USB sticks itself (/storage/<id>); its device node is
    # /dev/block/volmgr/public:<major>_<minor>.
    devnum=$(cat /sys/class/block/$disk/dev)
    mnt=$(while read -r dev mp fstype rest; do
        case "$dev" in
            /dev/block/$disk|*/public:${devnum%:*}_${devnum#*:}) echo $mp; break ;;
        esac
    done < /proc/mounts)
    if [ -n "$mnt" ]; then
        echo $mnt
        return 0
    fi
    mkdir -p $MOUNTPOINT
    if ! err=$(mount -t vfat -o rw,noatime /dev/block/$disk $MOUNTPOINT 2>&1); then
        log "could not mount $disk ($err), logs not saved"
        return 1
    fi
    echo $MOUNTPOINT
}

# stat -f rather than df, which looks at every mount
free_kb() {
    stat -f -c "%a %S" $1 | { read -r blocks size; echo $((blocks * size / 1024)); }
}

# Prints (and creates) this boot's directory on the partition mounted at $1, after dropping the
# oldest boots (of either kind) to keep KEEP_BOOTS including this one and MIN_FREE_KB free
boot_dir() {
    mkdir -p $1/pc_logs
    dir=$1/pc_logs/$BOOT_KIND-$(cut -c1-8 /proc/sys/kernel/random/boot_id)
    ls -1td $1/pc_logs/*-* 2>/dev/null | grep -v "^$dir$" |
        tail -n +$KEEP_BOOTS | while read -r old; do rm -rf "$old"; done
    while [ "$(free_kb $1)" -lt $MIN_FREE_KB ]; do
        old=$(ls -1td $1/pc_logs/*-* 2>/dev/null | grep -v "^$dir$" | tail -n 1)
        [ -n "$old" ] || break
        rm -rf "$old"
    done
    mkdir -p $dir
    echo $dir
}

# Android: once the drivers are up, save the kernel's own messages (without pc_logcat's
# logcat lines) to kernel-early.txt, in case logcat fills the kernel log and pushes the
# boot's driver messages (firmware, USB IDs) out before the logs are saved.
save_kernel_early() {
    grep -q " $ANDROID_MOUNTPOINT " /proc/mounts || return 1
    dir=$(boot_dir $ANDROID_MOUNTPOINT)
    dmesg 2>&1 | grep -v -E "$LOGCAT_LINE" > $dir/kernel-early.txt
    sync
    log_info "kernel messages saved to ${dir#$ANDROID_MOUNTPOINT/}/kernel-early.txt"
}

save() {
    if [ $BOOT_KIND = android ]; then
        where="the pc_logs partition"
        mnt=$ANDROID_MOUNTPOINT
        grep -q " $mnt " /proc/mounts ||
            { log "the pc_logs partition is not mounted, logs not saved"; return 1; }
    elif [ -e $PC_LOGS_PARTITION ]; then
        where="the pc_logs partition"
        mnt=$MOUNTPOINT
        mkdir -p $mnt
        if ! err=$(mount -t vfat -o rw,noatime $PC_LOGS_PARTITION $mnt 2>&1); then
            log "could not mount the pc_logs partition ($err), logs not saved"
            return 1
        fi
    else
        where="the USB stick"
        mnt=$(mount_installer) || return 1
    fi

    dir=$(boot_dir $mnt)
    date > $dir/saved_at.txt
    if [ $BOOT_KIND = android ]; then
        # The kernel log holds both; split them, compressed (a full 16 MB log is about 1.5 MB)
        dmesg 2>&1 | grep -v -E "$LOGCAT_LINE" | gzip > $dir/dmesg.txt.gz
        dmesg 2>&1 | grep -E "$LOGCAT_LINE" | gzip > $dir/logcat.txt.gz
    else
        dmesg > $dir/dmesg.txt 2>&1
        cp /tmp/recovery.log $dir/recovery.log 2>/dev/null
    fi
    sync
    [ $mnt = $MOUNTPOINT ] && umount $mnt
    log "logs saved to ${dir#$mnt/} on $where"
}

case "$1" in
    save)
        save
        ;;
    watch)
        # With ctrl-alt-del set to 0 the kernel sends SIGINT to cad_pid instead of rebooting
        trap 'log "Ctrl+Alt+Del: saving logs, then rebooting"; save; setprop sys.powerctl reboot; exit 0' INT
        if echo $$ > /proc/sys/kernel/cad_pid && echo 0 > /proc/sys/kernel/ctrl-alt-del; then
            log_info "Ctrl+Alt+Del saves the logs before rebooting"
        else
            log "could not take over Ctrl+Alt+Del, it reboots without saving logs"
        fi
        [ $BOOT_KIND = android ] && { sleep $KERNEL_EARLY_DELAY; save_kernel_early; } &
        while true; do
            sleep 1
        done
        ;;
esac

exit 0
