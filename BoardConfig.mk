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
# virt-common's 2048 inodes don't hold the firmware (vendor/pc/firmware: GPU, Wi-Fi and
# Bluetooth, about 1900 files, directories and symlinks)
BOARD_VENDORIMAGE_EXTFS_INODE_COUNT := 8192

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
# nouveau: OpenGL ES for NVIDIA (no Vulkan yet: NVK needs Rust in Mesa's Android build).
# virgl / virtio keep the target testable in a VM.
BOARD_MESA3D_GALLIUM_DRIVERS += crocus iris nouveau radeonsi virgl
BOARD_MESA3D_VULKAN_DRIVERS += amd intel intel_hasvk virtio

# Kernel
# loglevel=3: the console shows levels 0-2 only (pc_* scripts use level 2 for what you need
# to see), so the kernel and init logs (levels 3+) don't draw over the installer and recovery UI.
# log_buf_len=16M: pc_logcat copies logcat into the kernel log, which mainline-common's 4M fills
# within minutes of booting; pc_save_logs.sh splits the two again when saving. The kernel keeps
# the largest log_buf_len it's given.
# video.brightness_switch_enabled=0: ACPI video changes the backlight on the brightness keys by
# itself and also passes them on; Android (the light HAL) does it, so the kernel must not.
# nouveau.atomic=1: nouveau only exposes atomic modesetting when asked, and drm_hwcomposer
# needs it (without it, it finds no display and the screen stays black).
BOARD_KERNEL_CMDLINE += \
    console=tty0 \
    log_buf_len=16M \
    loglevel=3 \
    nouveau.atomic=1 \
    video.brightness_switch_enabled=0

# GPU drivers are modules, loaded once /vendor (their firmware) is there
BOARD_VENDOR_KERNEL_MODULES_LOAD += \
    amdgpu.ko \
    i915.ko \
    nouveau.ko \
    xe.ko

# Wi-Fi drivers (see configs/kernel/pc.config). Android doesn't load modules on demand
# (no modprobe), so the helpers drivers would load themselves are listed too: iwlwifi's
# iwldvm / iwlmvm and brcmfmac's vendor modules.
BOARD_VENDOR_KERNEL_MODULES_LOAD += \
    ath9k.ko \
    ath9k_htc.ko \
    ath10k_pci.ko \
    ath11k_pci.ko \
    ath12k.ko \
    brcmfmac.ko \
    brcmfmac-bca.ko \
    brcmfmac-cyw.ko \
    brcmfmac-wcc.ko \
    iwlwifi.ko \
    iwldvm.ko \
    iwlmvm.ko \
    mt7601u.ko \
    mt76x0u.ko \
    mt76x2u.ko \
    mt7921e.ko \
    mt7921u.ko \
    mt7925e.ko \
    mt7925u.ko \
    rt2800pci.ko \
    rt2800usb.ko \
    rtl8188ee.ko \
    rtl8192ee.ko \
    rtl8723be.ko \
    rtl8821ae.ko \
    rtl8xxxu.ko \
    rtw88_8723de.ko \
    rtw88_8723du.ko \
    rtw88_8812au.ko \
    rtw88_8821au.ko \
    rtw88_8821ce.ko \
    rtw88_8821cu.ko \
    rtw88_8822be.ko \
    rtw88_8822bu.ko \
    rtw88_8822ce.ko \
    rtw88_8822cu.ko \
    rtw89_8851be.ko \
    rtw89_8852ae.ko \
    rtw89_8852be.ko \
    rtw89_8852ce.ko \
    rtw89_8922ae.ko

BOARD_KERNEL_IMAGE_NAME := bzImage
BOARD_LINUX_SERIAL_DEVICE := ttyS0
TARGET_KERNEL_ARCH := x86

TARGET_KERNEL_CONFIG_EXT += \
    $(DEVICE_PATH)/configs/kernel/vm.config \
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
SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS += \
    $(DEVICE_PATH)/sepolicy/public

# VINTF
DEVICE_MANIFEST_FILE += \
    $(DEVICE_PATH)/configs/vintf/manifest.xml
