/*
 * SPDX-FileCopyrightText: The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Unmutes the outputs of every sound card at boot, like alsactl init does on desktop
 * Linux. HD Audio codecs come up with their output amps muted or at 0, and the audio HAL
 * only drives "Master Playback Switch / Volume" (and one hardware volume control), so
 * without this the analog outputs stay silent.
 *
 * Only output controls are touched: unmuting e.g. "Mic Playback Switch" would loop the
 * microphone back to the speakers. Volumes go to 100%, which is 0 dB on HDA codecs; the
 * audio HAL then sets the actual level through Master.
 *
 * It also picks the output and input the audio HAL uses by default, which would otherwise be
 * card 0 device 0: on PCs card 0 is often the GPU's HDMI audio, whose devices start at 3.
 */

#define LOG_TAG "pc_setup_sound"

#include <log/log.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/system_properties.h>
#include <tinyalsa/mixer.h>

#define MAX_CARDS 32

// Output controls, as "<name> Playback Switch" / "<name> Playback Volume"
static const char* const kOutputs[] = {
        "Master",  "Front",        "Surround",  "Center",       "LFE",      "Side",
        "Speaker", "Bass Speaker", "Headphone", "Headphone+LO", "Line Out", "PCM",
        "IEC958",
};

static bool is_output_control(const char* name, const char* suffix) {
    for (size_t i = 0; i < sizeof(kOutputs) / sizeof(kOutputs[0]); i++) {
        size_t len = strlen(kOutputs[i]);
        // "Front Playback Switch", and indexed ones like "IEC958 Playback Switch" on HDMI
        if (!strncmp(name, kOutputs[i], len) && name[len] == ' ' &&
            !strcmp(name + len + 1, suffix)) {
            return true;
        }
    }
    return false;
}

static int setup_card(unsigned int card) {
    struct mixer* mixer = mixer_open(card);
    if (!mixer) return -1;

    unsigned int changed = 0;
    for (unsigned int i = 0; i < mixer_get_num_ctls(mixer); i++) {
        struct mixer_ctl* ctl = mixer_get_ctl(mixer, i);
        const char* name = mixer_ctl_get_name(ctl);
        enum mixer_ctl_type type = mixer_ctl_get_type(ctl);
        bool is_switch = type == MIXER_CTL_TYPE_BOOL &&
                         is_output_control(name, "Playback Switch");
        bool is_volume = type == MIXER_CTL_TYPE_INT &&
                         is_output_control(name, "Playback Volume");
        if (!is_switch && !is_volume) continue;

        for (unsigned int v = 0; v < mixer_ctl_get_num_values(ctl); v++) {
            int ret = is_switch ? mixer_ctl_set_value(ctl, v, 1)
                                : mixer_ctl_set_percent(ctl, v, 100);
            if (ret) ALOGW("card%u: failed to set %s", card, name);
        }
        changed++;
    }

    ALOGI("card%u (%s): unmuted %u output controls", card, mixer_get_name(mixer), changed);
    mixer_close(mixer);
    return 0;
}

// Lower is better: the speakers / headphone jack / built-in microphone, then S/PDIF, then
// HDMI / DisplayPort
static int pcm_rank(const char* name) {
    if (strstr(name, "HDMI") || strstr(name, "DisplayPort")) return 2;
    if (strstr(name, "Digital") || strstr(name, "IEC958") || strstr(name, "SPDIF")) return 1;
    return 0;
}

// Picks the output or input the audio HAL uses unless one is chosen in Settings (PcSettings),
// from /proc/asound/pcm, whose lines look like
// "01-00: ALC3227 Analog : ALC3227 Analog : playback 1 : capture 1"
static void choose_pcm(bool input) {
    const char* direction = input ? "input" : "output";
    FILE* f = fopen("/proc/asound/pcm", "re");
    if (!f) {
        ALOGW("no /proc/asound/pcm, the audio HAL uses card 0");
        return;
    }

    char line[256], best_name[80] = "";
    unsigned int card, device, best_card = 0, best_device = 0;
    int best_rank = -1;
    while (fgets(line, sizeof(line), f)) {
        int name_start;
        if (sscanf(line, "%u-%u: %n", &card, &device, &name_start) != 2) continue;
        if (!strstr(line, input ? ": capture " : ": playback ")) continue;

        char* name = line + name_start;
        char* end = strstr(name, " : ");
        if (end) *end = '\0';

        int rank = pcm_rank(name);
        if (best_rank < 0 || rank < best_rank) {
            best_rank = rank;
            best_card = card;
            best_device = device;
            snprintf(best_name, sizeof(best_name), "%s", name);
        }
    }
    fclose(f);

    if (best_rank < 0) {
        ALOGI("No %s devices", direction);
        return;
    }

    char prop[64], value[32];
    snprintf(prop, sizeof(prop), "persist.vendor.audio.primary.auto_%s", direction);
    snprintf(value, sizeof(value), "%u,%u", best_card, best_device);
    __system_property_set(prop, value);
    ALOGI("Default %s: card%u device %u (%s)", direction, best_card, best_device, best_name);
}

int main() {
    int cards = 0;
    // Card numbers can have gaps, so try them all
    for (unsigned int card = 0; card < MAX_CARDS; card++) {
        if (!setup_card(card)) cards++;
    }
    if (!cards) ALOGI("No sound cards");

    choose_pcm(false);
    choose_pcm(true);
    return 0;
}
