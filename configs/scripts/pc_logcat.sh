#!/system/bin/sh
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Copies logcat into the kernel log (stdout is /dev/kmsg_debug, see pc_logcat.rc), so the
# logs pc_save_logs.sh saves have it too. Each kmsg write is one record of at most ~1 KB,
# and logcat's buffered stdout writes several KB at once, which kmsg rejects; so lines are
# passed on one write each (print is a shell builtin), and a too long one only loses itself.

/system/bin/logcat -v threadtime -b main,system,crash '*:I' | while IFS= read -r line; do
    print -r -- "$line"
done
