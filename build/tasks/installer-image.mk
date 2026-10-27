#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

ifeq ($(USES_DEVICE_PC_X86_64),true)

# Build the installer image (and the OTA zip it contains) with a plain `m`.
# Refers to the phony target rather than INSTALLED_ESPIMAGE_INSTALL_TARGET because
# this file is included before virt-common's build tasks define it.
droidcore: espimage-install

endif # USES_DEVICE_PC_X86_64
