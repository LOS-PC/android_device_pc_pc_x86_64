# LineageOS for x86_64 PCs

```
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
```

Based on `device/virt/virt-common` (GRUB, installer, A/B, partition layout) and
`device/mainline/common` (HALs). It replaces `virtio-common` with real hardware support.

First target hardware: Acer One 10 S1003 (Atom x5-Z8350, Cherry Trail, 2 GB RAM,
32 GB eMMC, 32-bit UEFI).

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
3. Pick the disk in the list. It shows every disk except the installer itself (name,
   NVMe / SATA / eMMC / USB, size, model, current partitions); disks under 16 GB can't be
   picked. Up / Down or the volume keys move, Enter or Power selects.
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

## Graphics

`pc_gpu_detect` runs at boot and looks at the bound DRM drivers:

- Intel (i915 / xe): Mesa (iris / crocus, Vulkan anv / hasvk).
- Anything else: SwiftShader software rendering on `simpledrm` (the UEFI framebuffer)
  with minigbm's dumb buffers. This covers NVIDIA and AMD until their drivers are added,
  and virtio GPUs in a VM.

`androidboot.gpu=` / `androidboot.graphics=` override it, e.g. `androidboot.graphics=swiftshader`
to force software rendering on Intel.

## Kernel

`configs/kernel/pc.config`: EFI mixed mode, NVMe/AHCI/eMMC/USB storage, built-in i915,
simpledrm, Ethernet (Realtek r8169, Intel e1000e/igb/igc), ACPI battery/AC, PS/2 and
I2C-HID input.
`configs/kernel/cherrytrail.config`: Bay Trail / Cherry Trail GPIO, LPSS, I2C, PWM,
PMICs and their ACPI OpRegions (needed for eMMC and panel power), AXP288 battery.

The virtio drivers are kept, so the target can be tested in a VM first.

## Known gaps

- Battery and suspend: still virt-common's fake battery HAL and no suspend.
- Wi-Fi (RTL8723BS on many Cherry Trail tablets), audio, touchscreen and cameras are not
  set up yet.
- Hardware graphics are Intel only. AMD and NVIDIA run on software rendering until Mesa
  radeonsi/RADV and an NVIDIA driver (nouveau/NVK or NVIDIA's open kernel module) are added.
- Wi-Fi and audio on desktops are not set up yet; Ethernet works for the common chips.
- 2 GB RAM is tight for Android 16. `androidboot.low_perf=1` (GRUB settings) helps.
