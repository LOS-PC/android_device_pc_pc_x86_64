# Do not set interpreter, this script is executed by init in android recovery
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Copies the recovery log (recovery and update_engine_sideload write to it) to the kernel
# log, so it shows on screen with loglevel=7. Started with androidboot.install_logs=1.

tail -n +1 -F /tmp/recovery.log 2>/dev/null | while IFS= read -r line; do
    echo "<4>recovery: $line" > /dev/kmsg
done
