# LineageOS for x86_64 PCs

```
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
```

Based on `device/virt/virt-common` (GRUB, installer, A/B, partition layout) and
`device/mainline/common` (HALs). It doesn't use the virtio device trees
(`virtio-common`, `virtio_x86_64`) or their kernel: the kernel config, VINTF manifest
and VM test drivers are all here.

Target: modern desktop PCs and laptops. Tested on an AMD A6-9225 laptop, a Steam Deck and,
for 32-bit UEFI and Intel graphics, an Acer One 10 S1003 (Atom x5-Z8350, Cherry Trail).

## Build

```bash
source build/envsetup.sh
breakfast pc_x86_64
m
```

`m` also builds the installer (`espimage-install`, see `build/tasks/installer-image.mk`)
and the OTA zip inside it: `out/target/product/pc_x86_64/lineage-*.img`. Write it to a USB stick
(it's a plain FAT32 image, no partition table):

```bash
sudo dd if=lineage-<version>-pc_x86_64.img of=/dev/sdX bs=4M conv=fsync status=progress
```

## Install

1. Disable Secure Boot. Boot from the USB stick.
2. Choose **Install** in the installer menu.
3. Pick the disk in the list. It shows the internal disks (name, NVMe / SATA / eMMC, size,
   model, current partitions); **Show USB drives and SD cards** adds those, except the
   installer itself. Disks under 12 GB can't be picked. Up / Down or the volume keys move,
   Enter or Power selects. A system installed on a USB drive or SD card starts when it's
   chosen in the PC's boot menu.
4. Confirm. A disk without LineageOS is erased completely. A disk that already has
   LineageOS can be reinstalled keeping its data, or erased.

`pc_install_disk_select` (recovery) asks; `pc_create_partition_table.sh` partitions the disk.
To skip the questions, add `androidboot.install_disk=<name>` (and
`androidboot.install_erase=1` to erase) to the Install entry (press `e` in GRUB).

The kernel runs with `loglevel=3`, so its log doesn't draw over the installer and
recovery. Partitioning errors are still printed on screen; everything else is in `dmesg`.
To debug an install, add `loglevel=7 androidboot.install_logs=1` to the Install entry
(`boot_android_install loglevel=7 androidboot.install_logs=1`): the recovery log, which
includes update_engine's output while a zip installs, is then copied to the screen.

Every reboot, and Ctrl+Alt+Del, saves the logs to `pc_logs/<recovery|android>-<boot id>/`
on the install disk's `pc_logs` partition (8 MB FAT, label `PC_LOGS`), so they can be read
from any other OS on the same PC. The oldest boots are dropped to keep 4 MB free.
`pc_save_logs.sh` takes Ctrl+Alt+Del over from the kernel (`kernel.ctrl-alt-del=0`,
`cad_pid`), saves the logs, then reboots.

- Recovery: `dmesg.txt` and `recovery.log` (recovery and update_engine). Before the disk is
  partitioned, they go to the installer USB stick instead, found by its FAT label
  (`install`) or GPT partition name (`LINEAGE_INSTALL`).
- Android: `dmesg.txt`. `pc_logcat` (system_ext) copies logcat
  (main, system, crash) into the kernel log, so it's in there too. init mounts the
  partition at `/mnt/vendor/pc_logs`.
Disks installed with the old 12 GB super can only be reinstalled with the erase option.

## Partition layout

Same partition numbers as virt-common's A/B layout, so GRUB and the fstab work unchanged.
super is 4 GB instead of 12 GB (the system partitions need about 3 GB) and userdata takes
the rest of the disk:

| # | Name | Size |
|---|---|---|
| 1 | EFI | 256M |
| 2 | super | 4G (`BOARD_SUPER_PARTITION_SIZE`) |
| 3 | misc | 1M |
| 4 | persist | 16M |
| 5 | metadata | 32M |
| 6 | firmware | 128M |
| 7-8 | vendor_boot_a/b | 100M |
| 9-10 | boot_a/b | 80M |
| 11 | BIOS | 4M |
| 12 | userdata | rest |
| 13 | pc_logs | 8M (FAT, before userdata on disk) |

Partitions are found by GPT name (`androidboot.boot_devices=any`), not by disk name, and
GRUB finds the disk by the PERSIST label, so it can be any disk in the machine. Don't keep
two disks with LineageOS installed attached at the same time.

## 32-bit UEFI

`TARGET_GRUB_EFI_EXTRA_ARCHS := i386-efi` (in virt-common's `20-grub.mk`) adds
`EFI/BOOT/BOOTIA32.EFI` and the i386-efi GRUB modules to the installer and to `EFI.img`,
which the install zip and OTAs flash. The kernel has `CONFIG_EFI_MIXED`, so the 64-bit kernel
can use 32-bit firmware services. The installer ISO is still x86_64-efi only; use the
`.img`.

## Desktop

Aimed at desktop PCs and regular laptops (not tablets or convertibles), on top of
LineageOS's tablet base (`common_full_tablet_wifionly`):

- `configs/permissions/pc_desktop.xml` declares `android.hardware.type.pc` and freeform
  windows, like AOSP's `pc_core_hardware.xml`. With both, the window manager starts the
  display in freeform mode, and Android 16's desktop windowing (enabled on the internal
  display by virt-common's tablet overlay, and by default in this release) takes over:
  resizable app windows with a taskbar. The display isn't auto-rotated, and apps get
  PC mouse input handling.
- It marks the sensors PCs don't have (accelerometer, compass, gyroscope, proximity,
  barometer, ...) unavailable; the ambient light sensor stays, some laptops have one.
  The touchscreen features stay declared: most apps implicitly require them, and mouse
  clicks work as touches.
- `overlay/`: dragging a window to the top edge maximizes it.
- `frameworks/base` (WM Shell, `DesktopDisplayModeController`): with the form factor based
  desktop-first switch (enabled in this release), the display only stays in desktop mode
  with both a touchpad and a physical keyboard, so a desktop with a mouse dropped back to
  fullscreen apps, and Launcher3 hid the taskbar on the home screen. FEATURE_PC devices
  are now always desktop-first.

## Display settings

`apps/PcSettings` adds Settings > Display > Screen rotation & resolution:

- Rotation: 0 / 90 / 180 / 270 degrees (`freezeDisplayRotation`), kept across restarts.
- With a GPU driver, the display's own modes: resolution and refresh rate apply right away
  as the user preferred display mode; "Automatic" lets Android choose.
- With the firmware framebuffer (simpledrm, GPUs without a driver), there's one mode, set by
  GRUB at boot: the resolution is saved to GRUB's environment (`persist.sys.pc.boot_resolution`
  -> `pc_display_mode`, see `init.pc.rc`) and used after a restart. The property is
  `pc_display_prop` (`sepolicy/public`, system_ext): set by the app, read by vendor_init. GRUB passes it to the
  kernel with `gfxpayload`, falling back to `auto` (the monitor's preferred mode) when the
  firmware doesn't have it. Without a choice it's `auto`, so the native resolution; with
  software rendering, a lower resolution can be noticeably faster. There's no refresh rate
  to choose here.

## Graphics

`pc_gpu_detect` runs at boot (`post-fs-data`, after waiting up to 10 s for the vendor
kernel modules) and looks at the bound DRM drivers:

- Intel (i915 / xe): Mesa (iris / crocus, Vulkan anv / hasvk), minigbm's Intel backends.
- AMD (amdgpu): Mesa (radeonsi, Vulkan RADV), built with the ACO compiler (no LLVM), and
  minigbm's gbm_mesa backend. amdgpu is a module (`amdgpu.ko`, vendor_dlkm): it can't start
  without its firmware, which is in `/vendor/firmware/amdgpu` (`vendor/pc/firmware`), and
  replaces simpledrm when it binds. GCN 1 / 2 (SI / CIK) cards use amdgpu too.
  Firmware reaches kernel modules through ueventd (`firmware_directories`):
  dlkm_loader_mainline.rc sets `force_sysfs_fallback`, which `sepolicy/vendor` labels
  (`vendor_proc_firmware_config`) so vendor_init may write it. Without that, the kernel only looks
  in its own firmware path, which virt-common points at `/vendor/firmware_mnt`.
- Anything else: SwiftShader software rendering on `simpledrm` (the UEFI framebuffer)
  with minigbm's dumb buffers. This covers NVIDIA until its driver is added, and virtio
  GPUs in a VM.

On machines with both, Intel is preferred, since it usually drives a laptop's own screen.
`pc_gpu_detect` also sets `vendor.hwc.drm.device` to the chosen GPU's card: drm_hwcomposer
otherwise scans `card0`, `card1`, ... until one is missing, and when amdgpu replaces
simpledrm, `card0` is gone. Mesa finds the GPU through its PCI sysfs files (IDs, `uevent`),
which `sepolicy/vendor/file_contexts` labels `sysfs_gpu` for every PCI device, since an AMD
GPU can be anywhere on PCI.

`androidboot.gpu=` / `androidboot.graphics=` override it, e.g. `androidboot.graphics=swiftshader`
to force software rendering on Intel.

## Audio

The kernel has the HD Audio codec drivers found on PC motherboards and laptops (Realtek,
Conexant, Analog Devices, IDT / SigmaTel, VIA, Cirrus, Creative, C-Media, Senary) and
HDMI / DisplayPort audio, built in. AOSP's default AIDL audio HAL plays to ALSA card 0,
device 0, which on most desktops is the motherboard's analog output.

HDA codecs start with their outputs muted, and the HAL only drives `Master`, so
`pc_setup_sound` turns on the output switches (`Front`, `Speaker`, `Headphone`,
`IEC958`, ...) and sets their volumes to 0 dB on every card at boot, like `alsactl init`.
It leaves inputs alone, so microphones aren't looped back to the speakers.

## Wi-Fi

Android drives the first wireless interface (`wlan0`) through `wpa_supplicant` (nl80211),
with no vendor Wi-Fi HAL. The kernel builds the common PC drivers as modules, all loaded at
boot (`BOARD_VENDOR_KERNEL_MODULES_LOAD`), since Android doesn't load drivers on demand:
Realtek rtw88 / rtw89 / rtl8xxxu / rtlwifi, MediaTek mt76, Qualcomm Atheros ath9k_htc /
ath9k / ath10k / ath11k / ath12k, Intel iwlwifi, Broadcom brcmfmac (PCIe, USB) and Ralink
rt2800. RTL8821AU / RTL8812AU USB adapters (e.g. TP-Link Archer T2U) use rtw88's
8821au / 8812au drivers, backported to `kernel/pc/pc` from 6.13 (upstream's rtw88 commits
between 6.12 and 6.13 that the stable tree doesn't have). USB adapters plugged in later
bind to the loaded drivers. Their firmware, and the
Bluetooth firmware of the same chips, is in `vendor/pc/firmware/wireless`.

## Bluetooth

`pc_bt_detect.sh` looks for an adapter before system_server starts: an HCI in
`/sys/class/bluetooth`, or a USB interface of the Bluetooth class, waiting until USB
devices have settled (at most 4 s). Without one, it sets the vendor SKU to
`nobluetooth` (`ro.boot.product.vendor.sku`), and `/vendor/etc/permissions/sku_nobluetooth/`
marks the Bluetooth features unavailable: Android doesn't start Bluetooth, and Settings
and the quick settings panel don't show it. Adapters plugged in later are seen after a
reboot. `androidboot.bluetooth=1` / `0` skips the detection.

## Kernel

Source: `kernel/pc/pc`, a copy of `kernel/virt/virtio` (LineageOS's android16-6.12 GKI
tree) so the virtio target's kernel stays untouched. Its own changes: simpledrm accepts
ARGB8888 / ABGR8888 / XBGR8888 framebuffers (what Android renders into) and converts them
when copying to the firmware's XRGB8888 framebuffer, and rtw88 has the RTL8821AU /
RTL8812AU drivers from 6.13.

`configs/kernel/pc.config`: EFI mixed mode, NVMe/AHCI/eMMC/SD (SDHCI, Realtek card
readers)/USB storage, GPU drivers as modules (i915, xe, amdgpu), simpledrm, Ethernet
(Realtek r8169, Intel e1000e/igb/igc), HD Audio, ACPI battery/AC and laptop drivers,
PS/2 and I2C-HID input.
`configs/kernel/cherrytrail.config`: Bay Trail / Cherry Trail GPIO, LPSS, I2C, PWM,
PMICs and their ACPI OpRegions (needed for eMMC and panel power), AXP288 battery.

`configs/kernel/vm.config`: VirtIO devices, 9p and the sound cards QEMU emulates, so the
target can be tested in a VM first.

## Known gaps

- Cameras are not set up yet. Tablets and old Atom / budget Celeron machines (SDIO Wi-Fi,
  UART Bluetooth, I2S audio, touchscreens) aren't targeted.
- Hardware graphics are Intel and AMD only. NVIDIA runs on software rendering until
  nouveau + NVK are added. NVIDIA's open kernel module alone doesn't
  help: its OpenGL / Vulkan libraries are closed and only built for glibc Linux.
- Wi-Fi: only `wlan0` (the first adapter) is used.
- Audio: laptops whose speakers sit behind an amplifier (Cirrus CS35L41/56,
  TI TAS2781) or whose microphones need Intel SOF (most since ~2019) need more drivers
  and firmware.
- 2 GB RAM is tight for Android 16. `androidboot.low_perf=1` (GRUB settings) helps.
