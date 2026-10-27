#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

# Inherit from common
$(call inherit-product, device/virt/virt-common/virt-common.mk)

DEVICE_PATH := device/pc/pc_x86_64

# Graphics (Allocator)
TARGET_GRAPHICS_ALLOCATOR_HAL := minigbm-upstream
TARGET_MINIGBM_PLATFORM := generic

# Graphics (Composer)
TARGET_GRAPHICS_COMPOSER_HAL := drm_hwcomposer
TARGET_DRM_HWCOMPOSER_VARIANT := upstream

# Graphics
PRODUCT_PACKAGES += \
    pc_gpu_detect

# Logs
PRODUCT_PACKAGES += \
    pc_logcat.sh

# Init
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/configs/init/init.pc.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.pc.rc \
    $(DEVICE_PATH)/configs/init/pc_logcat.rc:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/init/pc_logcat.rc \
    $(DEVICE_PATH)/configs/scripts/pc_save_logs.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_save_logs.sh

PRODUCT_PACKAGES += \
    fstab.pc \
    fstab.pc.vendor_ramdisk

# Kernel
TARGET_KERNEL_SOURCE := kernel/virt/virtio

# Recovery
PRODUCT_PACKAGES += \
    pc_install_disk_select

PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/configs/init/init.recovery.pc.rc:$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.pc.rc \
    $(DEVICE_PATH)/configs/scripts/pc_install_logs.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/bin/pc_install_logs.sh \
    $(DEVICE_PATH)/configs/pc_logs/pc_logs.img.gz:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/pc_logs.img.gz \
    $(DEVICE_PATH)/configs/scripts/pc_save_logs.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/bin/pc_save_logs.sh \
    $(DEVICE_PATH)/configs/scripts/pc_create_partition_table.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/bin/pc_create_partition_table.sh

# Shipping API level
PRODUCT_SHIPPING_API_LEVEL := 36

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(DEVICE_PATH)
