#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

USES_DEVICE_PC_X86_64 := true

DEVICE_PATH := device/pc/pc_x86_64

# Boot manager
TARGET_BOOT_MANAGER ?= grub

# GRUB: 64-bit UEFI, legacy BIOS, and 32-bit UEFI (Bay Trail / Cherry Trail tablets)
TARGET_GRUB_ARCH := x86_64-efi
TARGET_GRUB_2ND_ARCH := i386-pc
TARGET_GRUB_EFI_EXTRA_ARCHS := i386-efi

# Inherit from common
include device/virt/virt-common/BoardConfigVirtCommon.mk

# Partitions
# virt-common's A/B super is 12 GB. The dynamic partitions need about 3 GB, so keep super
# small and leave the rest of the disk to userdata. Must match pc_create_partition_table.sh.
BOARD_SUPER_PARTITION_SIZE := 4294967296 # 4 GB
BOARD_VIRT_DYNAMIC_PARTITIONS_SIZE := $(shell expr $(BOARD_SUPER_PARTITION_SIZE) - 4194304 )
$(call soong_config_set,VIRT_PREINSTALL_CHECK,SUPER_PARTITION_SIZE,$(BOARD_SUPER_PARTITION_SIZE))

# Arch
# Silvermont (Atom) has no AVX, unlike the sandybridge baseline used for VMs.
TARGET_CPU_ABI := x86_64
TARGET_ARCH := x86_64
TARGET_ARCH_VARIANT := silvermont

# Boot manager
TARGET_GRUB_BOOT_CONFIGS += $(DEVICE_PATH)/bootmgr/grub/grub-boot.cfg

# Bootconfig
BOARD_BOOTCONFIG += \
    androidboot.hardware=pc

# Graphics (Allocator)
$(call soong_config_set_string_list,minigbm_upstream,cflags,-DDRV_I915 -DDRV_XE)

# Graphics (Mesa)
# virgl / virtio keep the target testable in a VM.
BOARD_MESA3D_GALLIUM_DRIVERS += crocus iris virgl
BOARD_MESA3D_VULKAN_DRIVERS += intel intel_hasvk virtio

# Kernel
# loglevel=3: the console shows levels 0-2 only (pc_* scripts use level 2 for what you need
# to see), so the kernel and init logs (levels 3+) don't draw over the installer and recovery UI.
BOARD_KERNEL_CMDLINE += \
    console=tty0 \
    loglevel=3

BOARD_KERNEL_IMAGE_NAME := bzImage
BOARD_LINUX_SERIAL_DEVICE := ttyS0
TARGET_KERNEL_ARCH := x86

TARGET_KERNEL_CONFIG_EXT += \
    device/virt/virtio-common/configs/kernel/virtio-common.config \
    device/virt/virtio_x86_64/configs/kernel/virtio_x86_64.config \
    $(DEVICE_PATH)/configs/kernel/pc.config \
    $(DEVICE_PATH)/configs/kernel/cherrytrail.config

# Pre-install checks (virt-common's checker is VM specific; pc_create_partition_table.sh
# does the checks for this target)
$(call soong_config_set,VIRT_PREINSTALL_CHECK,BOOT_DISK_NAME,mmcblk0)
$(call soong_config_set,VIRT_PREINSTALL_CHECK,USERDATA_DISK_NAME,mmcblk0p12)
$(call soong_config_set,VIRT_PREINSTALL_CHECK,DRM_CARD_NAME,i915)

# Recovery
TARGET_RECOVERY_FSTAB_GENRULE := gen_fstab_pc
TARGET_RECOVERY_PIXEL_FORMAT := ARGB_8888

# SELinux
BOARD_VENDOR_SEPOLICY_DIRS += \
    $(DEVICE_PATH)/sepolicy/vendor
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += \
    $(DEVICE_PATH)/sepolicy/private

# VINTF
DEVICE_MANIFEST_FILE += \
    device/virt/virtio-common/configs/vintf/manifest_target-level-latest.xml
