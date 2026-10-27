/*
 * SPDX-FileCopyrightText: The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

// Installer step that runs before the recovery UI: lists the disks, lets the user pick
// the one to install LineageOS on and confirm erasing it, then hands the choice to
// pc_create_partition_table.sh through vendor.pc_install.{disk,erase}.

#include <android-base/file.h>
#include <android-base/logging.h>
#include <android-base/parseint.h>
#include <android-base/properties.h>
#include <android-base/stringprintf.h>
#include <android-base/strings.h>
#include <android-base/unique_fd.h>
#include <linux/input.h>
#include <minui/minui.h>

#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

using android::base::GetProperty;
using android::base::ReadFileToString;
using android::base::SetProperty;
using android::base::StringPrintf;
using android::base::Trim;
using android::base::unique_fd;

namespace {

// 12 GiB super plus room for the other partitions and userdata
constexpr uint64_t kMinDiskBytes = 16ull * 1024 * 1024 * 1024;

struct Disk {
    std::string name;
    std::string model;
    std::string transport;
    uint64_t size_bytes = 0;
    std::vector<std::string> partitions;  // GPT partition names
    bool has_partition_table = false;
    bool has_lineage = false;
    bool is_installer = false;
};

std::string ReadSysfs(const std::string& path) {
    std::string value;
    ReadFileToString(path, &value);
    return Trim(value);
}

std::string FormatSize(uint64_t bytes) {
    double gb = bytes / 1e9;
    return gb >= 1000 ? StringPrintf("%.1f TB", gb / 1000) : StringPrintf("%.0f GB", gb);
}

bool ReadAt(int fd, uint64_t offset, void* buf, size_t len) {
    return pread(fd, buf, len, offset) == static_cast<ssize_t>(len);
}

// Fills partition info from the GPT, and recognizes the installer image
// (a FAT32 "superfloppy" labelled "install", or the GPT test image).
void ReadPartitionTable(Disk& disk, uint64_t sector_size) {
    unique_fd fd(open(("/dev/block/" + disk.name).c_str(), O_RDONLY | O_CLOEXEC));
    if (fd < 0) {
        PLOG(WARNING) << "open " << disk.name;
        return;
    }

    uint8_t sector0[512];
    if (ReadAt(fd, 0, sector0, sizeof(sector0)) && sector0[510] == 0x55 && sector0[511] == 0xaa) {
        if (!memcmp(sector0 + 82, "FAT32   ", 8) && !memcmp(sector0 + 71, "install", 7)) {
            disk.is_installer = true;
            return;
        }
        disk.has_partition_table = true;  // MBR, possibly the GPT protective one
    }

    uint8_t header[92];
    if (!ReadAt(fd, sector_size, header, sizeof(header)) || memcmp(header, "EFI PART", 8)) {
        return;
    }
    uint64_t entries_lba;
    uint32_t num_entries, entry_size;
    memcpy(&entries_lba, header + 72, 8);
    memcpy(&num_entries, header + 80, 4);
    memcpy(&entry_size, header + 84, 4);
    if (entry_size < 128 || num_entries > 1024) return;

    std::vector<uint8_t> entries(static_cast<size_t>(num_entries) * entry_size);
    if (!ReadAt(fd, entries_lba * sector_size, entries.data(), entries.size())) return;

    disk.has_partition_table = true;
    std::vector<std::string> names(num_entries);  // indexed by partition number - 1
    for (uint32_t i = 0; i < num_entries; i++) {
        const uint8_t* entry = &entries[static_cast<size_t>(i) * entry_size];
        static const uint8_t kZeroGuid[16] = {};
        if (!memcmp(entry, kZeroGuid, 16)) continue;  // unused slot

        std::string name;
        for (int c = 0; c < 36; c++) {
            uint16_t ch = entry[56 + c * 2] | (entry[57 + c * 2] << 8);
            if (!ch) break;
            name += ch < 0x80 ? static_cast<char>(ch) : '?';
        }
        names[i] = name;
        disk.partitions.push_back(name.empty() ? "(unnamed)" : name);
    }

    disk.has_lineage = num_entries >= 12 && names[1] == "super" && names[11] == "userdata";
    disk.is_installer = std::find(names.begin(), names.end(), "LINEAGE_INSTALL") != names.end();
}

std::vector<Disk> ScanDisks() {
    std::vector<Disk> disks;
    std::unique_ptr<DIR, decltype(&closedir)> dir(opendir("/sys/block"), closedir);
    if (!dir) return disks;

    while (dirent* de = readdir(dir.get())) {
        std::string name = de->d_name;
        std::string sys = "/sys/block/" + name;
        Disk disk;
        disk.name = name;

        if (android::base::StartsWith(name, "nvme")) {
            disk.transport = "NVMe";
            disk.model = ReadSysfs(sys + "/device/model");
        } else if (android::base::StartsWith(name, "mmcblk")) {
            // eMMC only: skip SD cards and the eMMC boot / RPMB areas
            if (name.find("boot") != std::string::npos || name.find("rpmb") != std::string::npos ||
                ReadSysfs(sys + "/device/type") != "MMC") {
                continue;
            }
            disk.transport = "eMMC";
            disk.model = ReadSysfs(sys + "/device/name");
        } else if (android::base::StartsWith(name, "sd")) {
            std::string path;
            android::base::Realpath(sys, &path);
            disk.transport = path.find("/usb") != std::string::npos ? "USB"
                             : path.find("/ata") != std::string::npos ? "SATA"
                                                                      : "SCSI";
            disk.model = Trim(ReadSysfs(sys + "/device/vendor") + " " +
                              ReadSysfs(sys + "/device/model"));
        } else if (android::base::StartsWith(name, "vd")) {
            disk.transport = "virtio";
            disk.model = "Virtual disk";
        } else {
            continue;
        }

        uint64_t sector_size = 512;
        android::base::ParseUint(ReadSysfs(sys + "/queue/logical_block_size"), &sector_size);
        uint64_t sectors = 0;
        android::base::ParseUint(ReadSysfs(sys + "/size"), &sectors);
        disk.size_bytes = sectors * 512;  // sysfs size is always in 512-byte units
        if (disk.size_bytes == 0) continue;

        ReadPartitionTable(disk, sector_size);
        if (disk.is_installer) {
            LOG(INFO) << name << " is the installer, not listing it";
            continue;
        }
        disks.push_back(disk);
    }
    std::sort(disks.begin(), disks.end(),
              [](const Disk& a, const Disk& b) { return a.name < b.name; });
    return disks;
}

std::string Describe(const Disk& disk) {
    return StringPrintf("%-8s %-7s %8s  %s", disk.name.c_str(), disk.transport.c_str(),
                        FormatSize(disk.size_bytes).c_str(), disk.model.c_str());
}

std::string Contents(const Disk& disk) {
    if (disk.has_lineage) return "LineageOS";
    if (!disk.has_partition_table) return "empty";
    if (disk.partitions.empty()) return "other partition table";
    std::string list = android::base::Join(disk.partitions, ", ");
    if (list.size() > 60) list = list.substr(0, 57) + "...";
    return StringPrintf("%zu partitions: %s", disk.partitions.size(), list.c_str());
}

// ---- drawing ---------------------------------------------------------------

struct Line {
    std::string text;
    enum Style { kNormal, kTitle, kDim, kWarning } style = kNormal;
};

int g_char_w, g_char_h;

void Draw(const std::vector<Line>& header, const std::vector<std::string>& items,
          const std::vector<bool>& enabled, size_t selected, const std::vector<Line>& footer) {
    const GRFont* font = gr_sys_font();
    int margin = g_char_w * 2;
    int y = g_char_h * 2;

    gr_color(0, 0, 0, 255);
    gr_clear();

    auto text = [&](const Line& line) {
        switch (line.style) {
            case Line::kTitle: gr_color(255, 255, 255, 255); break;
            case Line::kDim: gr_color(150, 150, 155, 255); break;
            case Line::kWarning: gr_color(255, 110, 90, 255); break;
            default: gr_color(220, 220, 225, 255); break;
        }
        gr_text(font, margin, y, line.text.c_str(), line.style == Line::kTitle);
        y += g_char_h + g_char_h / 2;
    };

    for (const auto& line : header) text(line);
    y += g_char_h;

    for (size_t i = 0; i < items.size(); i++) {
        if (i == selected) {
            gr_color(56, 122, 255, 255);
            gr_fill(margin / 2, y - g_char_h / 4, gr_fb_width() - margin / 2,
                    y + g_char_h + g_char_h / 4);
        }
        gr_color(255, 255, 255, 255);
        if (!enabled[i]) gr_color(110, 110, 115, 255);
        gr_text(font, margin, y, items[i].c_str(), i == selected);
        y += g_char_h * 2;
    }

    y += g_char_h;
    for (const auto& line : footer) text(line);
    gr_flip();
}

int g_key = -1;

int OnInput(int fd, uint32_t epevents) {
    input_event ev;
    if (ev_get_input(fd, epevents, &ev) == -1) return -1;
    if (ev.type == EV_KEY && ev.value == 1) g_key = ev.code;
    return 0;
}

int WaitKey() {
    g_key = -1;
    while (g_key < 0) {
        if (!ev_wait(-1)) ev_dispatch();
    }
    return g_key;
}

// Shows a menu and returns the chosen index. Disabled items can't be chosen.
size_t RunMenu(const std::vector<Line>& header, const std::vector<std::string>& items,
               const std::vector<bool>& enabled, const std::vector<Line>& footer) {
    size_t selected = 0;
    while (selected < items.size() && !enabled[selected]) selected++;
    for (;;) {
        Draw(header, items, enabled, selected, footer);
        switch (WaitKey()) {
            case KEY_UP:
            case KEY_VOLUMEUP:
                for (size_t i = selected; i > 0; i--) {
                    if (enabled[i - 1]) {
                        selected = i - 1;
                        break;
                    }
                }
                break;
            case KEY_DOWN:
            case KEY_VOLUMEDOWN:
                for (size_t i = selected + 1; i < items.size(); i++) {
                    if (enabled[i]) {
                        selected = i;
                        break;
                    }
                }
                break;
            case KEY_ENTER:
            case KEY_KPENTER:
            case KEY_POWER:
                if (selected < items.size() && enabled[selected]) return selected;
                break;
        }
    }
}

void Choose(const std::string& disk, bool erase) {
    LOG(INFO) << "installing to " << disk << (erase ? ", erasing it" : ", keeping data");
    SetProperty("vendor.pc_install.erase", erase ? "1" : "0");
    // Set last: pc_create_partition_table.sh starts when this one is set.
    SetProperty("vendor.pc_install.disk", disk);
}

const std::vector<Line> kKeysHelp = {
        {"Up / Down (or Volume keys): move    Enter (or Power): select", Line::kDim}};

}  // namespace

int main(int /* argc */, char** argv) {
    android::base::InitLogging(argv, &android::base::KernelLogger);

    // Disk given on the kernel command line: no questions asked
    std::string preset = GetProperty("ro.boot.install_disk", "");
    if (!preset.empty()) {
        Choose(preset, GetProperty("ro.boot.install_erase", "0") == "1");
        return 0;
    }

    if (gr_init() != 0) {
        LOG(ERROR) << "cannot initialize the display";
        return 1;
    }
    gr_font_size(gr_sys_font(), &g_char_w, &g_char_h);
    ev_init(OnInput);

    for (;;) {
        std::vector<Disk> disks = ScanDisks();

        std::vector<std::string> items;
        std::vector<bool> enabled;
        for (const auto& disk : disks) {
            bool big_enough = disk.size_bytes >= kMinDiskBytes;
            items.push_back(Describe(disk) + "   [" +
                            (big_enough ? Contents(disk) : "too small, needs 16 GB") + "]");
            enabled.push_back(big_enough);
        }
        items.push_back("Rescan disks");
        items.push_back("Reboot");
        items.push_back("Power off");
        enabled.insert(enabled.end(), {true, true, true});

        std::vector<Line> header = {
                {"LineageOS installer", Line::kTitle},
                {"Choose the disk to install LineageOS on.", Line::kNormal},
        };
        if (disks.empty()) {
            header.push_back({"No disks found. Connect one and choose Rescan disks.",
                              Line::kWarning});
        }

        size_t choice = RunMenu(header, items, enabled, kKeysHelp);
        if (choice == disks.size()) continue;
        if (choice == disks.size() + 1) {
            SetProperty("sys.powerctl", "reboot");
            return 0;
        }
        if (choice == disks.size() + 2) {
            SetProperty("sys.powerctl", "shutdown");
            return 0;
        }

        const Disk& disk = disks[choice];
        std::vector<Line> confirm_header = {
                {"Install LineageOS on this disk?", Line::kTitle},
                {Describe(disk), Line::kNormal},
                {"Contents: " + Contents(disk), Line::kNormal},
        };
        std::vector<std::string> options;
        if (disk.has_lineage) {
            confirm_header.push_back(
                    {"LineageOS is already installed here. You can keep its data.", Line::kNormal});
            options = {"Install and keep data", "Erase the whole disk and install", "Back"};
        } else {
            confirm_header.push_back(
                    {"EVERYTHING on this disk will be erased, including all partitions.",
                     Line::kWarning});
            options = {StringPrintf("Erase %s and install", disk.name.c_str()), "Back"};
        }

        size_t action = RunMenu(confirm_header, options, std::vector<bool>(options.size(), true),
                                kKeysHelp);
        if (options[action] == "Back") continue;
        bool erase = !(disk.has_lineage && action == 0);

        Draw({{"Preparing " + disk.name + "...", Line::kTitle}}, {}, {}, 0, {});
        Choose(disk.name, erase);
        return 0;
    }
}
