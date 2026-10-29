# Do not set interpreter, this script is executed by init in android recovery
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Clears the start of metadata and userdata on a disk pc_create_partition_table.sh just erased.
# New partitions keep whatever the disk held before, and Android formats them on first boot only
# if they start with zeros (libcutils' partition_wiped). Runs as recovery, one of the few domains
# allowed to write the metadata partition; pc_create_partition_table.sh waits for
# vendor.pc_install.partitions_cleared.

result=1
for part in metadata userdata; do
    if ! dd if=/dev/zero of=/dev/block/by-name/$part bs=1M count=1 conv=fsync; then
        echo "<2>pc_install: could not clear the $part partition" > /dev/kmsg
        result=0
    fi
done
setprop vendor.pc_install.partitions_cleared $result
