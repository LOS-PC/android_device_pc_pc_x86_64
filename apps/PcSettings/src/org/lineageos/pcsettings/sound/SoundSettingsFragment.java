/*
 * SPDX-FileCopyrightText: The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.pcsettings.sound;

import android.os.Bundle;
import android.os.SystemProperties;
import android.util.Log;

import androidx.preference.ListPreference;
import androidx.preference.Preference;

import com.android.settingslib.widget.SettingsBasePreferenceFragment;

import org.lineageos.pcsettings.R;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Sound output and input: which device of which sound card the audio HAL uses.
 *
 * PCs often have several sound cards (the motherboard's or laptop's, HDMI / DisplayPort audio
 * on the GPU, USB headsets), and Android's audio HAL uses a single one per direction. The
 * choice ("<card>,<device>", or "auto" for the one pc_setup_sound picks at boot) goes to
 * persist.sys.pc.audio.{output,input}, which init.pc.rc passes on to the audio HAL. The HAL
 * reads it whenever a stream starts, so it applies from the next sound on.
 */
public class SoundSettingsFragment extends SettingsBasePreferenceFragment
        implements Preference.OnPreferenceChangeListener {

    private static final String TAG = "PcSoundSettings";

    private static final String KEY_OUTPUT = "output";
    private static final String KEY_INPUT = "input";

    private static final String AUTOMATIC = "auto";

    private static final String PROP_OUTPUT = "persist.sys.pc.audio.output";
    private static final String PROP_INPUT = "persist.sys.pc.audio.input";

    private ListPreference mOutput;
    private ListPreference mInput;

    @Override
    public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
        setPreferencesFromResource(R.xml.sound_settings, rootKey);

        mOutput = findPreference(KEY_OUTPUT);
        mInput = findPreference(KEY_INPUT);
        mOutput.setOnPreferenceChangeListener(this);
        mInput.setOnPreferenceChangeListener(this);
        mOutput.setSummaryProvider(ListPreference.SimpleSummaryProvider.getInstance());
        mInput.setSummaryProvider(ListPreference.SimpleSummaryProvider.getInstance());
    }

    @Override
    public void onResume() {
        super.onResume();
        // USB sound cards come and go
        updateDevices();
    }

    @Override
    public boolean onPreferenceChange(Preference preference, Object newValue) {
        SystemProperties.set(preference == mOutput ? PROP_OUTPUT : PROP_INPUT, (String) newValue);
        return true;
    }

    private void updateDevices() {
        final Map<String, CharSequence> outputs = new LinkedHashMap<>();
        final Map<String, CharSequence> inputs = new LinkedHashMap<>();
        outputs.put(AUTOMATIC, getString(R.string.automatic));
        inputs.put(AUTOMATIC, getString(R.string.automatic));

        final Map<Integer, String> cards = readCardNames();
        // "01-00: ALC3227 Analog : ALC3227 Analog : playback 1 : capture 1"
        try (BufferedReader reader = new BufferedReader(new FileReader("/proc/asound/pcm"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                final String[] fields = line.split(" : ");
                final int colon = fields[0].indexOf(':');
                final int dash = fields[0].indexOf('-');
                if (colon < 0 || dash < 0 || dash > colon) continue;
                final int card, device;
                try {
                    card = Integer.parseInt(fields[0].substring(0, dash));
                    device = Integer.parseInt(fields[0].substring(dash + 1, colon));
                } catch (NumberFormatException e) {
                    continue;
                }
                final String name = fields[0].substring(colon + 1).trim();
                final String cardName = cards.get(card);
                final CharSequence entry = cardName != null
                        ? getString(R.string.sound_device_entry, name, cardName)
                        : name;
                final String value = card + "," + device;
                for (int i = 1; i < fields.length; i++) {
                    if (fields[i].startsWith("playback")) outputs.put(value, entry);
                    if (fields[i].startsWith("capture")) inputs.put(value, entry);
                }
            }
        } catch (IOException e) {
            Log.e(TAG, "Failed to read the sound devices", e);
        }

        setEntries(mOutput, outputs, SystemProperties.get(PROP_OUTPUT, AUTOMATIC));
        setEntries(mInput, inputs, SystemProperties.get(PROP_INPUT, AUTOMATIC));
    }

    // Card numbers and names, from /proc/asound/cards:
    // " 1 [Generic_1      ]: HDA-Intel - HD-Audio Generic"
    private static Map<Integer, String> readCardNames() {
        final Map<Integer, String> cards = new HashMap<>();
        try (BufferedReader reader = new BufferedReader(new FileReader("/proc/asound/cards"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                final int bracket = line.indexOf('[');
                final int separator = line.indexOf("]: ");
                if (bracket < 0 || separator < 0) continue;
                try {
                    final int card = Integer.parseInt(line.substring(0, bracket).trim());
                    final String name = line.substring(separator + 3);
                    final int dash = name.indexOf(" - ");
                    cards.put(card, dash >= 0 ? name.substring(dash + 3) : name);
                } catch (NumberFormatException e) {
                    // A card's second line, or something unexpected
                }
            }
        } catch (IOException e) {
            Log.e(TAG, "Failed to read the sound cards", e);
        }
        return cards;
    }

    // A chosen device that's gone (e.g. an unplugged USB headset) stays listed, so the choice
    // isn't lost; the audio HAL uses the automatic one until it's back
    private void setEntries(ListPreference preference, Map<String, CharSequence> entries,
            String value) {
        if (!entries.containsKey(value)) {
            entries.put(value, getString(R.string.sound_device_missing));
        }
        preference.setEntries(entries.values().toArray(new CharSequence[0]));
        preference.setEntryValues(entries.keySet().toArray(new CharSequence[0]));
        preference.setValue(value);
    }
}
