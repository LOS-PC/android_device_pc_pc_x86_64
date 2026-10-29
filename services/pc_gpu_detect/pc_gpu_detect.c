/*
 * SPDX-FileCopyrightText: The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Picks the graphics stack from the DRM drivers that are bound:
 * - Intel (i915 / xe): Mesa (iris / crocus, anv / hasvk), minigbm's gbm_mesa backend.
 * - AMD (amdgpu): Mesa (radeonsi, RADV), minigbm's gbm_mesa backend.
 * - Anything else (simpledrm on the firmware framebuffer, e.g. NVIDIA GPUs whose driver
 *   isn't built yet, or virtio_gpu in a VM): SwiftShader software rendering, with
 *   minigbm's dumb buffer backend.
 * androidboot.gpu / androidboot.graphics override the choice.
 *
 * The GPU drivers (amdgpu, i915, xe) are modules (they need firmware from /vendor), so this
 * waits for the vendor modules to be loaded first: once one binds, it replaces simpledrm.
 *
 * It also tells drm_hwcomposer which card to use (vendor.hwc.drm.device): by default it
 * scans /dev/dri/card0, card1, ... and stops at the first missing one, and when a GPU
 * driver replaces simpledrm, card0 is gone and the GPU is card1.
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
// dlkm_loader_mainline sets vendor.dlkm.modules.ready once the vendor modules are loaded
#define MODULES_TIMEOUT_MS 10000

static bool is_intel(const char* driver) {
    return !strcmp(driver, "i915") || !strcmp(driver, "xe");
}

static bool is_amd(const char* driver) {
    return !strcmp(driver, "amdgpu");
}

static void wait_for_modules() {
    for (int ms = 0; ms < MODULES_TIMEOUT_MS; ms += 100) {
        if (property_get_bool("vendor.dlkm.modules.ready", false)) return;
        usleep(100 * 1000);
    }
    ALOGW("Vendor modules not loaded after %d ms, GPU drivers may be missing",
          MODULES_TIMEOUT_MS);
}

int main() {
    char drivers[MAX_CARDS][32] = {};
    int card_index[MAX_CARDS] = {};
    int num_cards = 0;
    int card = -1;  // index in drivers[] of the card that drives the display
    char gpu[PROPERTY_VALUE_MAX] = "";
    char graphics[PROPERTY_VALUE_MAX] = "";

    wait_for_modules();

    for (int i = 0; i < MAX_CARDS; i++) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/dri/card%d", i);
        int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;

        drmVersionPtr version = drmGetVersion(fd);
        if (version) {
            ALOGI("card%d: %s", i, version->name);
            card_index[num_cards] = i;
            strlcpy(drivers[num_cards++], version->name, sizeof(drivers[0]));
            drmFreeVersion(version);
        }
        close(fd);
    }

    property_get("ro.boot.gpu", gpu, "");
    if (!gpu[0]) {
        // On hybrid machines prefer Intel, which usually drives the built-in display
        for (int i = 0; i < num_cards && card < 0; i++) {
            if (is_intel(drivers[i])) {
                strlcpy(gpu, "intel", sizeof(gpu));
                card = i;
            }
        }
        for (int i = 0; i < num_cards && card < 0; i++) {
            if (is_amd(drivers[i])) {
                strlcpy(gpu, "amd", sizeof(gpu));
                card = i;
            }
        }
        if (card < 0 && num_cards) {
            strlcpy(gpu, drivers[0], sizeof(gpu));
            card = 0;
        }
        if (card < 0) strlcpy(gpu, "none", sizeof(gpu));
    } else if (num_cards) {
        card = 0;
    }

    property_get("ro.boot.graphics", graphics, "");
    if (!graphics[0]) {
        if (!strcmp(gpu, "intel") || !strcmp(gpu, "amd")) {
            strlcpy(graphics, "mesa", sizeof(graphics));
        } else {
            ALOGW("No supported GPU driver (display driver: %s), using software rendering", gpu);
            strlcpy(graphics, "swiftshader", sizeof(graphics));
        }
    }

    // Mesa's GPUs allocate through Mesa's GBM, which knows each driver's tiling and
    // modifiers (minigbm's own i915 / xe backends aren't built for TARGET_MINIGBM_PLATFORM
    // generic). minigbm would fall back to it by itself when ro.hardware.egl is mesa, but
    // init sets that after the allocator starts. simpledrm and friends get dumb buffers,
    // which work on any KMS driver.
    if (!strcmp(gpu, "amd") || !strcmp(gpu, "intel")) {
        property_set("vendor.minigbm.generic_backend", "gbm_mesa");
    } else {
        property_set("vendor.minigbm.generic_backend", "dumb_generic");
    }

    if (card >= 0) {
        char device[32];
        snprintf(device, sizeof(device), "/dev/dri/card%d", card_index[card]);
        property_set("vendor.hwc.drm.device", device);
        ALOGI("display: %s", device);
    }

    ALOGI("gpu=%s graphics=%s", gpu, graphics);
    property_set("ro.vendor.graphics.gpu", gpu);
    property_set("ro.vendor.graphics", graphics);
    return EXIT_SUCCESS;
}
