/*
 * SPDX-FileCopyrightText: The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Picks the graphics stack from the DRM drivers that are bound:
 * - Intel (i915 / xe): Mesa.
 * - Anything else (simpledrm on the firmware framebuffer, e.g. NVIDIA or AMD GPUs whose
 *   drivers aren't built yet, or virtio_gpu in a VM): SwiftShader software rendering, with
 *   minigbm's dumb buffer backend.
 * androidboot.gpu / androidboot.graphics override the choice.
 */

#define LOG_TAG "pc_gpu_detect"

#include <cutils/log.h>
#include <cutils/properties.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>

#define MAX_CARDS 8

static bool is_intel(const char* driver) {
    return !strcmp(driver, "i915") || !strcmp(driver, "xe");
}

int main() {
    char drivers[MAX_CARDS][32] = {};
    int num_cards = 0;
    char gpu[PROPERTY_VALUE_MAX] = "";
    char graphics[PROPERTY_VALUE_MAX] = "";

    for (int i = 0; i < MAX_CARDS; i++) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/dri/card%d", i);
        int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;

        drmVersionPtr version = drmGetVersion(fd);
        if (version) {
            ALOGI("card%d: %s", i, version->name);
            strlcpy(drivers[num_cards++], version->name, sizeof(drivers[0]));
            drmFreeVersion(version);
        }
        close(fd);
    }

    property_get("ro.boot.gpu", gpu, "");
    if (!gpu[0]) {
        // Prefer Intel on hybrid machines, since it's the only GPU with a driver
        for (int i = 0; i < num_cards && !gpu[0]; i++) {
            if (is_intel(drivers[i])) strlcpy(gpu, "intel", sizeof(gpu));
        }
        if (!gpu[0]) strlcpy(gpu, num_cards ? drivers[0] : "none", sizeof(gpu));
    }

    property_get("ro.boot.graphics", graphics, "");
    if (!graphics[0]) {
        if (!strcmp(gpu, "intel")) {
            strlcpy(graphics, "mesa", sizeof(graphics));
        } else {
            ALOGW("No supported GPU driver (display driver: %s), using software rendering", gpu);
            strlcpy(graphics, "swiftshader", sizeof(graphics));
        }
    }

    // minigbm has no backend for simpledrm and friends; dumb buffers work on any KMS driver
    if (strcmp(gpu, "intel")) {
        property_set("vendor.minigbm.generic_backend", "dumb_generic");
    }

    ALOGI("gpu=%s graphics=%s", gpu, graphics);
    property_set("ro.vendor.graphics.gpu", gpu);
    property_set("ro.vendor.graphics", graphics);
    return EXIT_SUCCESS;
}
